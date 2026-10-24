import AppKit
import Foundation
import SwiftData

/// What the extension last reported for a browser. `url` nil with a client
/// connected means no page it can see is in front (a private window, a
/// browser page), so the AppleScript fallback isn't used either.
struct ExtensionTab: Equatable {
    let url: String?
    let title: String?
}

/// The app's end of the browser extension. Browser helpers connect over a
/// local socket; the bridge keeps what each one reported, answers the
/// popup's requests and pushes the state the extension shows.
///
/// Nothing here talks to a server: the socket is a file in the user's
/// Application Support folder that only this user can open.
@MainActor
@Observable
final class ExtensionBridge {
    /// One browser profile running the extension.
    struct Client: Equatable {
        var browser: String?
        var origin: String?
        var extensionVersion: String?
        var siteAccess = false
        var incognito = false
        var greeted = false
        var tab: BrowserTabReport?
        var tabAt: Date = .distantPast
        /// The last page it showed, kept when its windows lose focus.
        var lastTab: BrowserTabReport?
        var lastTabAt: Date = .distantPast
    }

    private(set) var clients: [BrowserSocketServer.ClientID: Client] = [:]

    /// Browsers with the extension connected right now, by bundle id.
    var connectedBrowsers: Set<String> {
        Set(clients.values.filter(\.greeted).compactMap(\.browser))
    }

    // MARK: Hooks (set by AppState)

    /// The plan and which Pro features are unlocked, from `Entitlements`.
    @ObservationIgnored var planProvider: () -> ExtensionState.Plan = { ExtensionBridge.plan(from: .shared) }
    /// Sites and parts of sites blocked during sessions: the Distracting site
    /// and part-of-site rules unless something else is set.
    @ObservationIgnored var blockListProvider: (() -> (sites: [String], parts: [String]))?
    /// Today's daily limits (`DailyLimitsEngine.statuses`).
    @ObservationIgnored var limitsProvider: () -> [LimitStatus] = { [] }
    /// The preset in force; its `OverridePolicy` decides passes and extra time.
    @ObservationIgnored var presetProvider: () -> DriftResponse = { .standard }
    /// Takes extra time on a daily limit, by its id; false when the preset
    /// doesn't allow more today.
    @ObservationIgnored var extraTimeHandler: ((UUID) -> Bool)?
    /// Gives the escalation engine the same pass the block screen's "Let me
    /// through" does, for what the snapshot shows, so a pass taken in the
    /// browser isn't followed by the block screen.
    @ObservationIgnored var grantEnginePass: (ActivitySnapshot) -> Void = { _ in }

    // MARK: State

    private let server: BrowserSocketServer
    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var rulesObserver: NSObjectProtocol?
    @ObservationIgnored private var lastSent: ExtensionState?
    @ObservationIgnored private var lastSentAt: Date = .distantPast
    @ObservationIgnored private var blockListCache: (at: Date, value: (sites: [String], parts: [String]))?
    /// `pauseTab` requests waiting for the extension's answer, by request id.
    @ObservationIgnored private var pendingPauses: [String: (done: @MainActor (Bool) -> Void, timer: Timer)] = [:]
    @ObservationIgnored private var visitsCache: (at: Date, value: [String: (count: Int, last: Date?)])?
    /// When each browser last came to the front.
    @ObservationIgnored private var activatedAt: [String: Date] = [:]

    /// Passes and "for work" sites taken in the browser, for the running session.
    private(set) var passes: [String: Date] = [:]
    private(set) var allowedForWork: Set<String> = []
    private(set) var stoppedVisits = 0
    @ObservationIgnored private var countersSessionID: UUID?

    /// Soft changes (the session bar, today's focus) go out at most this often.
    static let softPushInterval: TimeInterval = 15

    init(socketPath: String = BrowserSocketLocation.path()) {
        server = BrowserSocketServer(path: socketPath)
        server.onConnect = { [weak self] id in self?.connected(id) }
        server.onDisconnect = { [weak self] id in self?.clients[id] = nil }
        server.onMessage = { [weak self] id, data in self?.receive(data, from: id) }
    }

