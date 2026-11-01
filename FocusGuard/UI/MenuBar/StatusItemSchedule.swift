import Foundation

/// When a whole-minute count shown somewhere (the menu-bar label, the
/// Control Center control) next changes by itself, so its owner can wake
/// then instead of every second.
enum MinuteClock {
    /// Seconds until a running count's whole minutes go up: at 119.5 s
    /// elapsed, 0.5. Also when "minutes left" of a timed session goes down,
    /// since its length is whole minutes.
    static func untilNextMinute(elapsed: TimeInterval) -> TimeInterval {
        let into = elapsed.truncatingRemainder(dividingBy: 60)
        return 60 - max(0, into)
    }

    /// Seconds until a countdown shown rounded up ("5m" from 4:01 to 5:00
    /// left) drops a minute; nil once it's run out.
    static func untilMinuteDrops(remaining: TimeInterval) -> TimeInterval? {
        guard remaining > 0 else { return nil }
        return remaining - 60 * ((remaining / 60).rounded(.up) - 1)
    }

    /// Seconds until a countdown shown in whole seconds, rounded up, drops one.
    static func untilSecondDrops(remaining: TimeInterval) -> TimeInterval? {
        guard remaining > 0 else { return nil }
        return remaining - (remaining.rounded(.up) - 1)
    }
}

/// When the status item next changes on its own — the minutes beside it,
/// the shield filling a step, a drift outlasting its silence window, a
/// pass's seconds, the recap giving way to ready — so `MenuBarController`
/// redraws then rather than polling every second. Changes of state (a
/// session starting, a pause, a drift starting) it observes instead.
enum StatusItemSchedule {
    struct Inputs: Equatable {
        /// A session running (not paused): seconds so far and its planned length.
        var elapsed: TimeInterval?
        var planned: TimeInterval?
        /// Seconds left on a break.
        var breakRemaining: TimeInterval?
        /// Seconds left on a "Let me through" pass.
        var passRemaining: TimeInterval?
        /// Seconds until a drift in progress shows in the menu bar.
        var driftShowsIn: TimeInterval?
        /// Seconds until the finished session's recap gives way to ready.
        var recapEndsIn: TimeInterval?
    }

    /// A hair past the boundary, so the redraw lands after the change.
    static let slack: TimeInterval = 0.05

    /// Seconds until the next change; nil when nothing changes by itself.
    static func delay(_ inputs: Inputs) -> TimeInterval? {
        var candidates: [TimeInterval?] = [
            inputs.breakRemaining.flatMap(MinuteClock.untilMinuteDrops),
            inputs.passRemaining.flatMap(MinuteClock.untilSecondDrops),
            inputs.driftShowsIn,
            inputs.recapEndsIn,
        ]
        if let elapsed = inputs.elapsed {
            candidates.append(MinuteClock.untilNextMinute(elapsed: elapsed))
            candidates.append(inputs.planned.flatMap { untilNextFillStep(elapsed: elapsed, planned: $0) })
        }
        guard let soonest = candidates.compactMap({ $0 }).filter({ $0 > 0 }).min() else { return nil }
        return soonest + slack
    }

    /// Seconds until the shield's fill rises a step (`StatusGlyphState.fillSteps`
    /// steps across the planned length); nil once it's full.
    static func untilNextFillStep(elapsed: TimeInterval, planned: TimeInterval) -> TimeInterval? {
        guard planned > 0, elapsed < planned else { return nil }
        let steps = Double(StatusGlyphState.fillSteps)
        let step = (max(0, elapsed) / planned * steps).rounded(.down) + 1
        return step * planned / steps - elapsed
    }
}

extension AppState {
    /// Seconds until the status item changes by itself (see `StatusItemSchedule`).
    func statusItemChangeDelay(now: Date = .now) -> TimeInterval? {
        var inputs = StatusItemSchedule.Inputs()
        if let state = breakManager.current {
            inputs.breakRemaining = state.remaining(now: now)
        } else if let session = sessionManager.currentSession {
            guard session.pausedAt == nil else { return nil }
            inputs.elapsed = sessionManager.runningSeconds(for: session, now: now)
            inputs.planned = session.plannedDurationMinutes.map { TimeInterval($0 * 60) }
            inputs.passRemaining = runningPass(now: now)?.remaining(now: now)
            if let since = escalationEngine.currentStreakStartedAt,
               tracker.currentSnapshot?.classification == .distraction {
                inputs.driftShowsIn = since.addingTimeInterval(escalationEngine.silenceThreshold).timeIntervalSince(now)
            }
        } else if let recap {
            inputs.recapEndsIn = recap.endedAt.addingTimeInterval(SessionRecap.shelfLife).timeIntervalSince(now)
        }
        return StatusItemSchedule.delay(inputs)
    }
}
