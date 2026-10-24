import XCTest
import SwiftData
@testable import FocusGuard

/// The snapshot the widgets and the Control Center control read: how it
/// runs ahead in a widget timeline, and what the control shows and does.
final class SurfaceSnapshotTests: XCTestCase {
    private let calendar = Calendar.current
    private lazy var noon = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600)

    private func snapshot(phase: SurfaceSnapshot.Phase, planned: TimeInterval? = 50 * 60,
                          running: TimeInterval = 20 * 60) -> SurfaceSnapshot {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: noon)?.start ?? noon
        let session = phase == .focusing || phase == .paused
            ? SurfaceSnapshot.Running(name: "Taxes", startedAt: noon.addingTimeInterval(-running), plannedSeconds: planned,
                                      runningSeconds: running, focused: 18 * 60, drifted: 2 * 60, other: 0,
                                      ring: "fffffffffffffffffdd" + "n" + String(repeating: ".", count: 30))
            : nil
        let onBreak = phase == .onBreak
            ? SurfaceSnapshot.Break(startedAt: noon.addingTimeInterval(-60), endsAt: noon.addingTimeInterval(9 * 60), canEndEarly: true)
            : nil
        return SurfaceSnapshot(
            writtenAt: noon, phase: phase, session: session, onBreak: onBreak,
            today: .init(start: calendar.startOfDay(for: noon), focused: 4 * 3600, drifted: 600, other: 0,
                         sessions: 3, goalSeconds: 4 * 3600, streak: 2),
            week: .init(start: weekStart, focused: Array(repeating: 3600, count: 7)),
            lastSession: nil, usualMinutes: 50
        )
    }

    // MARK: - Running ahead

    func testSessionTimeAdvancesOnlyWhileFocusing() {
        let running = snapshot(phase: .focusing)
        XCTAssertEqual(running.sessionEndsAt, noon.addingTimeInterval(30 * 60))
        XCTAssertEqual(running.timeLeft(at: noon.addingTimeInterval(600)) ?? 0, 20 * 60, accuracy: 0.1)
        XCTAssertEqual(running.sessionProgress(at: noon) ?? 0, 0.4, accuracy: 0.001)

        let paused = snapshot(phase: .paused)
        XCTAssertNil(paused.sessionEndsAt)
        XCTAssertEqual(paused.timeLeft(at: noon.addingTimeInterval(600)) ?? 0, 30 * 60, accuracy: 0.1)
    }

    func testATimedSessionEndsOnTime() {
        let s = snapshot(phase: .focusing)
        XCTAssertEqual(s.projected(to: noon.addingTimeInterval(29 * 60)).phase, .focusing)
        let after = s.projected(to: noon.addingTimeInterval(31 * 60))
        XCTAssertEqual(after.phase, .ready)
        XCTAssertNil(after.session)
        XCTAssertEqual(after.lastSession?.name, "Taxes")
        XCTAssertEqual(after.lastSession?.minutes, 50)
        XCTAssertEqual(after.lastSession?.focusRate ?? 0, 0.9, accuracy: 0.001)
    }

    func testOpenEndedAndPausedSessionsDontEnd() {
        XCTAssertEqual(snapshot(phase: .focusing, planned: nil).projected(to: noon.addingTimeInterval(5 * 3600)).phase, .focusing)
        XCTAssertEqual(snapshot(phase: .paused).projected(to: noon.addingTimeInterval(5 * 3600)).phase, .paused)
    }

    func testABreakEnds() {
        let s = snapshot(phase: .onBreak)
        XCTAssertEqual(s.projected(to: noon.addingTimeInterval(8 * 60)).phase, .onBreak)
        let after = s.projected(to: noon.addingTimeInterval(10 * 60))
        XCTAssertEqual(after.phase, .ready)
        XCTAssertNil(after.onBreak)
    }

    func testMidnightStartsTodayOver() {
        let s = snapshot(phase: .ready)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: s.today.start)!.addingTimeInterval(60)
        let next = s.projected(to: tomorrow)
        XCTAssertEqual(next.today.start, calendar.startOfDay(for: tomorrow))
        XCTAssertEqual(next.today.focused, 0)
        XCTAssertEqual(next.today.sessions, 0)
        XCTAssertEqual(next.today.goalSeconds, 4 * 3600)
        // The goal was met, so the streak grows by today.
        XCTAssertEqual(next.today.streak, 3)
        XCTAssertEqual(s.projected(to: noon).today, s.today)
    }

    func testANewWeekStartsEmpty() {
        let s = snapshot(phase: .ready)
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: s.week.start)!.addingTimeInterval(3600)
        let next = s.projected(to: nextWeek)
        XCTAssertEqual(next.week.focused, Array(repeating: 0, count: 7))
        XCTAssertEqual(next.weekIndex(of: nextWeek), 0)
        XCTAssertNil(s.weekIndex(of: nextWeek))
    }

    // MARK: - Timeline

    func testTimelineHasAnEntryEachMinuteUntilTheEnd() {
        let s = snapshot(phase: .focusing)
        let dates = s.timelineDates(now: noon, calendar: calendar)
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: noon))!
        XCTAssertEqual(dates.first, noon)
        XCTAssertTrue(dates.contains(noon.addingTimeInterval(30 * 60)), "an entry when the session ends")
        XCTAssertFalse(dates.contains(noon.addingTimeInterval(31 * 60)))
        XCTAssertEqual(dates.last, midnight)
        XCTAssertEqual(dates.count, 1 + 29 + 1 + 1, "now, 29 minutes, the end, midnight")
        XCTAssertEqual(dates, dates.sorted())
    }

    func testReadyTimelineIsNowAndMidnight() {
        XCTAssertEqual(snapshot(phase: .ready).timelineDates(now: noon, calendar: calendar).count, 2)
        XCTAssertEqual(snapshot(phase: .paused).timelineDates(now: noon, calendar: calendar).count, 2)
    }

    func testOpenEndedTimelineCoversAnHour() {
        let dates = snapshot(phase: .focusing, planned: nil).timelineDates(now: noon, calendar: calendar)
        XCTAssertEqual(dates.count, 1 + 59 + 1 + 1, "now, 59 minutes, the hour mark, midnight")
    }

    // MARK: - Control

    func testControlValue() {
        XCTAssertEqual(FocusControlValue.from(snapshot(phase: .ready), at: noon),
                       FocusControlValue(isOn: false, title: "FocusGuard", detail: "Start 50 min", symbol: "shield"))
        XCTAssertEqual(FocusControlValue.from(snapshot(phase: .focusing), at: noon.addingTimeInterval(11.5 * 60)),
                       FocusControlValue(isOn: true, title: "Taxes", detail: "19 min left", symbol: "shield.lefthalf.filled"))
        XCTAssertEqual(FocusControlValue.from(snapshot(phase: .paused), at: noon).detail, "Paused")
        XCTAssertEqual(FocusControlValue.from(snapshot(phase: .focusing, planned: nil), at: noon).detail, "20 min so far")
        let onBreak = FocusControlValue.from(snapshot(phase: .onBreak), at: noon)
        XCTAssertTrue(onBreak.isOn)
        XCTAssertEqual(onBreak.title, "Break")
        XCTAssertEqual(onBreak.symbol, "cup.and.saucer")
        XCTAssertFalse(FocusControlValue.from(nil, at: noon).isOn)
    }

    func testControlToggle() {
        XCTAssertEqual(SurfaceSnapshot.controlAction(turningOn: true, snapshot: snapshot(phase: .ready)), .start(minutes: 50))
        XCTAssertEqual(SurfaceSnapshot.controlAction(turningOn: true, snapshot: nil), .start(minutes: 50))
        XCTAssertNil(SurfaceSnapshot.controlAction(turningOn: true, snapshot: snapshot(phase: .focusing)))
        XCTAssertEqual(SurfaceSnapshot.controlAction(turningOn: false, snapshot: snapshot(phase: .focusing)), .end)
        XCTAssertEqual(SurfaceSnapshot.controlAction(turningOn: false, snapshot: snapshot(phase: .paused)), .end)
        XCTAssertEqual(SurfaceSnapshot.controlAction(turningOn: false, snapshot: snapshot(phase: .onBreak)), .endBreak)
        XCTAssertNil(SurfaceSnapshot.controlAction(turningOn: false, snapshot: snapshot(phase: .ready)))

        var strict = snapshot(phase: .onBreak)
        strict.onBreak?.canEndEarly = false
        XCTAssertNil(SurfaceSnapshot.controlAction(turningOn: false, snapshot: strict))
    }

    func testWords() {
        XCTAssertEqual(SurfaceWords.duration(135 * 60), "2h 15m")
        XCTAssertEqual(SurfaceWords.duration(4 * 3600), "4h")
        XCTAssertEqual(SurfaceWords.duration(59), "0m")
        XCTAssertEqual(SurfaceWords.minutesLeft(61), "2 min")
        XCTAssertEqual(SurfaceWords.minutesLeft(0), "0 min")
        XCTAssertEqual(SurfaceWords.stopwatch(18 * 60 + 23.2), "18:24")
        XCTAssertEqual(SurfaceWords.stopwatch(3909), "1:05:09")
    }

    // MARK: - Shared folder

    func testStoreRoundTripsTheSnapshotAndCommands() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SurfaceStoreTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = SurfaceStore(folder: folder)
        XCTAssertNil(store.readSnapshot())

        var written = snapshot(phase: .focusing)
        let first = SurfaceCommand(action: .start(minutes: 25), issuedAt: Date().addingTimeInterval(-2))
        let second = SurfaceCommand(action: .extendBreak(minutes: 5), issuedAt: Date().addingTimeInterval(-1))
        let stale = SurfaceCommand(action: .end, issuedAt: Date().addingTimeInterval(-SurfaceStore.commandShelfLife - 1))
        written.handled = [first.id]
        try store.write(written)
        XCTAssertEqual(store.readSnapshot(), written)
        XCTAssertTrue(store.isHandled(first.id))
        XCTAssertFalse(store.isHandled(second.id))

        try store.post(second)
        try store.post(stale)
        try store.post(first)
        XCTAssertEqual(store.takeCommands(), [first, second], "oldest first, stale ones dropped")
        XCTAssertEqual(store.takeCommands(), [], "taking clears the folder")
    }

    func testAnOlderSnapshotFormatIsIgnored() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SurfaceStoreTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = SurfaceStore(folder: folder)
        var old = snapshot(phase: .ready)
        old.version = 0
        try store.write(old)
        XCTAssertNil(store.readSnapshot())
    }
}