    func start(appState: AppState) {
        self.appState = appState
        NativeHostInstaller().install()
        do {
            try server.start()
        } catch {
            Persistence.logger.error("browser extension socket didn't start: \(String(describing: error), privacy: .public)")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Switching to a browser: ask its extension where it is, in case a
        // focus change got lost on the way.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let bundleId = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            // Synchronously (this is the main queue), so the time is set
            // before the tracker's own tick for this switch runs.
            MainActor.assumeIsolated { self?.browserActivated(bundleId) }
        }
        rulesObserver = NotificationCenter.default.addObserver(
            forName: .activityTotalsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.blockListCache = nil }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        server.stop()
        clients = [:]
    }

    // MARK: - Tracking source

    /// The extension's report for this browser, or nil when no extension is
    /// connected for it (the tracker then falls back to AppleScript).
    func tab(forBrowser bundleId: String) -> ExtensionTab? {
        Self.pickTab(from: Array(clients.values), browser: bundleId, activatedAt: activatedAt[bundleId])
    }

    /// How long after switching to a browser its last page still counts,
    /// while the extension's fresh report is on its way.
    nonisolated static let returnGrace: TimeInterval = 1.5

    /// Several profiles of one browser can be connected; each reports nil when
    /// its windows lose focus, so the newest report with a tab is the front one.
    /// Nil from every profile means no page the extension can see is in front
    /// (a private window), except just after switching back to the browser.
    nonisolated static func pickTab(from clients: [Client], browser: String,
                                    now: Date = .now, activatedAt: Date? = nil) -> ExtensionTab? {
        let mine = clients.filter { $0.greeted && $0.browser == browser }
        guard !mine.isEmpty else { return nil }
        if let tab = mine.filter({ $0.tab != nil }).max(by: { $0.tabAt < $1.tabAt })?.tab {
            return ExtensionTab(url: tab.url, title: tab.title)
        }
        if let activatedAt, now.timeIntervalSince(activatedAt) < returnGrace,
           let last = mine.filter({ $0.lastTab != nil }).max(by: { $0.lastTabAt < $1.lastTabAt })?.lastTab {
            return ExtensionTab(url: last.url, title: last.title)
        }
        return ExtensionTab(url: nil, title: nil)
    }

    // MARK: - Receiving

    /// A helper connected; it says which browser it's for in `helperHello`.
    func connected(_ id: BrowserSocketServer.ClientID) {
        clients[id] = Client()
    }

    private func receive(_ data: Data, from id: BrowserSocketServer.ClientID) {
        let message: ExtensionMessage
        do {
            message = try ExtensionMessage.decode(data)
        } catch {
            Persistence.logger.error("unreadable extension message: \(String(describing: error), privacy: .public)")
            return
        }
        handle(message, from: id)
    }

