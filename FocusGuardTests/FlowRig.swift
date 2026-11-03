import SwiftData
import XCTest
@testable import FocusGuard

/// The parts of the app a session runs through, wired the way `AppState`
/// wires them, on an in-memory store and with nothing on screen. Tests drive
/// it with `look(at:)`, one tracker tick at a time, at times they choose.
@MainActor
final class FlowRig {
    typealias StubOverlay = EscalationEngineTests.StubOverlay
    typealias RecordingPresenter = EscalationEngineTests.RecordingPresenter

    // Made-up apps, so none of them can be what's really in front.
    static let editor = FrontmostApp(bundleId: "com.example.editor", name: "Editor", pid: 999_981)
    static let notes = FrontmostApp(bundleId: "com.example.notes", name: "Jotter", pid: 999_982)
    static let feed = FrontmostApp(bundleId: "com.example.feed", name: "Feed", pid: 999_983)
    static let safari = FrontmostApp(bundleId: "com.apple.Safari", name: "Safari", pid: 999_984)
    static let focusGuard = FrontmostApp(bundleId: ActivityTracker.selfBundleId, name: "FocusGuard", pid: 999_985)
    static let lockScreen = FrontmostApp(bundleId: "com.apple.loginwindow", name: "loginwindow", pid: 999_986)

    let container: ModelContainer
    let context: ModelContext
    let classifier: Classifier
    let tracker: ActivityTracker
    let sessions: SessionManager
    let overlay = StubOverlay()
    let nudges = RecordingPresenter()
    let engine: EscalationEngine
    /// Seconds since the last input, as the tracker reads it.
    var idle: TimeInterval = 0
    var title: String?
    /// What the browser extension reports for the browser in front.
    var tab: ExtensionTab?

    init(preset: DriftResponse = .standard) throws {
        container = try Self.makeContainer()
        context = container.mainContext
        classifier = Classifier(context: context)
        classifier.setOverride(bundleId: Self.editor.bundleId, classification: .focus)
        classifier.setOverride(bundleId: Self.notes.bundleId, classification: .neutral)
        classifier.setOverride(bundleId: Self.feed.bundleId, classification: .distraction)
        tracker = ActivityTracker(context: context, optOutCache: TitleOptOutCache(context: context), classifier: classifier)
        sessions = SessionManager(context: context, tracker: tracker)
        engine = EscalationEngine(presenter: nudges, overlay: overlay)
        use(preset)
        tracker.readWindowTitle = { [unowned self] _ in title }
        tracker.secondsSinceInput = { [unowned self] in idle }
        tracker.displayKeptAwake = { false }
        // Always answering for a browser keeps the tracker from asking the
        // real one over AppleScript, should one be what's really in front.
        tracker.extensionTab = { [unowned self] id in
            BrowserTabReader.isBrowser(bundleIdentifier: id) ? (tab ?? ExtensionTab(url: nil, title: nil)) : nil
        }
    }

    static func makeContainer() throws -> ModelContainer {
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self, DailyLimit.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    /// `DriftResponse.apply` also writes the setting, which would land in the
    /// real app's defaults when tests run on the owner's Mac.
    func use(_ preset: DriftResponse) {
        let values = preset.values
        engine.silenceThreshold = TimeInterval(values.silence)
        engine.notifyThreshold = TimeInterval(values.notify)
        engine.blockThreshold = TimeInterval(values.block)
        engine.strictMode = values.strict
    }

    /// One tracker tick, feeding the engine the way `AppState`'s `onTick` does.
    func look(at front: FrontmostApp, _ now: Date) {
        tracker.record(front, now: now)
        guard let snapshot = tracker.currentSnapshot, !tracker.isAway else { return }
        let observed = tracker.isFrontmostSelf ? snapshot.asNeutral(at: now) : snapshot.observed(at: now)
        let running = sessions.currentSession != nil && sessions.currentSession?.pausedAt == nil
        engine.observe(snapshot: observed, isInSession: running)
    }

    /// A tick a second on `front` for `seconds`, from `start`.
    func stay(on front: FrontmostApp, from start: Date, for seconds: Int) {
        for second in 0..<seconds { look(at: front, start.addingTimeInterval(TimeInterval(second))) }
    }

    /// "Let me through" on what's in front, at a test's own time (the block
    /// screen's button goes by the real clock).
    func letThrough(at now: Date) throws {
        overlay.dismiss()
        engine.takePass(for: try XCTUnwrap(tracker.currentSnapshot), now: now)
    }

    func events() -> [ActivityEvent] {
        Persistence.fetch(context, FetchDescriptor<ActivityEvent>(sortBy: [SortDescriptor(\.startedAt)]))
    }

    func save() throws { try context.save() }
}

extension ActivityEvent {
    /// Adds a finished event with its classification.
    @discardableResult
    static func add(to context: ModelContext, _ kind: Classification, from start: Date, seconds: TimeInterval,
                    app: FrontmostApp = FlowRig.editor, url: String? = nil, title: String? = nil,
                    session: Session? = nil) -> ActivityEvent {
        let event = ActivityEvent(startedAt: start, endedAt: start.addingTimeInterval(seconds),
                                  bundleIdentifier: app.bundleId, appName: app.name, windowTitle: title, url: url,
                                  session: session)
        event.classification = kind
        context.insert(event)
        return event
    }
}

extension Calendar {
    /// A Gregorian calendar in `zone`, weeks from Monday, whatever the Mac is set to.
    static func fixed(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
        calendar.firstWeekday = 2
        return calendar
    }

    func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        date(from: DateComponents(timeZone: timeZone, year: year, month: month, day: day,
                                  hour: hour, minute: minute, second: second)) ?? .distantPast
    }
}