/// The app side: what goes into the snapshot, and what widget taps do.
@MainActor
final class SurfaceBuilderTests: XCTestCase {
    private var container: ModelContainer!
    private var sessions: SessionManager!
    private var breaks: BreakManager!
    private var defaults: UserDefaults!
    private let calendar = Calendar.current

    override func setUpWithError() throws {
        let suite = "SurfaceBuilderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let tracker = ActivityTracker(context: context, optOutCache: TitleOptOutCache(context: context), classifier: Classifier(context: context))
        sessions = SessionManager(context: context, tracker: tracker)
        breaks = BreakManager(defaults: defaults)
    }

    private var actions: FocusActions {
        FocusActions(sessions: sessions, breaks: breaks,
                     startBreak: { [breaks] in breaks?.startBreak(durationMinutes: $0) }, defaults: defaults)
    }

    private func numbers(now: Date) -> SurfaceStats.Numbers {
        SurfaceStats.Numbers(
            today: FocusNumbers.summary(.today, context: container.mainContext, now: now),
            week: .init(start: now, focused: Array(repeating: 0, count: 7)), last: nil, streak: 0
        )
    }

    private func build(now: Date = .now) -> SurfaceSnapshot {
        SurfaceSnapshotBuilder.make(
            sessions: sessions, breaks: breaks,
            timeline: { [sessions] session in
                SessionTimeline.build(segments: SessionTimeline.segments(from: session.events),
                                      elapsed: sessions!.runningSeconds(for: session, now: now),
                                      planned: session.plannedDurationMinutes.map { TimeInterval($0 * 60) },
                                      current: .focus)
            },
            numbers: numbers(now: now), goal: 4 * 3600, usualMinutes: 50, handled: [], now: now
        )
    }