    func handle(_ message: ExtensionMessage, from id: BrowserSocketServer.ClientID) {
        switch message {
        case .helperHello(let browser, let origin):
            clients[id]?.browser = browser
            clients[id]?.origin = origin
        case .hello(let version, let siteAccess, let incognito):
            clients[id]?.extensionVersion = version
            clients[id]?.siteAccess = siteAccess
            clients[id]?.incognito = incognito
            clients[id]?.greeted = true
            if let state = makeState(now: .now) { send(state, to: id) }
        case .tab(let report):
            clients[id]?.tab = report
            clients[id]?.tabAt = .now
            if let report {
                clients[id]?.lastTab = report
                clients[id]?.lastTabAt = .now
            }
        case .classify(let requestId, let url):
            reply(id, requestId, result: classification(of: url, browser: clients[id]?.browser))
        case .setCategory(let requestId, let url, let scope, let category):
            setCategory(url: url, scope: scope, category: category)
            reply(id, requestId, result: classification(of: url, browser: clients[id]?.browser))
        case .startSession(let requestId, let minutes):
            reply(id, requestId, error: startSession(minutes: minutes))
        case .extendBreak(let requestId, let minutes):
            guard let breaks = appState?.breakManager, breaks.isOnBreak else {
                return reply(id, requestId, error: "noBreak")
            }
            breaks.extend(byMinutes: minutes)
            reply(id, requestId)
        case .endBreak(let requestId):
            guard let breaks = appState?.breakManager, breaks.isOnBreak else {
                return reply(id, requestId, error: "noBreak")
            }
            breaks.skip()
            reply(id, requestId, error: breaks.isOnBreak ? "strictBreak" : nil)
        case .openApp(let page):
            NotificationCenter.default.post(name: .openMainWindowFromExtension, object: Self.mainTab(for: page))
        case .backToWork(let requestId):
            reply(id, requestId, result: .init(app: backToWork()))
        case .requestPass(let requestId, let host):
            switch grantPass(host: host) {
            case .success(let until): reply(id, requestId, result: .init(until: BrowserProtocol.millis(until)))
            case .failure(let reason): reply(id, requestId, error: reason.rawValue)
            }
        case .allowForWork(let requestId, let host):
            reply(id, requestId, error: allowForWork(host: host))
        case .requestExtraTime(let requestId, let site):
            reply(id, requestId, error: takeExtraTime(site: site))
        case .blockedVisit:
            resetCountersIfNeeded()
            if appState?.sessionManager.currentSession != nil { stoppedVisits += 1 }
        case .pauseResult(let requestId, let ok):
            finishPause(requestId, ok: ok)
        case .tabAction(let requestId, let action, let pauseID, let minutes):
            guard let route = Self.route(action: action, pauseID: pauseID, minutes: minutes) else {
                return reply(id, requestId, error: "unknownAction")
            }
            appState?.open(route)
            reply(id, requestId)
        case .unknown(let type, let requestId):
            Persistence.logger.debug("ignoring extension message \(type, privacy: .public)")
            if let requestId { reply(id, requestId, error: "unknownType") }
        }
        pushIfChanged(force: true)
    }

    // MARK: - Requests

    private func classification(of url: String, browser: String?) -> ExtensionReply.Result {
        let host = Self.displayHost(url)
        guard let classifier = appState?.classifier else { return .init(host: host) }
        let rule = classifier.matchingRule(bundleId: browser ?? "", windowTitle: nil, url: url)
        let scope: CategoryScope? = switch rule?.matchKind {
        case .host?: .site
        case .urlPrefix?: .page
        default: nil
        }
        return .init(host: host, category: BrowserCategory(rule?.classification ?? .neutral), ruleScope: scope)
    }

    private func setCategory(url: String, scope: CategoryScope, category: BrowserCategory) {
        guard let classifier = appState?.classifier, let host = Self.displayHost(url) else { return }
        switch scope {
        case .site:
            classifier.setOverride(host: host, classification: category.classification)
        case .page:
            guard let prefix = Self.pagePattern(url) else { return }
            classifier.setOverride(urlPrefix: prefix, classification: category.classification)
        }
        blockListCache = nil
    }

    /// Nil on success, else why not.
    private func startSession(minutes: Int?) -> String? {
        guard let appState else { return "notReady" }
        guard appState.sessionManager.currentSession == nil else { return "alreadyRunning" }
        guard !appState.breakManager.isOnBreak else { return "onBreak" }
        let label = UserDefaults.standard.string(forKey: SessionDefaultsKey.label) ?? ""
        appState.sessionManager.startSession(label: label.isEmpty ? nil : label, plannedDurationMinutes: minutes)
        return nil
    }

    /// Brings back the last focus app. Nil when there's none to go back to;
    /// the block page then closes its tab instead.
    private func backToWork() -> String? {
        guard let appState,
              let id = appState.tracker.lastFocusBundleId, id != ActivityTracker.selfBundleId,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
        else { return nil }
        app.activate()
        return app.localizedName
    }

    enum PassRefusal: String, Error {
        case notPro, noSession, strict
    }

