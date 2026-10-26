import Foundation
import SwiftData

/// Pro smart categories: new apps and sites get Focus, Neutral or
/// Distracting from Apple's on-device model, each with a one-line reason.
/// Sure answers apply on their own (with Undo); unsure ones wait for the
/// person. A category the person set is never touched. With YouTube video
/// by video on, each youtube.com video is judged by its title too.
///
/// It works in batches: a few minutes after something new shows up, never
/// during a session, and never twice for the same app or video.
@MainActor
@Observable
final class SmartCategories {
    /// Smart rules sit above built-in ones (100) and below the person's (200+).
    static let rulePriority = 150

    static let enabledKey = "smartCategories.enabled"
    static let perVideoKey = "smartCategories.youtubePerVideo"

    /// Waits this long after something new before sorting, so a burst of
    /// new apps goes in one batch.
    static let newItemDelay: TimeInterval = 120
    /// Retried this often while a session runs.
    static let sessionRetry: TimeInterval = 300
    static let videoDelay: TimeInterval = 6
    /// Something used less than this in the last week isn't sorted yet.
    static let minimumSeconds: TimeInterval = 60
    static let maxPerRun = 30
    static let lookbackDays = 7

    private(set) var store: SmartCategoryStore
    private(set) var isWorking = false

    /// Sort new apps and sites on their own; on by default once unlocked.
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { schedule(after: 1) }
        }
    }

    /// YouTube video by video, off until turned on.
    private(set) var perVideo: Bool

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let classifier: Classifier
    @ObservationIgnored private let optedOut: () -> Set<String>
    @ObservationIgnored private let isUnlocked: @MainActor (ProFeature) -> Bool
    @ObservationIgnored private let startTrial: @MainActor (ProFeature) -> Void
    @ObservationIgnored private let modelProvider: () -> (any OnDeviceModel)?
    @ObservationIgnored private let isInSession: () -> Bool
    @ObservationIgnored private let isStrictLocked: () -> Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let flagOn: Bool

    /// Keys looked at since the last run, so each new event costs a set lookup.
    @ObservationIgnored private var checkedKeys = Set<String>()
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// Videos waiting for a verdict: id → latest title.
    @ObservationIgnored private var pendingVideos: [String: String] = [:]
    @ObservationIgnored private var videoTask: Task<Void, Never>?
    /// Focus apps used lately, newest first: what the videos are compared with.
    @ObservationIgnored private var recentFocus: [String] = []

    private var context: ModelContext { container.mainContext }

    init(container: ModelContainer,
         classifier: Classifier,
         optedOut: @escaping () -> Set<String>,
         isUnlocked: @escaping @MainActor (ProFeature) -> Bool = { Entitlements.shared.isUnlocked($0) },
         startTrial: @escaping @MainActor (ProFeature) -> Void = { Entitlements.shared.startTrialIfNeeded(for: $0) },
         model: @escaping () -> (any OnDeviceModel)? = OnDeviceAI.model,
         isInSession: @escaping () -> Bool = { false },
         isStrictLocked: @escaping () -> Bool = { false },
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         flagOn: Bool = FeatureFlags.smartCategories) {
        self.container = container
        self.classifier = classifier
        self.optedOut = optedOut
        self.isUnlocked = isUnlocked
        self.startTrial = startTrial
        self.modelProvider = model
        self.isInSession = isInSession
        self.isStrictLocked = isStrictLocked
        self.defaults = defaults
        self.now = now
        self.flagOn = flagOn
        self.store = SmartCategoryStore.load(from: defaults)
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.perVideo = defaults.bool(forKey: Self.perVideoKey)
    }

    // MARK: - State

    /// Smart categories may run: built, unlocked and switched on.
    var isOn: Bool { flagOn && isUnlocked(.smartCategories) && isEnabled }

    /// YouTube video by video applies.
    var isPerVideoOn: Bool { flagOn && isUnlocked(.youtubePerVideo) && perVideo }

    /// Apple Intelligence is there to ask.
    var isModelAvailable: Bool { modelProvider() != nil }

    /// "Sorted 19 of 21 new apps and sites · 2 need you", or nil.
    var banner: SmartBanner? {
        SmartBanner(records: Array(store.records.values), closedAt: store.bannerClosedAt, now: now()) { isUnsorted($0) }
    }

    /// Unsure guesses, still unsorted, newest first.
    var needsYou: [SmartRecord] {
        store.records.values
            .filter { $0.status == .needsYou && isUnsorted($0) }
            .sorted { ($0.decidedAt, $1.key) > ($1.decidedAt, $0.key) }
    }

    /// Put in place on their own and still in place, newest first.
    var sortedForYou: [SmartRecord] {
        store.records.values
            .filter { $0.status == .applied && smartRule(for: $0) != nil }
            .sorted { ($0.decidedAt, $1.key) > ($1.decidedAt, $0.key) }
    }

    /// What smart categories said about an app or site, while it still
    /// stands: applied and in place, or waiting for the person.
    func suggestion(for key: String) -> SmartRecord? {
        guard let record = store.records[key] else { return nil }
        switch record.status {
        case .applied:  return smartRule(for: record) != nil ? record : nil
        case .needsYou: return isUnsorted(record) ? record : nil
        case .accepted, .dismissed: return nil
        }
    }

    func recentVideos(limit: Int = 5) -> [VideoVerdict] {
        store.recentVideos(limit: limit)
    }

    // MARK: - Wiring

    /// Watches new activity and gives the classifier per-video verdicts.
    func attach(tracker: ActivityTracker) {
        tracker.onNewEvent = { [weak self] event in
            self?.noticed(bundleId: event.bundleIdentifier, appName: event.appName, url: event.url,
                          title: event.windowTitle, classification: event.classification ?? .neutral)
        }
        classifier.pageVerdict = { [weak self] url in self?.videoVerdict(for: url) }
        schedule(after: 60)
    }

    /// A new stretch of activity began. Something not sorted yet starts a
    /// batch a little later; a YouTube video waits for its verdict.
    func noticed(bundleId: String, appName: String, url: String?, title: String?, classification: Classification) {
        let record = ActivityRecord(start: .now, end: .now, bundleId: bundleId, appName: appName, title: nil, url: url,
                                    inSession: false, classification: classification)
        if classification == .focus {
            let name = record.host ?? appName
            recentFocus.removeAll { $0 == name }
            recentFocus.insert(name, at: 0)
            if recentFocus.count > 4 { recentFocus.removeLast() }
        }
        if let url, let id = YouTubeVideos.videoId(in: url) {
            noticeVideo(id, title: title)
        }
        guard isOn, bundleId != ActivityTracker.selfBundleId else { return }
        let key = record.key
        guard checkedKeys.insert(key).inserted, store.records[key] == nil,
              isUnsorted(bundleId: bundleId, host: record.host) else { return }
        schedule(after: Self.newItemDelay)
    }

    /// Runs a batch after `delay`, unless one is already on its way.
    func schedule(after delay: TimeInterval) {
        guard runTask == nil, isOn else { return }
        runTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.runTask = nil
            await self.run()
        }
    }

    // MARK: - Sorting

    /// Sorts what's new now. Returns the records it made.
    @discardableResult
    func run() async -> [SmartRecord] {
        guard isOn, !isWorking, let model = modelProvider() else { return [] }
        guard !isInSession() else {
            schedule(after: Self.sessionRetry)
            return []
        }
        isWorking = true
        defer { isWorking = false }

        let container = self.container
        let optedOut = self.optedOut()
        let days = Self.lookbackDays
        let at = now()
        let evidence = await Task.detached(priority: .utility) {
            SmartEvidenceBuilder.build(ActivityRecord.recent(in: container, days: days, now: at), optedOut: optedOut)
        }.value
        let candidates = Array(evidence.filter { item in
            item.seconds >= Self.minimumSeconds && item.bundleId != ActivityTracker.selfBundleId
                && store.records[item.key] == nil && isUnsorted(bundleId: item.bundleId, host: item.host)
        }.prefix(Self.maxPerRun))
        checkedKeys.removeAll()
        guard !candidates.isEmpty else { return [] }

        let verdicts = await SmartCategorizer.verdicts(for: candidates, model: model)
        let byKey = Dictionary(candidates.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var made: [SmartRecord] = []
        for verdict in verdicts {
            // The person may have sorted it while the model thought.
            guard let item = byKey[verdict.key], store.records[item.key] == nil,
                  isUnsorted(bundleId: item.bundleId, host: item.host) else { continue }
            let decision = SmartCategorizer.decide(verdict, evidence: item)
            made.append(SmartRecord(key: item.key, name: item.name, bundleId: item.bundleId, host: item.host,
                                    suggested: verdict.classification, sure: verdict.sure, reason: verdict.reason,
                                    hours: item.hours, status: decision == .apply ? .applied : .needsYou,
                                    decidedAt: now()))
        }
        let applied = made.filter { $0.status == .applied }
        for record in applied { insertRule(record) }
        for record in made { store.records[record.key] = record }
        store.save(to: defaults)
        if !applied.isEmpty { reclassify(keys: applied) }
        return made
    }

    /// Undo for something sorted on its own: its rule goes, its past
    /// activity goes back, and it isn't suggested again. False while
    /// Strict keeps it blocked.
    @discardableResult
    func undo(_ record: SmartRecord) -> Bool {
        if let rule = smartRule(for: record) {
            guard !(isStrictLocked() && rule.classification == .distraction) else { return false }
            context.delete(rule)
            Persistence.save(context)
            classifier.invalidate()
            reclassify(keys: [record])
        }
        setStatus(.dismissed, for: record.key)
        return true
    }

    /// The person picked a category for a guess (theirs from now on).
    @discardableResult
    func accept(_ record: SmartRecord, as classification: Classification) -> Bool {
        let done = record.host != nil
            ? classifier.setOverride(host: record.key, classification: classification)
            : classifier.setOverride(bundleId: record.key, classification: classification)
        if done { setStatus(.accepted, for: record.key) }
        return done
    }

    /// Leave it unsorted and don't suggest it again.
    func dismiss(_ record: SmartRecord) {
        setStatus(.dismissed, for: record.key)
    }

    /// Puts a smart rule back after the window's sort flow undid a pick.
    func restore(_ record: SmartRecord) {
        guard store.records[record.key]?.status == .applied, smartRule(for: record) == nil,
              isUnsorted(bundleId: record.bundleId, host: record.host) else { return }
        insertRule(record)
        reclassify(keys: [record])
    }

    func closeBanner() {
        store.bannerClosedAt = now()
        store.save(to: defaults)
    }

    /// Turns smart categories on; a free person's first time starts the trial.
    func turnOn() {
        startTrial(.smartCategories)
        isEnabled = true
    }

    /// Everything it remembers goes ("Erase everything").
    func erase() {
        store = SmartCategoryStore()
        store.save(to: defaults)
        pendingVideos = [:]
        checkedKeys = []
        recentFocus = []
    }

    // MARK: - YouTube video by video

    /// The verdict for a youtube.com video page, while video by video is on.
    func videoVerdict(for url: String) -> Classification? {
        guard isPerVideoOn, let id = YouTubeVideos.videoId(in: url) else { return nil }
        return store.videos[id]?.classification
    }

    func setPerVideo(_ on: Bool) {
        if on { startTrial(.youtubePerVideo) }
        perVideo = on
        defaults.set(on, forKey: Self.perVideoKey)
        // Past videos follow: their verdicts, or youtube.com's category again.
        reclassifyVideos(ids: nil)
    }

    /// The person's correction for one video; it stays as they said.
    func correct(_ videoId: String, as classification: Classification) {
        guard var verdict = store.videos[videoId] else { return }
        verdict.classification = classification
        verdict.byUser = true
        store.remember(verdict)
        store.save(to: defaults)
        reclassifyVideos(ids: [videoId])
    }

    private func noticeVideo(_ id: String, title: String?) {
        guard isPerVideoOn, store.videos[id] == nil, let title = YouTubeVideos.videoTitle(title) else { return }
        // The tab's title catches up a moment after the address changes:
        // the latest one wins.
        pendingVideos[id] = title
        guard videoTask == nil else { return }
        videoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.videoDelay))
            guard let self, !Task.isCancelled else { return }
            self.videoTask = nil
            await self.sortVideos()
        }
    }

    /// Asks about the videos waiting. Returns their verdicts.
    @discardableResult
    func sortVideos() async -> [VideoVerdict] {
        guard isPerVideoOn, let model = modelProvider(), !pendingVideos.isEmpty else { return [] }
        let pending = pendingVideos.sorted { $0.key < $1.key }
            .filter { store.videos[$0.key] == nil }
            .map { YouTubeVideos.Pending(videoId: $0.key, title: $0.value) }
        pendingVideos = [:]
        let verdicts = await YouTubeVideos.verdicts(for: pending, workingOn: recentFocus, model: model, now: now())
        guard !verdicts.isEmpty else { return [] }
        for verdict in verdicts where store.videos[verdict.videoId] == nil { store.remember(verdict) }
        store.save(to: defaults)
        reclassifyVideos(ids: Set(verdicts.map(\.videoId)))
        return verdicts
    }

    // MARK: - Rules and past activity

    /// Unsorted: no rule says what it is, built-in or the person's.
    func isUnsorted(bundleId: String, host: String?) -> Bool {
        if let host {
            return classifier.matchingRule(bundleId: "", windowTitle: nil, url: "https://\(host)/") == nil
        }
        return classifier.matchingRule(bundleId: bundleId, windowTitle: nil, url: nil) == nil
    }

    private func isUnsorted(_ record: SmartRecord) -> Bool {
        isUnsorted(bundleId: record.bundleId, host: record.host)
    }

    /// The smart rule that still decides this app or site.
    private func smartRule(for record: SmartRecord) -> AppRule? {
        let rule = record.host != nil
            ? classifier.matchingRule(bundleId: "", windowTitle: nil, url: "https://\(record.key)/")
            : classifier.matchingRule(bundleId: record.key, windowTitle: nil, url: nil)
        guard let rule, rule.priority == Self.rulePriority, rule.pattern == record.key else { return nil }
        return rule
    }

    private func insertRule(_ record: SmartRecord) {
        context.insert(AppRule(pattern: record.key, matchKind: record.host == nil ? .bundleId : .host,
                               classification: record.suggested, priority: Self.rulePriority))
    }

    private func setStatus(_ status: SmartRecord.Status, for key: String) {
        guard store.records[key] != nil else { return }
        store.records[key]?.status = status
        store.save(to: defaults)
    }

    /// Past activity of these apps and sites follows the rules as they are now.
    private func reclassify(keys records: [SmartRecord]) {
        Persistence.save(context)
        classifier.invalidate()
        let apps = records.filter { $0.host == nil }.map(\.key)
        let hosts = records.compactMap(\.host)
        var events: [ActivityEvent] = []
        if !apps.isEmpty {
            events += Persistence.fetch(context, FetchDescriptor<ActivityEvent>(
                predicate: #Predicate { apps.contains($0.bundleIdentifier) }))
        }
        if !hosts.isEmpty {
            events += Persistence.fetch(context, FetchDescriptor<ActivityEvent>(predicate: #Predicate { $0.url != nil }))
                .filter { event in
                    guard let host = event.url.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return false }
                    return hosts.contains { Classifier.host(host, matches: $0) }
                }
        }
        for event in events {
            event.classification = classifier.classify(bundleId: event.bundleIdentifier, windowTitle: event.windowTitle,
                                                       url: event.url)
        }
        Persistence.save(context)
        classifier.invalidate()
    }

    /// youtube.com videos follow their verdicts (or the site's category
    /// when video by video is off). Nil means every video.
    private func reclassifyVideos(ids: Set<String>?) {
        let events = Persistence.fetch(context, FetchDescriptor<ActivityEvent>(predicate: #Predicate { $0.url != nil }))
        var changed = false
        for event in events {
            guard let url = event.url, let id = YouTubeVideos.videoId(in: url), ids?.contains(id) ?? true else { continue }
            event.classification = classifier.classify(bundleId: event.bundleIdentifier, windowTitle: event.windowTitle, url: url)
            changed = true
        }
        guard changed else { return }
        Persistence.save(context)
        classifier.invalidate()
    }
}
