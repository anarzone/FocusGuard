import Foundation

/// A part of the day in whole local hours, `from` up to (not including) `to`.
struct CoachHours: Codable, Hashable, Sendable {
    let from: Int
    let to: Int

    static let morning = CoachHours(from: 0, to: 12)
    static let afternoon = CoachHours(from: 12, to: 17)
    static let evening = CoachHours(from: 17, to: 24)
    /// The whole day, for a change that isn't by the hour.
    static let allDay = CoachHours(from: 0, to: 24)
    /// The parts sessions are grouped into, in order.
    static let parts = [morning, afternoon, evening]

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return from <= hour && hour < to
    }

    /// "before noon", "between 12:00 and 17:00", "after 17:00".
    func phrase(locale: Locale = .current, calendar: Calendar = .current) -> String {
        func clock(_ hour: Int) -> String {
            let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date(timeIntervalSince1970: 0)) ?? .now
            return HabitFormat.time(date, locale: locale, calendar: calendar)
        }
        if from == 0 && to == 24 { return String(localized: "all day") }
        if from == 0 {
            if to == 12 { return String(localized: "before noon") }
            let end = clock(to)
            return String(localized: "before \(end)", comment: "A time in a sentence: Your sessions before 09:00 ...")
        }
        if to == 24 {
            let start = clock(from)
            return String(localized: "after \(start)", comment: "A time in a sentence: Your sessions after 17:00 ...")
        }
        let start = clock(from), end = clock(to)
        return String(localized: "between \(start) and \(end)", comment: "Times in a sentence: Your sessions between 12:00 and 17:00 ...")
    }
}

/// Something true about a week, worked out from the numbers alone. The
/// coach picks the strongest one each week; a model may only reword it.
enum CoachFinding: Equatable, Sendable {
    /// Sessions in one part of the day went much worse than in another.
    case timeOfDay(TimeOfDay)
    /// The same distraction, opened soon after most sessions ended.
    case afterSessions(AfterSessions)
    /// One day drifted far more than the others.
    case driftDay(DriftDay)
    /// Days whose first session started late focused less.
    case lateStarts(LateStarts)
    /// One day's sessions changed app far more often than usual.
    case switching(Switching)
    /// Sessions of one length went clearly better than longer ones.
    case sessionLength(SessionLength)
    /// Days with hours of calls focused clearly less.
    case meetingDays(MeetingDays)
    /// The same app led straight to the same distraction again and again.
    case appChain(AppChain)
    /// One weekday came in well below the rest, week after week.
    case weeklyRhythm(WeeklyRhythm)

    struct TimeOfDay: Equatable, Sendable {
        let weak: CoachHours
        let weakRate: Double
        let weakSessions: Int
        let strong: CoachHours
        let strongRate: Double
        let strongSessions: Int
        /// The weak sessions' drift after their 25th minute, as a share of all their drift.
        let lateDriftShare: Double
        /// The weak sessions' average length.
        let weakMinutes: Int
    }

    struct AfterSessions: Equatable, Sendable {
        let target: String
        let name: String
        let isSite: Bool
        /// Sessions it followed, of `sessions`.
        let count: Int
        let sessions: Int
        let withinMinutes: Int
        /// Average time a day on it, over the days with anything tracked.
        let dailySeconds: TimeInterval
    }

    struct DriftDay: Equatable, Sendable {
        let day: Date
        let drift: TimeInterval
        /// The other active days' average drift.
        let othersAverage: TimeInterval
        /// Where most of that day's drift went.
        let target: String
        let name: String
        let isSite: Bool
        let targetSeconds: TimeInterval
        /// Average time a day on it over the week's active days.
        let dailySeconds: TimeInterval
    }

    struct LateStarts: Equatable, Sendable {
        /// A first session at or after this clock time (minutes after
        /// midnight) counts as late.
        let cutoff: Int
        let lateDays: Int
        let earlyDays: Int
        /// Average focused time on late days, and on early ones.
        let lateFocus: TimeInterval
        let earlyFocus: TimeInterval
    }