    /// "Let me through" on a block page: as long as the preset's pass, when
    /// the preset allows one. The time still counts as drift.
    func grantPass(host: String, now: Date = .now) -> Result<Date, PassRefusal> {
        guard planProvider().features.blockInBrowser else { return .failure(.notPro) }
        guard appState?.sessionManager.currentSession != nil else { return .failure(.noSession) }
        let policy = presetProvider().overridePolicy
        guard policy.allowsPass else { return .failure(.strict) }
        resetCountersIfNeeded()
        let key = host.lowercased()
        let until = now.addingTimeInterval(policy.passSeconds)
        passes[key] = until
        grantEnginePass(ActivitySnapshot(
            bundleIdentifier: appState?.tracker.currentSnapshot?.bundleIdentifier ?? "",
            appName: "", windowTitle: nil, url: "https://\(key)/",
            classification: .distraction, observedAt: now
        ))
        return .success(until)
    }

    /// "5 more minutes" on a daily limit's block page. Nil on success.
    private func takeExtraTime(site: String) -> String? {
        guard let limit = limitsProvider().first(where: { $0.isSite && Classifier.host(site, matches: $0.target) }) else {
            return "noLimit"
        }
        return extraTimeHandler?(limit.id) == true ? nil : "notAllowed"
    }

    /// Nil on success.
    private func allowForWork(host: String) -> String? {
        guard let appState, appState.sessionManager.currentSession != nil else { return "noSession" }
        resetCountersIfNeeded()
        let key = host.lowercased()
        allowedForWork.insert(key)
        // The escalation engine keys its exceptions by host, like this.
        appState.escalationEngine.allowForSession(ActivitySnapshot(
            bundleIdentifier: appState.tracker.currentSnapshot?.bundleIdentifier ?? "",
            appName: "", windowTitle: nil, url: "https://\(key)/",
            classification: .distraction, observedAt: .now
        ))
        return nil
    }

    // MARK: - Pausing tabs (free, level 1; see ExtensionTabPauser)

    /// How long to wait for the extension to say it paused a tab.
    static let pauseTimeout: TimeInterval = 3

