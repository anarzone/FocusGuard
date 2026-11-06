import AppKit
import Foundation
import SwiftData

/// A snapshot of "what the user is currently doing" for the UI to display.
struct ActivitySnapshot: Equatable {
    let bundleIdentifier: String
    let appName: String
    let windowTitle: String?
    let url: String?
    let classification: Classification
    let observedAt: Date
    /// A browser's private window: known here, for blocking, but its page and
    /// title are never written down.
    var isPrivateWindow = false
}

extension ActivitySnapshot {
    /// The same moment treated as neutral — used while FocusGuard is frontmost.
    func asNeutral(at date: Date) -> ActivitySnapshot {
        ActivitySnapshot(bundleIdentifier: bundleIdentifier, appName: appName, windowTitle: windowTitle,
                         url: url, classification: .neutral, observedAt: date, isPrivateWindow: isPrivateWindow)
    }

    /// The same activity, seen again at `date`. The tracker's
    /// `currentSnapshot` keeps the time it was first seen, so it changes
    /// only when the activity does; per-tick readers stamp it with the tick.
    func observed(at date: Date) -> ActivitySnapshot {
        ActivitySnapshot(bundleIdentifier: bundleIdentifier, appName: appName, windowTitle: windowTitle,
                         url: url, classification: classification, observedAt: date, isPrivateWindow: isPrivateWindow)
    }

    /// Same app, title, page and classification, whenever it was seen.
    func isSameActivity(as other: ActivitySnapshot) -> Bool {
        bundleIdentifier == other.bundleIdentifier && appName == other.appName && windowTitle == other.windowTitle
            && url == other.url && classification == other.classification && isPrivateWindow == other.isPrivateWindow
    }
}

/// The app in front, as the tracker reads it.
struct FrontmostApp: Equatable {
    let bundleId: String
    let name: String
    let pid: pid_t
}

/// Runs the always-on tracking. It looks at the frontmost app, window title
/// and browser tab when something changes — an app comes to the front, a
/// window or its title changes (Accessibility, where allowed), the browser
/// extension or AppleScript reports another page — and on a timer whose
/// pace follows what needs it (`TrackingCadence`): every second in a
/// session, on a break, on a limited site or with FocusGuard on screen, and
/// much less often otherwise.
///
/// Each look either extends the current `ActivityEvent` or, when the
/// (bundleId, windowTitle, url) tuple changed, ends it at that moment and
/// starts a new one, so durations come from when things happened rather
/// than from how often the timer runs. Sleep, the screens going dark, the
/// screen locking and another user taking over end the event in progress;
/// quitting brings it up to date (`flush`).
@MainActor
@Observable
final class ActivityTracker {
    private(set) var currentSnapshot: ActivitySnapshot?
    /// Most recent app classified as focus — where "Back to work" returns to.
    private(set) var lastFocusBundleId: String?
    /// When that app is a browser, the site it was on: "claude.ai". Back to
    /// work then means that tab, not the browser the drift is in too.
    private(set) var lastFocusHost: String?
    /// True while FocusGuard itself is frontmost. Its own windows aren't
    /// tracked, can't count as drift, and keep the session from looking idle.
    private(set) var isFrontmostSelf = false
    /// True while nobody's at the Mac (no input for `IdleMonitor.awayAfter`
    /// and nothing like a video keeping the display awake, or the screens
    /// asleep). Nothing is recorded meanwhile.
    private(set) var isAway = false
    /// Last tick with the user at the Mac (any app, FocusGuard included).
    /// Drives idle auto-pause, which `currentSnapshot` can't once FocusGuard
    /// is frontmost (the snapshot keeps showing the last real app).
    @ObservationIgnored private(set) var lastActiveAt: Date?

    /// FocusGuard's own bundle id; time in its windows isn't recorded.
    static let selfBundleId = Bundle.main.bundleIdentifier ?? "com.anar.focusguard"