    func testPhases() {
        XCTAssertEqual(build().phase, .ready)

        actions.start(minutes: 25, label: "Taxes")
        let focusing = build()
        XCTAssertEqual(focusing.phase, .focusing)
        XCTAssertEqual(focusing.session?.name, "Taxes")
        XCTAssertEqual(focusing.session?.plannedSeconds, 25 * 60)
        XCTAssertEqual(focusing.session?.ring.count, 25)
        XCTAssertEqual(focusing.session?.ring.first, "n")

        actions.pauseOrResume(.pause)
        XCTAssertEqual(build().phase, .paused)

        actions.takeBreak(minutes: 10)
        let onBreak = build()
        XCTAssertEqual(onBreak.phase, .onBreak)
        XCTAssertNil(onBreak.session)
        XCTAssertEqual(onBreak.onBreak?.canEndEarly, true)
    }

    func testSessionSplitAndRing() {
        let segments = [
            SessionTimeline.Segment(classification: .focus, seconds: 300),
            SessionTimeline.Segment(classification: .distraction, seconds: 60),
            SessionTimeline.Segment(classification: .neutral, seconds: 30),
            SessionTimeline.Segment(classification: .focus, seconds: 120),
        ]
        let split = SurfaceSnapshotBuilder.split(segments)
        XCTAssertEqual(split.focused, 420)
        XCTAssertEqual(split.drifted, 60)
        XCTAssertEqual(split.other, 30)

        let timeline = SessionTimeline(cells: [.focus, .drift, .other, .now(.focus), .future], minutesPerCell: 1)
        XCTAssertEqual(SurfaceSnapshotBuilder.ring(timeline), "fdon.")
    }