    /// Points the front tab of `browser` at the extension's paused page, if
    /// it still shows `host`, and reports whether it did.
    /// - Returns: the request id, nil when no extension is connected for it.
    @discardableResult
    func pauseFrontTab(browser: String, host: String, fragment: String,
                       completion: @escaping @MainActor (Bool) -> Void) -> String? {
        // The block screen has taken focus by now, so the browser may already
        // have reported "no tab": go by the last page each profile showed.
        let candidates = clients.filter { _, client in client.greeted && client.browser == browser }
        let showing = candidates
            .filter { _, client in client.lastTab?.url.flatMap(Self.displayHost).map { Classifier.host($0, matches: host) } == true }
            .max { $0.value.lastTabAt < $1.value.lastTabAt }
        guard let target = showing ?? candidates.max(by: { $0.value.lastTabAt < $1.value.lastTabAt }) else {
            completion(false)
            return nil
        }
        let (id, client) = target
        let rid = UUID().uuidString.lowercased()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pauseTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishPause(rid, ok: false) }
        }
        pendingPauses[rid] = (completion, timer)
        send(PauseTabCommand(rid: rid, host: host, tabId: client.lastTab?.tabId, fragment: fragment), to: id)
        return rid
    }

    private func finishPause(_ rid: String, ok: Bool) {
        guard let pending = pendingPauses.removeValue(forKey: rid) else { return }
        pending.timer.invalidate()
        pending.done(ok)
    }

    /// Points the tab showing paused page `pauseID` at the page in another
    /// state (`fragment`) or back at the site (`url`). Each extension for the
    /// browser looks only at tabs it paused itself.
    func redirectTab(pauseID: String, browser: String, fragment: String? = nil, url: URL? = nil) {
        let command = RedirectTabCommand(pauseId: pauseID, fragment: fragment, url: url?.absoluteString)
        for (id, client) in clients where client.greeted && client.browser == browser { send(command, to: id) }
    }

    /// The paused page's buttons, as the app's own `focusguard://` routes.
    nonisolated static func route(action: String, pauseID: String?, minutes: Int?) -> FocusGuardURL? {
        switch action {
        case "back":
            return .back
        case "reopenLater":
            guard let pauseID, PausedPage.isValidID(pauseID) else { return nil }
            return .reopenLater(pauseID: pauseID)
        case "keepPaused":
            guard let pauseID, PausedPage.isValidID(pauseID) else { return nil }
            return .keepPaused(pauseID: pauseID)
        case "startBreak":
            let range = FocusGuardURL.breakMinutes
            return .startBreak(minutes: min(max(minutes ?? 10, range.lowerBound), range.upperBound))
        default:
            return nil
        }
    }

    // MARK: - Pushing state

    private func tick() {
        // Nothing to keep up to date until an extension connects.
        guard let appState, !clients.isEmpty else { return }
        appState.refreshMenuStats()
        expirePasses()
        pushIfChanged(force: false)
    }

    private func expirePasses(now: Date = .now) {
        let live = passes.filter { $0.value > now }
        if live.count != passes.count { passes = live }
    }

    private func pushIfChanged(force: Bool, now: Date = .now) {
        guard !clients.isEmpty, let state = makeState(now: now) else { return }
        let hardChange = lastSent.map { Self.hardPart(of: $0) != Self.hardPart(of: state) } ?? true
        let softDue = now.timeIntervalSince(lastSentAt) >= Self.softPushInterval
        guard state != lastSent, hardChange || softDue || force else { return }
        lastSent = state
        lastSentAt = now
        for (id, client) in clients where client.greeted { send(state, to: id) }
    }

    /// The state without what changes every second, to tell real changes
    /// (a session starting, a pass) from the clock moving.
    nonisolated static func hardPart(of state: ExtensionState) -> ExtensionState {
        var hard = state
        hard.today.focusSeconds = 0
        if var session = hard.session {
            session.elapsedSeconds = 0
            session.asOf = 0
            session.segments = []
            session.focusSeconds = 0
            session.driftSeconds = 0
            session.otherSeconds = 0
            hard.session = session
        }
        hard.blocking.limits = hard.blocking.limits.map {
            var limit = $0
            if !limit.reached { limit.usedSeconds = 0 }
            return limit
        }
        return hard
    }

    func makeState(now: Date) -> ExtensionState? {
        guard let appState else { return nil }
        resetCountersIfNeeded()
        let plan = planProvider()
        let preset = presetProvider()
        var state = ExtensionState(
            app: .init(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""),
            plan: plan,
            preset: preset.rawValue,
            policy: preset.overridePolicy,
            today: .init(focusSeconds: Int(appState.menuStats.today.focus), goalMinutes: FocusGoal.dailyMinutes),
            phase: .ready,
            blocking: .init(pauseTab: appState.tabPause.isEnabled, sites: [], parts: [], limits: limits(now: now),
                            passes: passes.filter { $0.value > now }
                                .map { .init(host: $0.key, until: BrowserProtocol.millis($0.value)) }
                                .sorted { $0.host < $1.host },
                            allowed: allowedForWork.sorted(), lockedUntil: nil)
        )
        let list = blockList(now: now)
        state.blocking.sites = list.sites
        state.blocking.parts = list.parts

        switch appState.menuPhase(now: now) {
        case .ready:
            break
        case .recap(let recap):
            state.phase = .complete
            state.recap = .init(name: recap.label, endedAt: BrowserProtocol.millis(recap.endedAt),
                                showUntil: BrowserProtocol.millis(recap.endedAt.addingTimeInterval(SessionRecap.shelfLife)))
        case .onBreak(let breakState):
            state.phase = .onBreak
            let after = appState.recap.map { recap in
                recap.plannedMinutes.map { "\(recap.label) · \($0) min" } ?? recap.label
            }
            state.breakInfo = .init(
                startedAt: BrowserProtocol.millis(breakState.startedAt),
                endsAt: BrowserProtocol.millis(breakState.startedAt.addingTimeInterval(breakState.plannedDuration)),
                plannedSeconds: Int(breakState.plannedDuration),
                after: after,
                canEndEarly: appState.breakManager.canEndEarly
            )
        case .session(let session, _):
            let paused = session.pausedAt != nil
            state.phase = paused ? .paused : .focusing
            state.session = sessionInfo(session, appState: appState, now: now)
            if preset.overridePolicy.locksDuringSession, let endsAt = state.session?.endsAt {
                state.blocking.lockedUntil = endsAt
            }
        }
        return state
    }

    private func sessionInfo(_ session: Session, appState: AppState, now: Date) -> ExtensionState.SessionInfo {
        let elapsed = appState.sessionManager.runningSeconds(for: session, now: now)
        let paused = session.pausedAt != nil
        let endsAt: Date? = paused ? nil : session.plannedDurationMinutes.map {
            session.startedAt.addingTimeInterval(session.pausedSeconds + TimeInterval($0 * 60))
        }
        let raw = SessionTimeline.segments(from: session.events)
        let totals = Self.totals(raw)
        let backTo = appState.tracker.lastFocusBundleId.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName
        }
        return .init(
            name: session.displayName,
            startedAt: BrowserProtocol.millis(session.startedAt),
            endsAt: endsAt.map(BrowserProtocol.millis),
            plannedMinutes: session.plannedDurationMinutes,
            elapsedSeconds: Int(elapsed),
            asOf: BrowserProtocol.millis(now),
            paused: paused,
            segments: Self.barSegments(appState.liveTimeline(for: session, now: now)),
            focusSeconds: totals.focus,
            driftSeconds: totals.drift,
            otherSeconds: totals.other,
            stoppedVisits: stoppedVisits,
            backTo: backTo
        )
    }

    /// The popup's bar: the session timeline's minutes, run together.
    nonisolated static func barSegments(_ timeline: SessionTimeline) -> [ExtensionState.Segment] {
        var out: [ExtensionState.Segment] = []
        let cellSeconds = timeline.minutesPerCell * 60
        for cell in timeline.cells {
            let kind: String
            switch cell {
            case .focus, .now(.focus): kind = "f"
            case .drift, .now(.distraction): kind = "d"
            case .other, .now(.neutral): kind = "o"
            case .future: continue
            }
            if let last = out.last, last.kind == kind {
                out[out.count - 1].seconds += cellSeconds
            } else {
                out.append(.init(kind: kind, seconds: cellSeconds))
            }
        }
        return out
    }

    nonisolated static func totals(_ segments: [SessionTimeline.Segment]) -> (focus: Int, drift: Int, other: Int) {
        var focus = 0.0, drift = 0.0, other = 0.0
        for segment in segments {
            switch segment.classification {
            case .focus:       focus += segment.seconds
            case .distraction: drift += segment.seconds
            case .neutral:     other += segment.seconds
            }
        }
        return (Int(focus), Int(drift), Int(other))
    }

    private func blockList(now: Date) -> (sites: [String], parts: [String]) {
        if let blockListProvider { return blockListProvider() }
        if let cache = blockListCache, now.timeIntervalSince(cache.at) < 30 { return cache.value }
        guard let context = appState?.container.mainContext else { return ([], []) }
        let distraction = Classification.distraction.rawValue
        let rules = Persistence.fetch(context, FetchDescriptor<AppRule>(
            predicate: #Predicate { $0.classificationRaw == distraction }
        ))
        let value = Self.blockList(from: rules)
        blockListCache = (now, value)
        return value
    }

    /// Distracting site rules as the blocked list, sorted and without repeats.
    nonisolated static func blockList(from rules: [AppRule]) -> (sites: [String], parts: [String]) {
        var sites = Set<String>(), parts = Set<String>()
        for rule in rules where rule.classification == .distraction {
            switch rule.matchKind {
            case .host:
                if let host = displayHost("https://" + rule.pattern) { sites.insert(host) }
            case .urlPrefix:
                parts.insert(rule.pattern.lowercased())
            case .bundleId, .titleRegex:
                break
            }
        }
        return (sites.sorted(), parts.sorted())
    }

    private func browserActivated(_ bundleId: String?) {
        guard let bundleId else { return }
        activatedAt[bundleId] = .now
        for (id, client) in clients where client.greeted && client.browser == bundleId {
            send(RefreshCommand(), to: id)
        }
    }

    /// Passes, "for work" sites and the visit count belong to one session.
    private func resetCountersIfNeeded() {
        let current = appState?.sessionManager.currentSession?.id
        guard current != countersSessionID else { return }
        countersSessionID = current
        passes = [:]
        allowedForWork = []
        stoppedVisits = 0
    }

    // MARK: - Sending

    private func send<T: Encodable>(_ message: T, to id: BrowserSocketServer.ClientID) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        server.send(data, to: id)
    }

    private func reply(_ id: BrowserSocketServer.ClientID, _ requestId: String,
                       error: String? = nil, result: ExtensionReply.Result? = nil) {
        send(ExtensionReply(id: requestId, ok: error == nil, error: error, result: result), to: id)
    }

    // MARK: - Helpers

    /// "www.x.com" → "x.com"; nil for addresses without a web host.
    nonisolated static func displayHost(_ url: String) -> String? {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// "Only this article": the host and path, without query or fragment,
    /// e.g. "medium.com/@ann/structured-concurrency".
    nonisolated static func pagePattern(_ url: String) -> String? {
        guard let host = displayHost(url), let components = URLComponents(string: url) else { return nil }
        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path.count > 1 else { return nil }
        return host + path
    }

    nonisolated static func mainTab(for page: String?) -> MainTab {
        switch page {
        case "reports": return .reports
        case "apps", "blocking": return .apps
        case "settings": return .settings
        default: return .home
        }
    }

    /// The plan as the extension needs it: the tier, and each Pro feature
    /// it uses, from `Entitlements`.
    static func plan(from entitlements: Entitlements, now: Date = .now) -> ExtensionState.Plan {
        let tier: String
        switch entitlements.plan {
        case .free:  tier = "free"
        case .trial: tier = "trial"
        case .pro:   tier = "pro"
        }
        let features = ExtensionState.Features(
            blockInBrowser: entitlements.isUnlocked(.blockInBrowser),
            partsOfSites: entitlements.isUnlocked(.partsOfSites),
            youtubePerVideo: entitlements.isUnlocked(.youtubePerVideo),
            unlimitedLimits: entitlements.isUnlocked(.unlimitedLimits)
        )
        return .init(tier: tier, pro: entitlements.plan.unlocksPro(at: now),
                     trialDaysLeft: entitlements.plan.daysLeft(at: now), features: features)
    }

    /// Today's site limits for the block pages. Visits are counted only for
    /// limits that ran out, at most once a minute.
    private func limits(now: Date) -> [ExtensionState.Limit] {
        let statuses = limitsProvider().filter(\.isSite)
        let reached = statuses.filter(\.isUsedUp).map(\.target)
        var visits: [String: (count: Int, last: Date?)] = [:]
        if !reached.isEmpty, let context = appState?.container.mainContext {
            if let cache = visitsCache, now.timeIntervalSince(cache.at) < 60, Set(cache.value.keys) == Set(reached) {
                visits = cache.value
            } else {
                let dayStart = Calendar.current.startOfDay(for: now)
                let events = Persistence.fetch(context, FetchDescriptor<ActivityEvent>(
                    predicate: #Predicate { $0.endedAt >= dayStart },
                    sortBy: [SortDescriptor(\.startedAt)]
                )).map { (start: $0.startedAt, url: $0.url) }
                for site in reached { visits[site] = Self.visits(to: site, in: events) }
                visitsCache = (now, visits)
            }
        }
        return statuses.map { status in
            ExtensionState.Limit(
                site: status.target, minutes: status.minutes + status.extraMinutes,
                usedSeconds: Int(status.used), reached: status.isUsedUp, extraLeft: status.extraLeft,
                visits: visits[status.target]?.count, lastVisitAt: visits[status.target]?.last.map(BrowserProtocol.millis)
            )
        }
    }

    /// Separate visits to `site` among today's events (in order): each run of
    /// events on it counts once. Also when the last one began.
    static func visits(to site: String, in events: [(start: Date, url: String?)]) -> (count: Int, last: Date?) {
        var count = 0
        var last: Date?
        var onSite = false
        for event in events {
            let here = event.url.flatMap { URL(string: $0)?.host }.map { Classifier.host($0, matches: site) } == true
            if here, !onSite {
                count += 1
                last = event.start
            }
            onSite = here
        }
        return (count, last)
    }
}

extension Notification.Name {
    /// The extension asked for the app's window; `object` is the `MainTab`.
    static let openMainWindowFromExtension = Notification.Name("FocusGuard.openMainWindowFromExtension")
}