    /// Set by `SessionManager` when a focus session starts/stops. Newly created
    /// `ActivityEvent`s pick up this association at insert time.
    var currentSession: Session? {
        didSet {
            // Split the in-flight event at the session boundary (start, pause,
            // resume, stop). Otherwise the app you're already in when a
            // session starts keeps extending an event with no session, and
            // that time never counts toward it.
            guard oldValue?.id != currentSession?.id, let event = currentEvent else { return }
            event.endedAt = .now
            currentEvent = nil
        }
    }

    /// Optional callback invoked every tick. SessionManager hooks this to
    /// enforce planned-duration auto-stop and to feed the escalation engine.
    @ObservationIgnored var onTick: (() -> Void)?

    /// The browser extension's report for a browser, nil when none is
    /// connected for it (set by AppState). Used instead of AppleScript when
    /// present: no Automation prompt, and titles without Screen Recording.
    @ObservationIgnored var extensionTab: ((_ bundleId: String) -> ExtensionTab?)?

    /// Called once the Mac or its screens went to sleep or the screen locked,
    /// which can be the last thing that happens before they're back.
    @ObservationIgnored var onSuspended: (() -> Void)?

    /// Called when a new event starts (another app, page or title). Smart
    /// categories watch it for things not sorted yet.
    @ObservationIgnored var onNewEvent: ((ActivityEvent) -> Void)?

    /// Whether to look every second (set by AppState; see
    /// `TrackingCadence.needsSecondTicks`). Read under observation, so the
    /// pace follows it the moment it changes.
    @ObservationIgnored var needsSecondTicks: () -> Bool = { false }

    /// The frontmost window's title for a pid. Tests pass their own.
    @ObservationIgnored var readWindowTitle: (pid_t) -> String?
    /// Seconds since the last keyboard, mouse or trackpad input.
    @ObservationIgnored var secondsSinceInput: () -> TimeInterval = { IdleMonitor.secondsSinceInput() }
    /// Something (a video, a call) keeps the display awake.
    @ObservationIgnored var displayKeptAwake: () -> Bool = { IdleMonitor.displayKeptAwake() }

    /// The pace the timer runs at now.
    @ObservationIgnored private(set) var cadence: TrackingCadence?

    private let context: ModelContext
    private let browserReader: BrowserTabReader
    private let optOutCache: TitleOptOutCache
    private let classifier: Classifier
    @ObservationIgnored private let windowObserver = FocusedWindowObserver()

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    @ObservationIgnored private var currentEvent: ActivityEvent?
    /// Wall-clock of last `context.save()`. We coalesce saves so we don't
    /// burn through SQLite WAL writes when the user switches apps rapidly.
    @ObservationIgnored private var lastSaveAt: Date = .distantPast
    @ObservationIgnored private var isRunning = false
    /// When the Mac or its screens went to sleep, the screen locked or
    /// another user took over (see `suspend`); nil while in use.
    @ObservationIgnored private var suspendedAt: Date?
    var isSuspended: Bool { suspendedAt != nil }
    @ObservationIgnored private var lastLookAt: Date = .distantPast
    @ObservationIgnored private var lookPending = false
    /// The last value of `needsSecondTicks`, and whether a change is watched.
    @ObservationIgnored private var secondTicks = false
    @ObservationIgnored private var watchingNeeds = false
    /// What's in front can only be followed by asking again (see `TrackingCadence.needsPolling`).
    @ObservationIgnored private var needsPolling = false
    @ObservationIgnored private var screenRecording: (granted: Bool, checkedAt: Date)?