    func testWidgetTapsDoWhatTheMenuDoes() {
        SurfacesCoordinator.perform(.start(minutes: 25), with: actions)
        XCTAssertEqual(sessions.currentSession?.plannedDurationMinutes, 25)
        SurfacesCoordinator.perform(.togglePause, with: actions)
        XCTAssertNotNil(sessions.currentSession?.pausedAt)
        SurfacesCoordinator.perform(.togglePause, with: actions)
        XCTAssertNil(sessions.currentSession?.pausedAt)
        SurfacesCoordinator.perform(.end, with: actions)
        XCTAssertNil(sessions.currentSession)

        breaks.startBreak(durationMinutes: 10)
        SurfacesCoordinator.perform(.extendBreak(minutes: 5), with: actions)
        XCTAssertEqual(breaks.current?.plannedDuration, 15 * 60)
        SurfacesCoordinator.perform(.endBreak, with: actions)
        XCTAssertNil(breaks.current)
    }

    func testStatsReadTheWeekAndTheLastSession() async throws {
        let dayStart = calendar.startOfDay(for: Date())
        let now = dayStart.addingTimeInterval(12 * 3600)
        let session = Session(startedAt: dayStart.addingTimeInterval(60), label: "Taxes", plannedDurationMinutes: 25)
        session.endedAt = dayStart.addingTimeInterval(60 + 25 * 60)
        container.mainContext.insert(session)
        let event = ActivityEvent(startedAt: session.startedAt, endedAt: session.startedAt.addingTimeInterval(20 * 60),
                                  bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode", session: session)
        event.classification = .focus
        container.mainContext.insert(event)
        try container.mainContext.save()

        let stats = SurfaceStats(container: container)
        let read = await stats.read(now: now, goal: 4 * 3600)
        XCTAssertEqual(read.week.focused.count, 7)
        let todayIndex = calendar.dateComponents([.day], from: read.week.start, to: dayStart).day ?? -1
        XCTAssertEqual(read.week.focused[todayIndex], 20 * 60, accuracy: 2)
        XCTAssertEqual(read.week.focused.reduce(0, +), 20 * 60, accuracy: 2)
        XCTAssertEqual(read.last?.name, "Taxes")
        XCTAssertEqual(read.last?.minutes, 25)
        XCTAssertEqual(read.last?.focusRate ?? 0, 1, accuracy: 0.001)
    }
}
