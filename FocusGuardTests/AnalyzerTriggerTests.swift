import XCTest
@testable import FocusGuard

/// What sets lost focus off: the place before it, then the distraction; a
/// wait the user drifted in; moments the user rules out; the waits by project.
@MainActor
final class AnalyzerTriggerTests: XCTestCase {
    typealias F = CoachFixture
    let calendar = CoachFixture.calendar

    private func event(_ day: Int, _ h: Int, _ m: Int, _ minutes: Double, _ kind: Classification, _ target: String) -> CoachEvent {
        let start = F.at(day, h, m)
        return CoachEvent(start: start, end: start.addingTimeInterval(minutes * 60), kind: kind, target: target, name: target,
                          isSite: target.contains(".") && !target.hasPrefix("com."), session: nil, bundleId: nil)
    }

    /// Work, the drift, then work again.
    private func day(_ day: Int, before: String = "com.terminal", via: String? = nil, to: String = "x.com") -> AnalyzerDay {
        var events = [event(day, 9, 0, 60, .focus, "com.xcode"), event(day, 10, 0, 3, .focus, before)]
        var at = 3
        if let via {
            events.append(event(day, 10, at, 3, .neutral, via))
            at += 3
        }
        events.append(event(day, 10, at, 9, .distraction, to))
        events.append(event(day, 10, at + 9, 60, .focus, "com.xcode"))
        return AnalyzerDayBuilder.make(day: F.at(day, 0), events: events, calendar: calendar)
    }

    func testALossKnowsWhatCameJustBeforeIt() {
        let loss = day(0).losses.first
        XCTAssertEqual(loss?.before?.name, "com.terminal")
        XCTAssertNil(loss?.opening, "It began on the distraction itself")
        XCTAssertEqual(day(0, via: "com.slack").losses.first?.opening?.name, "com.slack")
    }

    func testTheSamePlaceThenTheSameDistractionIsOneTrigger() {
        let days = (0..<3).map { day($0) }
        let triggers = AnalyzerTriggers.make(days: days, waits: [], ruledOut: [], calendar: calendar)
        XCTAssertEqual(triggers.count, 1)
        XCTAssertEqual(triggers.first?.steps.map(\.label), ["com.terminal", "x.com"])
        XCTAssertEqual(triggers.first?.count, 3)
        XCTAssertEqual(triggers.first?.perDay, [1, 1, 1])
        XCTAssertEqual(triggers.first.map { AnalyzerTriggers.title($0) }, "x.com after com.terminal")
    }

    func testAMessageAppItBeganInComesFirst() {
        let days = (0..<3).map { day($0, via: "com.slack", to: "youtube.com") }
        let trigger = AnalyzerTriggers.make(days: days, waits: [], ruledOut: [], calendar: calendar).first
        XCTAssertEqual(trigger?.steps.map(\.label), ["com.slack", "youtube.com"])
    }

    func testOnceIsNotAPattern() {
        XCTAssertEqual(AnalyzerTriggers.make(days: [day(0)], waits: [], ruledOut: [], calendar: calendar), [])
        XCTAssertEqual(AnalyzerTriggers.make(days: (0..<2).map { day($0) }, waits: [], ruledOut: [], calendar: calendar), [],
                       "Nor is twice")
    }

    func testThreeTimesOnOneDayIsNotAPatternEither() {
        let start = F.at(0, 0)
        var events: [CoachEvent] = []
        for index in 0..<3 {
            let base = 9 + index * 2
            events += [event(0, base, 0, 60, .focus, "com.xcode"), event(0, base + 1, 0, 3, .focus, "com.terminal"),
                       event(0, base + 1, 3, 9, .distraction, "x.com")]
        }
        events.append(event(0, 16, 0, 60, .focus, "com.xcode"))
        let day = AnalyzerDayBuilder.make(day: start, events: events, calendar: calendar)
        XCTAssertEqual(day.losses.count, 3)
        XCTAssertEqual(AnalyzerTriggers.make(days: [day], waits: [], ruledOut: [], calendar: calendar), [], "One bad day isn't a pattern")
    }