    init(
        context: ModelContext,
        optOutCache: TitleOptOutCache,
        classifier: Classifier,
        inspector: WindowInspector = WindowInspector(),
        browserReader: BrowserTabReader? = nil
    ) {
        self.context = context
        self.optOutCache = optOutCache
        self.classifier = classifier
        self.browserReader = browserReader ?? BrowserTabReader()
        self.readWindowTitle = { inspector.frontmostWindowTitle(forPID: $0) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] in
            // A hop, not a direct call: ExtensionBridge notes the switch in its
            // own (synchronous) handler first, and this look reads that.
            Task { @MainActor in self?.wake() }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name) { [weak self] in MainActor.assumeIsolated { self?.suspend() } }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name) { [weak self] in MainActor.assumeIsolated { self?.wake() } }
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            MainActor.assumeIsolated { self?.suspend() }
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in
            MainActor.assumeIsolated { self?.wake() }
        }
        windowObserver.onChange = { [weak self] in self?.lookSoon(spacing: 1) }
        browserReader.onURLChange = { [weak self] in self?.lookSoon() }
        watchNeeds()
        tick()  // sample immediately on start
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        cadence = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        windowObserver.stop()
        windowObserver.onChange = nil
        browserReader.onURLChange = nil
        flush()
        currentEvent = nil
    }

    /// Persist the current event, brought up to now. Call before quitting or
    /// before reading totals.
    func flush(now: Date = .now) {
        if let event = currentEvent { event.endedAt = max(event.endedAt, now) }
        guard context.hasChanges else { return }
        Persistence.save(context)
        lastSaveAt = now
    }

    /// Looks again soon: on the next turn of the run loop, and no sooner than
    /// `spacing` after the last look, so a title that changes many times a
    /// second (a progress counter) costs at most a look a second.
    func lookSoon(spacing: TimeInterval = 0) {
        guard isRunning, !lookPending else { return }
        lookPending = true
        let wait = max(0, lastLookAt.addingTimeInterval(spacing).timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lookPending = false
                if self.isRunning { self.tick() }
            }
        }
    }

    // MARK: - Sleep and wake

    /// The Mac or its screens went to sleep, the screen locked or another
    /// user took over: what was in front ends now (or at the last input, if
    /// they'd already left). Outside sessions and breaks nothing is recorded
    /// until they're back, and the timer all but stops.
    func suspend(now: Date = .now) {
        guard isRunning, suspendedAt == nil else { return }
        tick(now: now)
        enterSuspension(at: now)
        onSuspended?()
        reschedule()
    }

    /// Ends the event in progress at `now`; nothing more is recorded outside
    /// a session or break until `leaveSuspension`.
    func enterSuspension(at now: Date) {
        guard suspendedAt == nil else { return }
        suspendedAt = now
        closeEvent(at: now)
    }

    /// Someone's in an app again — not the lock screen or screensaver.
    func leaveSuspension(frontmost bundleId: String?) {
        guard let bundleId, !Self.idleProcessBundleIds.contains(bundleId) else { return }
        suspendedAt = nil
    }

    /// Back from sleep, the lock screen or another user — or an app came to
    /// the front. Looks straight away; someone in an app ends a suspension.
    private func wake(now: Date = .now) {
        guard isRunning else { return }
        leaveSuspension(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        tick(now: now)
    }

    // MARK: - Looking

    /// System processes that take frontmost focus when the Mac is locked,
    /// asleep, or showing the screensaver. Counting time on these as
    /// activity inflates "neutral" for hours of actual idle time.
    private static let idleProcessBundleIds: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.WindowManager",
    ]

    /// Looks at what's in front and records it.
    func tick(now: Date = .now) {
        defer { reschedule() }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier else { return }
        // While suspended, input since then means someone's using the Mac
        // and a wake-up notification went missing.
        if let since = suspendedAt, secondsSinceInput() < now.timeIntervalSince(since) {
            leaveSuspension(frontmost: bundleId)
        }
        record(FrontmostApp(bundleId: bundleId, name: app.localizedName ?? bundleId, pid: app.processIdentifier), now: now)
    }

    /// One look's bookkeeping, apart from reading the system, so tests can
    /// drive it with their own apps and times.
    func record(_ front: FrontmostApp, now: Date) {
        lastLookAt = now
        let bundleId = front.bundleId

        // Suspended: nothing to record, in a session or out of one, until
        // `leaveSuspension`. (Sessions and breaks keep their every-second
        // ticks, for their clocks.)
        if suspendedAt != nil {
            setAway(true)
            setFrontmostSelf(false)
            needsPolling = false
            onTick?()
            return
        }

        // Skip ticks when the Mac is locked / asleep / on screensaver, ending
        // the event in progress so its endedAt doesn't stretch through the
        // lock period — otherwise a 9-hour overnight lock looks like 9 hours
        // of activity in the last app you used.
        if Self.idleProcessBundleIds.contains(bundleId) {
            setFrontmostSelf(false)
            needsPolling = false
            closeEvent(at: now)
            return
        }

        // Away from the Mac: end the event in progress at the last input, so
        // the idle stretch isn't counted, and record nothing until they're back.
        // `lastActiveAt` points at the last input so idle auto-pause fires on time.
        let idleSeconds = secondsSinceInput()
        if idleSeconds >= IdleMonitor.awayAfter,
           IdleMonitor.isAway(idleSeconds: idleSeconds, displayKeptAwake: displayKeptAwake()) {
            let lastInput = now.addingTimeInterval(-idleSeconds)
            setAway(true)
            setFrontmostSelf(false)
            lastActiveAt = lastInput
            // Nothing else came to the front since, or it would have its own
            // event: they were on this one until their last input.
            closeEvent(at: lastInput)
            needsPolling = true
            onTick?()
            return
        }
        setAway(false)

        // FocusGuard's own menu/window: close the event in progress and
        // record nothing. The user is still here, so stay "active".
        let isSelf = bundleId == Self.selfBundleId
        setFrontmostSelf(isSelf)
        lastActiveAt = now
        if isSelf {
            closeEvent(at: now)
            needsPolling = false
            onTick?()
            return
        }

        windowObserver.follow(front.pid)
        let extensionTab = extensionTab?(bundleId)
        let optedOut = optOutCache.isOptedOut(bundleId)
        let title: String? = optedOut ? nil : extensionTab?.title ?? readWindowTitle(front.pid)
        let isBrowser = BrowserTabReader.isBrowser(bundleIdentifier: bundleId)
        let url: String?
        if let extensionTab {
            url = extensionTab.url
        } else if isBrowser {
            // A new title in the same browser usually means a new tab or page.
            let titleChanged = currentSnapshot?.bundleIdentifier == bundleId && currentSnapshot?.windowTitle != title
            // Every other second-tick, or every poll (a little under its
            // interval, so a timer firing on the dot isn't "too soon").
            let maxAge = secondTicks ? 1.75 : TrackingCadence.polling.interval - 0.5
            url = browserReader.currentURL(forBundleId: bundleId, maxAge: maxAge, refresh: titleChanged)
        } else {
            url = nil
        }
        // The browser's word, from the extension or AppleScript. Safari doesn't say.
        let isPrivateWindow = extensionTab?.isPrivate ?? (isBrowser && browserReader.isPrivateWindow(forBundleId: bundleId))
        needsPolling = TrackingCadence.needsPolling(
            away: false,
            browserWithoutExtension: isBrowser && extensionTab == nil,
            titlesReadable: !optedOut && extensionTab?.title == nil && (title != nil || screenRecordingGranted(now: now)),
            titleChangesAnnounced: windowObserver.isObserving(front.pid)
        )

        let classification = classifier.classify(bundleId: bundleId, windowTitle: title, url: url)
        if classification == .focus {
            if lastFocusBundleId != bundleId { lastFocusBundleId = bundleId }
            let host = isBrowser ? url.flatMap { URL(string: $0)?.host?.lowercased() }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } : nil
            if lastFocusHost != host { lastFocusHost = host }
        }

        let snapshot = ActivitySnapshot(
            bundleIdentifier: bundleId,
            appName: front.name,
            windowTitle: title,
            url: url,
            classification: classification,
            observedAt: now,
            isPrivateWindow: isPrivateWindow
        )
        // Only a different activity is published: readers (the menu bar,
        // the menu) aren't woken just because time passed.
        if currentSnapshot.map({ !$0.isSameActivity(as: snapshot) }) ?? true {
            currentSnapshot = snapshot
        }

        // A private window's time still counts, under the app alone.
        let keptTitle = isPrivateWindow ? nil : title
        let keptURL = isPrivateWindow ? nil : url
        if let event = currentEvent,
           event.bundleIdentifier == bundleId,
           event.windowTitle == keptTitle,
           event.url == keptURL {
            // Same activity; just extend the window.
            event.endedAt = max(event.endedAt, now)
        } else {
            // Something else: the old event ends exactly where this one begins.
            closeEvent(at: now, save: false)
            let new = ActivityEvent(
                startedAt: now,
                endedAt: now,
                bundleIdentifier: bundleId,
                appName: front.name,
                windowTitle: keptTitle,
                url: keptURL,
                session: currentSession
            )
            new.classification = classification
            context.insert(new)
            currentEvent = new
            onNewEvent?(new)
        }

        // Coalesced save: hold pending mutations in the context for up to
        // `saveCoalesceInterval` seconds, then flush. `flush()` and
        // `applicationWillTerminate` always force a save.
        if now.timeIntervalSince(lastSaveAt) >= Constants.Tracking.saveCoalesceInterval {
            Persistence.save(context)
            lastSaveAt = now
        }

        onTick?()
    }

    /// Ends the event in progress at `date` (never before it began).
    private func closeEvent(at date: Date, save: Bool = true) {
        guard let event = currentEvent else { return }
        event.endedAt = max(event.startedAt, date)
        currentEvent = nil
        guard save else { return }
        Persistence.save(context)
        lastSaveAt = date
    }

    // Published state is written only when it changes, so observers (the
    // menu bar, the menu) aren't woken by a tick that changed nothing.
    private func setAway(_ value: Bool) {
        if isAway != value { isAway = value }
    }

    private func setFrontmostSelf(_ value: Bool) {
        if isFrontmostSelf != value { isFrontmostSelf = value }
    }

    /// Whether window titles can be read at all (Screen Recording). Checked
    /// every few minutes; a grant takes effect after a relaunch anyway.
    private func screenRecordingGranted(now: Date) -> Bool {
        if let cached = screenRecording, now.timeIntervalSince(cached.checkedAt) < 300 { return cached.granted }
        let granted = CGPreflightScreenCaptureAccess()
        screenRecording = (granted, now)
        return granted
    }

    // MARK: - Pace

    /// Watches `needsSecondTicks`; when it flips, looks straight away (a
    /// session or break just started or ended, the menu opened) and changes pace.
    private func watchNeeds() {
        guard isRunning, !watchingNeeds else { return }
        watchingNeeds = true
        secondTicks = withObservationTracking {
            needsSecondTicks()
        } onChange: { [weak self] in
            // Called before the change lands: read it on the next turn.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.needsChanged() } }
        }
    }

    private func needsChanged() {
        watchingNeeds = false
        let before = secondTicks
        watchNeeds()
        if secondTicks != before, isRunning { tick() }
    }

    /// Starts the timer at the pace what's in front needs, if that changed.
    private func reschedule() {
        guard isRunning else { return }
        let next = TrackingCadence.choose(secondTicks: secondTicks, suspended: isSuspended, polling: needsPolling)
        guard next != cadence || timer == nil else { return }
        cadence = next
        timer?.invalidate()
        let timer = Timer(timeInterval: next.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = next.tolerance
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @Sendable () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in handler() }
        observers.append((center, token))
    }
}
