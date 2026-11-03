import SwiftData
import XCTest
@testable import FocusGuard

/// The tracker's events under event-driven pace (#81): durations come from
/// when things happened, a switch ends the old event exactly where the new
/// one starts, and sleep, lock and screens off end it at that moment.
@MainActor
final class FlowTrackerTests: XCTestCase {
    private typealias Rig = FlowRig

    /// A small generator with a fixed seed, so a failure repeats.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Thousands of switches, title changes, trips to FocusGuard, lock
    /// screens and absences, a look at each at a random gap. The events must
    /// line up with what an independent count of the same run says.
    func testAnyRunOfSwitchesAddsUpToWhatHappened() throws {
        for seed in UInt64(1)...5 {
            var random = SplitMix(state: seed)
            let rig = try Rig()
            let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
            var now = start

            // The independent count: what's open, and time per app.
            var open: (app: String, title: String?, since: Date)?
            var expected: [String: TimeInterval] = [:]
            func close(at date: Date) {
                if let current = open { expected[current.app, default: 0] += max(0, date.timeIntervalSince(current.since)) }
                open = nil
            }

            for _ in 0..<4000 {
                now = now.addingTimeInterval(Double.random(in: 0.05...30, using: &random))
                let roll = Int.random(in: 0..<100, using: &random)
                let front: FrontmostApp
                switch roll {
                case 0..<35: front = Rig.editor
                case 35..<60: front = Rig.notes
                case 60..<80: front = Rig.feed
                case 80..<90: front = Rig.focusGuard
                case 90..<93: front = Rig.lockScreen
                default: front = open.flatMap { current in [Rig.editor, Rig.notes, Rig.feed].first { $0.bundleId == current.app } } ?? Rig.editor
                }
                rig.title = Bool.random(using: &random) ? nil : "Title \(Int.random(in: 0..<3, using: &random))"
                let away = Int.random(in: 0..<50, using: &random) == 0
                rig.idle = away ? 300 + min(now.timeIntervalSince(start), 5) : 0

                rig.tracker.record(front, now: now)

                if front.bundleId == Rig.lockScreen.bundleId {
                    close(at: now)
                } else if away {
                    if let current = open {
                        close(at: max(current.since, now.addingTimeInterval(-rig.idle)))
                    }
                } else if front.bundleId == Rig.focusGuard.bundleId {
                    close(at: now)
                } else if let current = open, current.app == front.bundleId, current.title == rig.title {
                    // Goes on.
                } else {
                    close(at: now)
                    open = (front.bundleId, rig.title, now)
                }
            }
            rig.tracker.flush(now: now)
            close(at: now)

            let events = rig.events()
            XCTAssertFalse(events.isEmpty)
            var previousEnd = Date.distantPast
            var actual: [String: TimeInterval] = [:]
            for event in events {
                XCTAssertGreaterThanOrEqual(event.endedAt, event.startedAt, "seed \(seed)")
                XCTAssertGreaterThanOrEqual(event.startedAt, previousEnd, "seed \(seed): events overlap")
                previousEnd = event.endedAt
                XCTAssertNotEqual(event.bundleIdentifier, ActivityTracker.selfBundleId)
                XCTAssertNotEqual(event.bundleIdentifier, Rig.lockScreen.bundleId)
                actual[event.bundleIdentifier, default: 0] += event.duration
            }
            for app in [Rig.editor, Rig.notes, Rig.feed] {
                XCTAssertEqual(actual[app.bundleId] ?? 0, expected[app.bundleId] ?? 0, accuracy: 0.001, "seed \(seed): \(app.name)")
            }
        }
    }

    func testASwitchEndsTheOldEventExactlyWhereTheNewOneStarts() throws {
        let rig = try Rig()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let apps = [Rig.editor, Rig.feed, Rig.notes, Rig.editor, Rig.feed]
        for (index, app) in apps.enumerated() {
            rig.tracker.record(app, now: start.addingTimeInterval(Double(index) * 0.2))
        }
        rig.tracker.flush(now: start.addingTimeInterval(1))
        let events = rig.events()
        XCTAssertEqual(events.count, apps.count)
        for (one, next) in zip(events, events.dropFirst()) { XCTAssertEqual(one.endedAt, next.startedAt) }
    }

    func testRestingLooksFarApartStillCountEveryThingBetweenThem() throws {
        let rig = try Rig()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // A look every 10 s, the resting pace.
        for look in 0...30 { rig.tracker.record(Rig.editor, now: start.addingTimeInterval(Double(look) * 10)) }
        rig.tracker.record(Rig.notes, now: start.addingTimeInterval(304))
        XCTAssertEqual(rig.events().first?.duration, 304)
    }

    func testAwayAndBackLeaveAGap() throws {
        let rig = try Rig()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        rig.tracker.record(Rig.editor, now: start)
        rig.idle = 300
        rig.tracker.record(Rig.editor, now: start.addingTimeInterval(400))
        XCTAssertTrue(rig.tracker.isAway)
        // Still away, more looks: nothing grows, nothing new.
        rig.idle = 600
        rig.tracker.record(Rig.editor, now: start.addingTimeInterval(700))
        rig.idle = 0
        rig.tracker.record(Rig.editor, now: start.addingTimeInterval(710))
        XCTAssertFalse(rig.tracker.isAway)
        rig.tracker.flush(now: start.addingTimeInterval(720))
        let events = rig.events()
        XCTAssertEqual(events.map(\.duration), [100, 10])
        XCTAssertEqual(events[1].startedAt, start.addingTimeInterval(710))
    }