    struct Switching: Equatable, Sendable {
        let day: Date
        /// Minutes in that day's sessions for each change of app, and the
        /// same over the other days.
        let minutesPerSwitch: Double
        let usualMinutesPerSwitch: Double
        let switches: Int
        /// The part of the day most of those sessions ran in.
        let hours: CoachHours
        /// The other days had no changes at all, so `usualMinutesPerSwitch`
        /// isn't a rate to quote.
        var noneOnOtherDays = false
    }

    struct SessionLength: Equatable, Sendable {
        /// The length that went best, and how its sessions went.
        let minutes: Int
        let rate: Double
        let sessions: Int
        /// Sessions at least 15 minutes longer.
        let longerRate: Double
        let longerSessions: Int
        /// Calendar weeks the sessions came from.
        let weeks: Int
    }

    struct MeetingDays: Equatable, Sendable {
        /// Days with at least `callHours` of calls, and the other days.
        let heavyDays: Int
        let otherDays: Int
        /// Average focused time a day on each.
        let heavyFocus: TimeInterval
        let otherFocus: TimeInterval
        let callHours: Int
    }

    struct AppChain: Equatable, Sendable {
        /// The app it started from (a bundle id) and its name.
        let source: String
        let sourceName: String
        /// The distraction it led to.
        let target: String
        let name: String
        let isSite: Bool
        let count: Int
        /// Average time a day on the distraction, over the days with anything tracked.
        let dailySeconds: TimeInterval
    }

    struct WeeklyRhythm: Equatable, Sendable {
        /// `Calendar` weekday: 1 is Sunday, 7 Saturday.
        let weekday: Int
        /// Weeks running it was the lowest.
        let weeks: Int
        /// Its average focused time, and the other days' in the same weeks.
        let focus: TimeInterval
        let othersFocus: TimeInterval
    }

    /// 0...1: how clear and how useful the finding is, to rank them.
    var strength: Double {
        switch self {
        case .timeOfDay(let f):
            let gap = f.strongRate - f.weakRate
            return min(1, gap / 0.35) * min(1, Double(min(f.weakSessions, f.strongSessions)) / 3)
        case .afterSessions(let f):
            return Double(f.count) / Double(max(1, f.sessions)) * min(1, Double(f.count) / 4) * 0.9
        case .driftDay(let f):
            return min(1, (f.drift - f.othersAverage) / max(1, f.drift)) * 0.8
        case .lateStarts(let f):
            return min(1, (f.earlyFocus - f.lateFocus) / max(1, f.earlyFocus)) * 0.75
        case .switching(let f):
            // Twice as often is a start; four times as often is as clear as it gets.
            let times = f.usualMinutesPerSwitch / max(0.1, f.minutesPerSwitch)
            return min(1, (times - 1) / 3) * 0.7
        case .sessionLength(let f):
            return min(1, (f.rate - f.longerRate) / 0.3) * min(1, Double(min(f.sessions, f.longerSessions)) / 4) * 0.85
        case .meetingDays(let f):
            return min(1, (f.otherFocus - f.heavyFocus) / max(1, f.otherFocus)) * 0.7
        case .appChain(let f):
            return min(1, Double(f.count) / 10) * 0.85
        case .weeklyRhythm(let f):
            return min(1, 1 - f.focus / max(1, f.othersFocus)) * 0.8
        }
    }
}

/// Finds the week's patterns with plain statistics, so whatever the coach
/// says is true of the user's own data.
enum CoachPatternFinder {
    /// Drift after this point in a session counts as late.
    static let lateInSession: TimeInterval = 25 * 60
    /// How soon after a session ends a distraction counts as "right after".
    static let afterSessionWindow: TimeInterval = 3 * 60