    func testADriftDuringAWaitCountsForTheWait() {
        let days = (0..<3).map { day($0) }
        let waits = (0..<3).map { index in
            WaitRecord(start: F.at(index, 10, 3), tool: "Codex", project: "curiplay", seconds: 540, drift: 540, to: "x.com")
        }
        let triggers = AnalyzerTriggers.make(days: days, waits: waits, ruledOut: [], calendar: calendar)
        XCTAssertEqual(triggers.count, 1, "Not counted twice")
        XCTAssertTrue(triggers.first?.isWait ?? false)
        XCTAssertEqual(triggers.first.map { AnalyzerTriggers.title($0) }, "x.com while you wait on Codex")
    }

    func testARuledOutMomentStopsCounting() {
        let days = (0..<4).map { day($0) }
        let first = AnalyzerTriggers.make(days: days, waits: [], ruledOut: [], calendar: calendar).first
        let moment = try? XCTUnwrap(first?.moments.first)
        let after = AnalyzerTriggers.make(days: days, waits: [], ruledOut: [moment?.id ?? ""], calendar: calendar).first
        XCTAssertEqual(after?.count, 3)
        XCTAssertEqual(after?.moments.count, 4, "Still listed, to undo")
        XCTAssertTrue(after?.moments.first?.isRuledOut ?? false)
    }

    func testRulingOutIsKeptAndUndone() {
        let defaults = UserDefaults(suiteName: "analyzer-triggers-\(UUID().uuidString)")!
        let moment = AnalyzerTrigger.Moment(start: F.at(0, 10, 3), seconds: 540)
        AnalyzerRuledOut.toggle(moment, defaults)
        XCTAssertEqual(AnalyzerRuledOut.load(defaults), [moment.id])
        AnalyzerRuledOut.toggle(moment, defaults)
        XCTAssertEqual(AnalyzerRuledOut.load(defaults), [])
    }

    func testSurenessGrowsWithTheDaysItsSeenOn() {
        var trigger = AnalyzerTrigger(id: "a", steps: [], moments: [], perDay: [1, 0, 0, 0, 0])
        XCTAssertEqual(trigger.sureness(workingDays: 5), 1)
        trigger.perDay = [1, 1, 0, 0, 0]
        XCTAssertEqual(trigger.sureness(workingDays: 5), 2)
        trigger.perDay = [1, 1, 1, 1, 0]
        XCTAssertEqual(trigger.sureness(workingDays: 5), 3)
    }

    func testWaitsAddUpByProject() {
        let now = F.at(0, 12, 0)
        let records = [
            WaitRecord(start: now, tool: "Codex", project: "Curiplay", seconds: 90, drift: 0),
            WaitRecord(start: now, tool: "Codex", project: "Curiplay", seconds: 600, drift: 500, to: "x.com"),
            WaitRecord(start: now, tool: "Codex", project: "Curiplay", seconds: 110, drift: 0),
            WaitRecord(start: now, tool: "Claude Code", project: nil, seconds: 100, drift: 0),
        ]
        let summary = AnalyzerWaitsSummary.make(records)
        XCTAssertEqual(summary.waits, 4)
        XCTAssertEqual(summary.drifted, 1)
        XCTAssertEqual(summary.projects.first?.name, "Curiplay")
        XCTAssertEqual(summary.projects.first?.stayed, 2)
        XCTAssertEqual(summary.averageWait, 100, accuracy: 0.1)
        XCTAssertEqual(summary.averageDrift, 500, accuracy: 0.1)
        XCTAssertEqual(summary.pullsAway?.tool, "Codex")
        XCTAssertEqual(AnalyzerWaitsSummary.make([]).waits, 0)
    }
}