    func testAVideoKeepingTheDisplayAwakeIsntAway() throws {
        let rig = try Rig()
        rig.tracker.displayKeptAwake = { true }
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        rig.tracker.record(Rig.feed, now: start)
        rig.idle = 1800
        rig.tracker.record(Rig.feed, now: start.addingTimeInterval(1800))
        XCTAssertFalse(rig.tracker.isAway)
        XCTAssertEqual(rig.events().first?.duration, 1800)
    }

    func testTheLockScreenEndsTheEventAtItsFirstLook() throws {
        let rig = try Rig()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        rig.tracker.record(Rig.editor, now: start)
        rig.tracker.record(Rig.lockScreen, now: start.addingTimeInterval(5))
        rig.tracker.record(Rig.lockScreen, now: start.addingTimeInterval(3600))
        rig.tracker.record(Rig.editor, now: start.addingTimeInterval(3700))
        rig.tracker.flush(now: start.addingTimeInterval(3701))
        XCTAssertEqual(rig.events().map(\.duration), [5, 1])
    }

    func testPageAndTitleChangesInOneAppAreOneStretchEach() throws {
        let rig = try Rig()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        rig.tab = ExtensionTab(url: "https://a.example/one", title: "One")
        rig.tracker.record(Rig.safari, now: start)
        rig.tab = ExtensionTab(url: "https://a.example/two", title: "Two")
        rig.tracker.record(Rig.safari, now: start.addingTimeInterval(4))
        rig.tab = ExtensionTab(url: "https://a.example/two", title: "Two")
        rig.tracker.record(Rig.safari, now: start.addingTimeInterval(9))
        rig.tracker.flush(now: start.addingTimeInterval(10))
        let events = rig.events()
        XCTAssertEqual(events.map(\.url), ["https://a.example/one", "https://a.example/two"])
        XCTAssertEqual(events.map(\.duration), [4, 6])
    }

    // MARK: - Limits against the tracker's own record

    private func limits(_ rig: Rig, now: Date) -> DailyLimitsEngine {
        DailyLimitsEngine(context: rig.context, notifier: DailyLimitsEngineTests.RecordingNotifier(), overlay: rig.overlay,
                          policy: { .standard }, calendar: .fixed("UTC"), now: now)
    }

    private func tickLimits(_ rig: Rig, _ engine: DailyLimitsEngine, _ front: FrontmostApp, _ now: Date) {
        rig.tracker.record(front, now: now)
        engine.observe(snapshot: rig.tracker.currentSnapshot,
                       counting: !rig.tracker.isFrontmostSelf && !rig.tracker.isAway,
                       awaySince: rig.tracker.isAway ? rig.tracker.lastActiveAt : nil, now: now)
    }

    func testALimitsCountMatchesTheEventsThroughSwitches() throws {
        let rig = try Rig()
        let start = Calendar.fixed("UTC").at(2026, 11, 2, 10)
        let engine = limits(rig, now: start)
        let limit = try XCTUnwrap(engine.addLimit(target: Rig.feed.bundleId, isSite: false, minutes: 60, now: start))
        var now = start
        for (app, seconds) in [(Rig.feed, 120), (Rig.editor, 60), (Rig.feed, 45), (Rig.focusGuard, 30), (Rig.feed, 15), (Rig.notes, 10)] {
            for _ in 0..<seconds {
                tickLimits(rig, engine, app, now)
                now = now.addingTimeInterval(1)
            }
        }
        XCTAssertEqual(engine.status(for: limit.id)?.used ?? 0, 180, accuracy: 2)
        try rig.save()
        // A relaunch reads the same time back from the events.
        let again = limits(rig, now: now)
        XCTAssertEqual(again.status(for: limit.id)?.used ?? 0, 180, accuracy: 2)
    }

    /// Away is only known after five quiet minutes. The tracker takes those
    /// back (the event ends at the last input), and so does the limit.
    func testALimitDoesntCountTheQuietMinutesBeforeAway() throws {
        let rig = try Rig()
        let start = Calendar.fixed("UTC").at(2026, 11, 2, 10)
        let engine = limits(rig, now: start)
        let limit = try XCTUnwrap(engine.addLimit(target: Rig.feed.bundleId, isSite: false, minutes: 60, now: start))
        for second in 0..<60 { tickLimits(rig, engine, Rig.feed, start.addingTimeInterval(TimeInterval(second))) }
        // Walks off: no input from here. Five minutes later the Mac says away.
        for second in 0...300 {
            rig.idle = TimeInterval(second)
            tickLimits(rig, engine, Rig.feed, start.addingTimeInterval(TimeInterval(60 + second)))
        }
        XCTAssertTrue(rig.tracker.isAway)
        XCTAssertEqual(rig.events().reduce(0) { $0 + $1.duration }, 60, accuracy: 1, "the record stops at the last input")
        XCTAssertEqual(engine.status(for: limit.id)?.used ?? 0, 60, accuracy: 2)
    }
}