    /// Every pattern found, strongest first.
    /// - Parameters:
    ///   - data: the week to look at.
    ///   - history: a longer stretch ending with it, for the patterns that
    ///     need several weeks (session length, weekly rhythm) or a usual to
    ///     compare against (switching, call-heavy days). Nil: `data` alone.
    ///   - lateStartCutoff: minutes after midnight from which a day's first
    ///     session counts as late (10:00 by default).
    ///   - weekendsCount: whether weekends count as days of the week's rhythm.
    static func find(in data: CoachData, history: CoachData? = nil, lateStartCutoff: Int = 600,
                     weekendsCount: Bool = false, calendar: Calendar = .current) -> [CoachFinding] {
        let longer = history ?? data
        return [timeOfDay(data, calendar: calendar),
                afterSessions(data, calendar: calendar),
                driftDay(data, calendar: calendar),
                lateStarts(data, cutoff: lateStartCutoff, calendar: calendar),
                switching(data, history: longer, calendar: calendar),
                sessionLength(longer, calendar: calendar),
                meetingDays(longer, calendar: calendar),
                appChain(data, calendar: calendar),
                weeklyRhythm(longer, weekendsCount: weekendsCount, calendar: calendar)]
            .compactMap { $0 }
            .sorted { $0.strength > $1.strength }
    }

    // MARK: - Time of day

    /// Sessions, and rated time, each part of the day needs before it's
    /// compared: four 15-minute sessions say nothing about a time of day.
    static let timeOfDaySessions = 3
    static let timeOfDaySeconds: TimeInterval = 45 * 60

    /// The part of the day whose sessions ran at the lowest focus rate,
    /// against the one with the highest, 15 points apart or more.
    static func timeOfDay(_ data: CoachData, calendar: Calendar = .current) -> CoachFinding? {
        struct Part {
            var focus: TimeInterval = 0, drift: TimeInterval = 0, lateDrift: TimeInterval = 0
            var sessions = 0, minutes = 0
            var rate: Double { FocusRate.of(focused: focus, drifted: drift) }
        }
        let bySession = data.eventsBySession
        var parts: [CoachHours: Part] = [:]
        for session in data.sessions {
            guard let hours = CoachHours.parts.first(where: { $0.contains(session.start, calendar: calendar) }) else { continue }
            let events = bySession[session.id] ?? []
            let tally = CoachData.tally(events)
            guard tally.focus + tally.drift >= 5 * 60 else { continue }
            let lateFrom = session.start.addingTimeInterval(lateInSession)
            var part = parts[hours] ?? Part()
            part.focus += tally.focus
            part.drift += tally.drift
            part.lateDrift += events.filter { $0.kind == .distraction }
                .reduce(0) { $0 + max(0, $1.end.timeIntervalSince(max($1.start, lateFrom))) }
            part.sessions += 1
            part.minutes += session.minutes
            parts[hours] = part
        }
        let rated: [(CoachHours, Part)] = CoachHours.parts.compactMap { hours in
            guard let part = parts[hours], part.sessions >= timeOfDaySessions, part.focus + part.drift >= timeOfDaySeconds else { return nil }
            return (hours, part)
        }
        guard rated.count >= 2,
              let weak = rated.min(by: { $0.1.rate < $1.1.rate }),
              let strong = rated.max(by: { $0.1.rate < $1.1.rate }),
              strong.1.rate - weak.1.rate >= 0.15 else { return nil }
        return .timeOfDay(.init(
            weak: weak.0, weakRate: weak.1.rate, weakSessions: weak.1.sessions,
            strong: strong.0, strongRate: strong.1.rate, strongSessions: strong.1.sessions,
            lateDriftShare: weak.1.drift > 0 ? weak.1.lateDrift / weak.1.drift : 0,
            weakMinutes: weak.1.minutes / max(1, weak.1.sessions)
        ))
    }

    // MARK: - Right after sessions

    /// A stay this short after a session is a glance, not reaching for it.
    static let afterSessionMinimum: TimeInterval = 60

    /// The distraction opened first within 3 minutes of a session ending,
    /// when it's the same one after at least 3 sessions and half of them, and
    /// it comes to minutes a day.
    static func afterSessions(_ data: CoachData, calendar: Calendar = .current) -> CoachFinding? {
        guard data.sessions.count >= 4 else { return nil }
        let loose = data.events.filter { $0.session == nil && $0.kind == .distraction && $0.duration >= afterSessionMinimum }
            .sorted { $0.start < $1.start }
        var counts: [String: (name: String, isSite: Bool, count: Int)] = [:]
        for session in data.sessions {
            let window = session.end.addingTimeInterval(-1)...session.end.addingTimeInterval(afterSessionWindow)
            guard let first = loose.first(where: { window.contains($0.start) }) else { continue }
            let entry = counts[first.target] ?? (first.name, first.isSite, 0)
            counts[first.target] = (entry.name, entry.isSite, entry.count + 1)
        }
        guard let best = counts.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }),
              best.value.count >= 3,
              Double(best.value.count) / Double(data.sessions.count) >= 0.5 else { return nil }
        let total = data.events.filter { $0.target == best.key }.reduce(0) { $0 + $1.duration }
        return .afterSessions(.init(
            target: best.key, name: best.value.name, isSite: best.value.isSite,
            count: best.value.count, sessions: data.sessions.count,
            withinMinutes: Int(afterSessionWindow / 60),
            dailySeconds: total / Double(max(1, data.activeDays(calendar: calendar).count))
        ))
    }

    // MARK: - The day that drifted

    /// The day with the most drift, when it's well above the other days.
    static func driftDay(_ data: CoachData, calendar: Calendar = .current) -> CoachFinding? {
        let byDay = Dictionary(grouping: data.events) { calendar.startOfDay(for: $0.start) }
        guard byDay.count >= 3 else { return nil }
        let drift = byDay.mapValues { $0.filter { $0.kind == .distraction }.reduce(0) { $0 + $1.duration } }
        guard let worst = drift.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { return nil }
        let others = drift.filter { $0.key != worst.key }.map(\.value)
        let average = others.reduce(0, +) / Double(max(1, others.count))
        guard worst.value >= 45 * 60, worst.value >= average * 1.6, worst.value - average >= 30 * 60 else { return nil }

        let onDay = (byDay[worst.key] ?? []).filter { $0.kind == .distraction }
        let byTarget = Dictionary(grouping: onDay, by: \.target).mapValues { $0.reduce(0) { $0 + $1.duration } }
        guard let top = byTarget.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
              let sample = onDay.first(where: { $0.target == top.key }) else { return nil }
        let weekTotal = data.events.filter { $0.target == top.key }.reduce(0) { $0 + $1.duration }
        return .driftDay(.init(
            day: worst.key, drift: worst.value, othersAverage: average,
            target: top.key, name: sample.name, isSite: sample.isSite, targetSeconds: top.value,
            dailySeconds: weekTotal / Double(byDay.count)
        ))
    }

    // MARK: - Late starts

    /// Calls this long before a day's first session are why it started late.
    static let callsBeforeFirstSession: TimeInterval = 60 * 60

    /// Days whose first session started at or after `cutoff`, against days
    /// that started earlier, when the early ones focused clearly more. A day
    /// whose morning went on calls doesn't count: starting earlier wouldn't
    /// have been an option, and the call-heavy days pattern speaks to it.
    static func lateStarts(_ data: CoachData, cutoff: Int = 600, calendar: Calendar = .current) -> CoachFinding? {
        let firstByDay = Dictionary(grouping: data.sessions) { calendar.startOfDay(for: $0.start) }
            .compactMapValues { $0.map(\.start).min() }
        let focusByDay = Dictionary(grouping: data.events.filter { $0.kind == .focus }) { calendar.startOfDay(for: $0.start) }
            .mapValues { $0.reduce(0) { $0 + $1.duration } }
        let calls = data.events.filter(\.isCall).map { DateInterval(start: $0.start, end: $0.end) } + data.busy
        var late: [TimeInterval] = [], early: [TimeInterval] = []
        for (day, first) in firstByDay {
            let parts = calendar.dateComponents([.hour, .minute], from: first)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            if minute >= cutoff {
                let before = calls.compactMap { span -> DateInterval? in
                    let start = max(span.start, day), end = min(span.end, first)
                    return end > start ? DateInterval(start: start, end: end) : nil
                }
                guard CoachData.covered(before) < callsBeforeFirstSession else { continue }
                late.append(focusByDay[day] ?? 0)
            } else {
                early.append(focusByDay[day] ?? 0)
            }
        }
        guard late.count >= 2, early.count >= 2 else { return nil }
        let lateFocus = late.reduce(0, +) / Double(late.count)
        let earlyFocus = early.reduce(0, +) / Double(early.count)
        guard earlyFocus >= lateFocus * 1.3, earlyFocus - lateFocus >= 45 * 60 else { return nil }
        return .lateStarts(.init(cutoff: cutoff, lateDays: late.count, earlyDays: early.count,
                                 lateFocus: lateFocus, earlyFocus: earlyFocus))
    }

    // MARK: - Switching a lot

    /// The day in `data` whose sessions changed app at least twice as often
    /// as sessions on the other days of `history` (at most every 5 minutes,
    /// 10 changes or more). Going between two focus apps is just work, so
    /// only a change to or from something else counts.
    static func switching(_ data: CoachData, history: CoachData? = nil,
                          calendar: Calendar = .current) -> CoachFinding? {
        struct Day {
            var seconds: TimeInterval = 0
            var switches = 0
            var byPart: [CoachHours: TimeInterval] = [:]
        }
        var days: [Date: Day] = [:]
        for (_, events) in (history ?? data).eventsBySession {
            let ordered = events.sorted { $0.start < $1.start }
            for (index, event) in ordered.enumerated() {
                let day = calendar.startOfDay(for: event.start)
                var entry = days[day] ?? Day()
                entry.seconds += event.duration
                if let part = CoachHours.parts.first(where: { $0.contains(event.start, calendar: calendar) }) {
                    entry.byPart[part, default: 0] += event.duration
                }
                if index > 0, ordered[index - 1].target != event.target,
                   !(ordered[index - 1].kind == .focus && event.kind == .focus) { entry.switches += 1 }
                days[day] = entry
            }
        }
        let counted = days.filter { $0.value.seconds >= 20 * 60 }
        guard counted.count >= 4 else { return nil }

        var best: (finding: CoachFinding.Switching, times: Double)?
        for (day, entry) in counted where data.interval.start <= day && day < data.interval.end {
            guard entry.seconds >= 40 * 60, entry.switches >= 10 else { continue }
            let others = counted.filter { $0.key != day }.map(\.value)
            let otherMinutes = others.reduce(0) { $0 + $1.seconds } / 60
            let otherSwitches = others.reduce(0) { $0 + $1.switches }
            let mine = entry.seconds / 60 / Double(entry.switches)
            let usual = otherMinutes / Double(max(1, otherSwitches))
            let times = usual / mine
            guard mine <= 5, times >= 2, best.map({ times > $0.times }) ?? true,
                  let part = entry.byPart.max(by: { ($0.value, $1.key.from) < ($1.value, $0.key.from) }) else { continue }
            best = (.init(day: day, minutesPerSwitch: mine, usualMinutesPerSwitch: usual,
                          switches: entry.switches, hours: part.key, noneOnOtherDays: otherSwitches == 0), times)
        }
        return best.map { .switching($0.finding) }
    }

    // MARK: - Best session length

    /// The length whose sessions ran at least 12 points above sessions 15
    /// minutes longer or more, at 70% or better, over two weeks or more.
    static func sessionLength(_ data: CoachData, calendar: Calendar = .current) -> CoachFinding? {
        struct Rated {
            let minutes: Int
            let focus: TimeInterval
            let drift: TimeInterval
            let week: Date
        }
        let bySession = data.eventsBySession
        let rated: [Rated] = data.sessions.compactMap { session in
            let tally = CoachData.tally(bySession[session.id] ?? [])
            guard tally.focus + tally.drift >= 5 * 60,
                  let week = calendar.dateInterval(of: .weekOfYear, for: session.start)?.start else { return nil }
            // The planned length, unless the session ended well short of it.
            let planned = session.plannedMinutes.flatMap { session.minutes * 10 >= $0 * 8 ? $0 : nil }
            let minutes = planned ?? Int((Double(session.minutes) / 5).rounded()) * 5
            guard (10...180).contains(minutes) else { return nil }
            return Rated(minutes: minutes, focus: tally.focus, drift: tally.drift, week: week)
        }
        let weeks = Set(rated.map(\.week)).count
        guard weeks >= 2 else { return nil }
        func rate(_ sessions: [Rated]) -> Double {
            FocusRate.of(focused: sessions.reduce(0) { $0 + $1.focus }, drifted: sessions.reduce(0) { $0 + $1.drift })
        }

        // The one that really went best: the widest gap to longer ones can
        // belong to a length that others beat.
        let lengths = Set(rated.map(\.minutes)).filter { minutes in rated.filter { $0.minutes == minutes }.count >= 3 }
        guard let minutes = lengths.max(by: { a, b in
            (rate(rated.filter { $0.minutes == a }), b) < (rate(rated.filter { $0.minutes == b }), a)
        }) else { return nil }
        let at = rated.filter { $0.minutes == minutes }
        let longer = rated.filter { $0.minutes >= minutes + 15 }
        guard longer.count >= 3, Set(at.map(\.week)).count >= 2 else { return nil }
        let atRate = rate(at), longerRate = rate(longer)
        guard atRate >= 0.7, atRate - longerRate >= 0.12 else { return nil }
        return .sessionLength(.init(minutes: minutes, rate: atRate, sessions: at.count,
                                    longerRate: longerRate, longerSessions: longer.count, weeks: weeks))
    }

    // MARK: - Meeting-heavy days

    /// A day with this much of calls counts as call-heavy.
    static let callHeavySeconds: TimeInterval = 3 * 3600

    /// Days with 3 hours of calls or more against the other days, when they
    /// focused at most 70% as much and 45 minutes less or more.
    static func meetingDays(_ data: CoachData, calendar: Calendar = .current) -> CoachFinding? {
        let calls = data.callSecondsByDay(calendar: calendar)
        let tracked = data.trackedByDay(calendar: calendar)
        let focus = data.focusByDay(calendar: calendar)
        var heavy: [TimeInterval] = [], other: [TimeInterval] = []
        for day in Set(tracked.keys).union(calls.keys) {
            let callTime = calls[day] ?? 0
            if callTime >= callHeavySeconds {
                heavy.append(focus[day] ?? 0)
            } else if (tracked[day] ?? 0) >= 30 * 60 {
                other.append(focus[day] ?? 0)
            }
        }
        guard heavy.count >= 2, other.count >= 2 else { return nil }
        let heavyFocus = heavy.reduce(0, +) / Double(heavy.count)
        let otherFocus = other.reduce(0, +) / Double(other.count)
        guard heavyFocus <= otherFocus * 0.7, otherFocus - heavyFocus >= 45 * 60 else { return nil }
        return .meetingDays(.init(heavyDays: heavy.count, otherDays: other.count, heavyFocus: heavyFocus,
                                  otherFocus: otherFocus, callHours: Int(callHeavySeconds / 3600)))
    }

    // MARK: - One app leads to another

    /// A distraction counts as opened from an app when it came within this
    /// long of the app, quick hops (a redirect, a new tab) aside.
    static let chainGap: TimeInterval = 15

    /// The same app (one that's neither focus nor a distraction, like Slack)
    /// leading straight to the same distraction 5 times or more.
    static func appChain(_ data: CoachData, calendar: Calendar = .current) -> CoachFinding? {
        let events = data.events.sorted { $0.start < $1.start }
        func isHop(_ event: CoachEvent) -> Bool {
            event.duration < 10 && event.kind != .distraction
                && (event.isSite || BrowserTabReader.isBrowser(bundleIdentifier: event.target))
        }
        var counts: [String: (source: CoachEvent, target: CoachEvent, count: Int)] = [:]
        for index in events.indices.dropFirst() where events[index].kind == .distraction {
            let event = events[index]
            guard events[index - 1].target != event.target else { continue }
            var back = index - 1
            while back > 0, index - back <= 3, isHop(events[back]) { back -= 1 }
            let source = events[back]
            guard source.kind == .neutral, !source.isSite, !BrowserTabReader.isBrowser(bundleIdentifier: source.target),
                  event.start.timeIntervalSince(source.end) <= chainGap else { continue }
            let key = source.target + "\u{1}" + event.target
            counts[key] = (source, event, (counts[key]?.count ?? 0) + 1)
        }
        guard let best = counts.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }),
              best.value.count >= 5 else { return nil }
        let target = best.value.target
        let total = data.events.filter { $0.target == target.target }.reduce(0) { $0 + $1.duration }
        return .appChain(.init(source: best.value.source.target, sourceName: best.value.source.name,
                               target: target.target, name: target.name, isSite: target.isSite,
                               count: best.value.count,
                               dailySeconds: total / Double(max(1, data.activeDays(calendar: calendar).count))))
    }

    // MARK: - Weekly rhythm

    /// One weekday was the lowest of its week, at 60% of the other days or
    /// less, in each of the last `weeks` whole weeks of `data`. Days with
    /// under half an hour tracked don't count; weekends only when they
    /// count toward the goal. Days level with it mean it isn't the weakest.
    static func weeklyRhythm(_ data: CoachData, weeks: Int = 3, weekendsCount: Bool = false,
                             calendar: Calendar = .current) -> CoachFinding? {
        var spans: [DateInterval] = []
        var cursor = calendar.dateInterval(of: .weekOfYear, for: data.interval.end.addingTimeInterval(-1))
        while let week = cursor, spans.count < weeks, week.end > data.interval.start {
            if week.start >= data.interval.start && week.end <= data.interval.end { spans.append(week) }
            cursor = calendar.dateInterval(of: .weekOfYear, for: week.start.addingTimeInterval(-1))
        }
        guard spans.count == weeks else { return nil }
        let tracked = data.trackedByDay(calendar: calendar)
        let focus = data.focusByDay(calendar: calendar)

        var weekday: Int?
        var low: [TimeInterval] = [], rest: [TimeInterval] = []
        for week in spans {
            let days = tracked.filter { day, seconds in
                week.start <= day && day < week.end && seconds >= 30 * 60
                    && (weekendsCount || !calendar.isDateInWeekend(day))
            }.map { (weekday: calendar.component(.weekday, from: $0.key), focus: focus[$0.key] ?? 0) }
            guard days.count >= 3,
                  let lowest = days.min(by: { ($0.focus, $0.weekday) < ($1.focus, $1.weekday) }),
                  weekday == nil || weekday == lowest.weekday else { return nil }
            let others = days.filter { $0.weekday != lowest.weekday }.map(\.focus)
            let othersAverage = others.reduce(0, +) / Double(max(1, others.count))
            guard othersAverage >= 3600, lowest.focus <= othersAverage * 0.6,
                  !days.contains(where: { $0.weekday != lowest.weekday && $0.focus - lowest.focus < 10 * 60 }) else { return nil }
            weekday = lowest.weekday
            low.append(lowest.focus)
            rest.append(othersAverage)
        }
        guard let weekday else { return nil }
        return .weeklyRhythm(.init(weekday: weekday, weeks: weeks, focus: low.reduce(0, +) / Double(low.count),
                                   othersFocus: rest.reduce(0, +) / Double(rest.count)))
    }
}
