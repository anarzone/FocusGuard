import Foundation

/// What a fix changes on On days. Each undoes exactly (`AnalyzerUndo`).
enum AnalyzerChange: Codable, Hashable, Sendable {
    /// A session starting with no goal asks for one line.
    case askForGoal
    /// A session starting says the plan again. Nothing else changes: there's
    /// no hold on messages to lean on, and FocusGuard can't read them.
    case messageReminder
    /// A daily limit on the top distraction.
    case dailyLimit(target: String, isSite: Bool, name: String, minutes: Int)
    /// A Focus block on the calendar, with the person's OK.
    case protectBlock(minutes: Int)
    /// The day's first session says the plan again, and the morning plan comes
    /// at this hour if it can come earlier.
    case hardestFirst(morningHour: Int?)
    /// Leaving this tool for this site while it works puts the site on hold
    /// for a while: its tab counts down, then opens by itself.
    case holdInWait(tool: String, site: String, seconds: Int)

    /// The if-then plan.
    var plan: String {
        switch self {
        case .askForGoal:
            return String(localized: "If a session starts with no goal, then I'll write one line first.")
        case .messageReminder:
            return String(localized: "If a message arrives during a session, then I'll read it at the next break.")
        case let .dailyLimit(_, _, name, minutes):
            return String(localized: "If I reach \(minutes) minutes on \(name) in a day, then I'll stop there.", comment: "An if-then plan. The name is a site or app")
        case let .protectBlock(minutes):
            return String(localized: "If a day has calls, then I'll keep \(minutes) minutes for one deep block.")
        case .hardestFirst:
            return String(localized: "If a task is hard, then I'll do it in my first session of the day.")
        case let .holdInWait(tool, site, seconds):
            return String(localized: "If \(tool) is working, then I'll wait \(max(1, seconds / 60)) minutes before \(site).",
                          comment: "An if-then plan. The tool, minutes, then the site")
        }
    }

    /// What the app does on On days.
    var onDays: String {
        switch self {
        case .askForGoal:
            return String(localized: "FocusGuard asks for a goal before each session")
        case .messageReminder:
            return String(localized: "FocusGuard reminds you of this plan when a session starts")
        case let .dailyLimit(_, _, name, minutes):
            return String(localized: "\(name) is blocked after \(minutes) minutes", comment: "The name is a site or app")
        case let .protectBlock(minutes):
            return String(localized: "FocusGuard adds a \(minutes)-minute Focus block to your calendar")
        case let .hardestFirst(hour?):
            let time = CoachExperiment.clock(hour)
            return String(localized: "The morning plan comes at \(time), and your first session reminds you of this plan")
        case .hardestFirst(nil):
            return String(localized: "Your first session of the day reminds you of this plan")
        case let .holdInWait(tool, site, seconds):
            return String(localized: "\(site) waits \(max(1, seconds / 60)) minutes when you leave \(tool) for it",
                          comment: "What happens on On days. The site, minutes, then the tool")
        }
    }
}

/// One fix for a cause, as a change the app can make and a measure to judge it.
struct AnalyzerFix: Codable, Hashable, Sendable {
    let cause: AnalyzerCause
    let change: AnalyzerChange
    let measure: AnalyzerMeasureKind
}

/// How to take a change back, exactly.
enum AnalyzerUndo: Codable, Equatable, Sendable {
    /// Nothing was changed: the app just reads the experiment.
    case nothing
    /// A limit or the morning plan's earlier values, as the coach undoes them.
    case coach(CoachUndo)
    /// The slot held on the calendar.
    case calendar(slot: Date)
}

/// One fix per cause, and only one the data supports.
enum AnalyzerFixes {
    /// What can be done right now.
    struct Context: Equatable, Sendable {
        var canUseCalendar = false
        var morningPlanHour = 9
        /// The coach keeps the morning plan's hour, so it can't be tested.
        var morningPlanTaken = false
        /// Sites and apps with a daily limit already.
        var limited: Set<String> = []
    }

    static func fix(for cause: AnalyzerCause, detail: AnalyzerCauseDetail, context: Context) -> AnalyzerFix? {
        guard detail.row.isSteady, !detail.row.isMuted else { return nil }
        switch cause {
        case .unclearTask:
            // Too few sessions, or almost all with a goal: asking would do
            // nothing. And goals that don't go with longer stretches here
            // aren't worth suggesting.
            guard detail.sessions >= AnalyzerRules.sessionsForAFix,
                  detail.goallessSessions >= AnalyzerRules.goallessForAFix else { return nil }
            if let with = detail.withGoal, let without = detail.withoutGoal, with.longest <= without.longest { return nil }
            return AnalyzerFix(cause: cause, change: .askForGoal, measure: .longestStretch)
        case .chatAndMail:
            guard detail.sessions >= AnalyzerRules.sessionsForAFix else { return nil }
            return AnalyzerFix(cause: cause, change: .messageReminder, measure: .longestStretch)
        case .habit:
            guard let top = detail.topDistraction,
                  let minutes = limitMinutes(perDay: detail.topDistractionPerDay),
                  !context.limited.contains(where: { $0 == top.target || (top.isSite && Classifier.host(top.target, matches: $0)) })
            else { return nil }
            return AnalyzerFix(cause: cause, change: .dailyLimit(target: top.target, isSite: top.isSite, name: top.name, minutes: minutes),
                               measure: .longestStretch)
        case .meetings:
            guard context.canUseCalendar else { return nil }
            return AnalyzerFix(cause: cause, change: .protectBlock(minutes: AnalyzerRules.protectedBlockMinutes), measure: .deepBlocks)
        case .tiredness:
            guard detail.sessions >= AnalyzerRules.sessionsForAFix else { return nil }
            let earlier = !context.morningPlanTaken && context.morningPlanHour > CoachPlanner.earliestMorningHour
            return AnalyzerFix(cause: cause, change: .hardestFirst(morningHour: earlier ? context.morningPlanHour - 1 : nil),
                               measure: .longestStretch)
        }
    }

    /// The coach's limit: 60% of the usual time, nothing under 15 minutes a day.
    static func limitMinutes(perDay: TimeInterval) -> Int? {
        guard perDay >= 15 * 60 else { return nil }
        return min(60, max(10, Int((perDay / 60 * 0.6 / 5).rounded()) * 5))
    }

    /// The first free slot that day between the block's hours, on a
    /// quarter-hour, after now. Nil when the calendar has no room.
    static func freeSlot(on day: Date, busy: [DateInterval], minutes: Int, now: Date, calendar: Calendar = .current) -> Date? {
        guard let from = calendar.date(bySettingHour: AnalyzerRules.protectedBlockFirstHour, minute: 0, second: 0, of: day),
              let to = calendar.date(bySettingHour: AnalyzerRules.protectedBlockLastHour, minute: 0, second: 0, of: day) else { return nil }
        let length = TimeInterval(minutes * 60)
        var slot = from
        while slot.addingTimeInterval(length) <= to {
            let span = DateInterval(start: slot, end: slot.addingTimeInterval(length))
            if slot > now, !busy.contains(where: { ($0.intersection(with: span)?.duration ?? 0) > 0 }) { return slot }
            slot = slot.addingTimeInterval(15 * 60)
        }
        return nil
    }
}

/// A stable random stream, so a stored seed always gives the same shuffle,
/// whatever the system's own shuffling does between versions.
struct AnalyzerRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func coin() -> Bool { next() & 1 == 1 }

    mutating func shuffled<T>(_ items: [T]) -> [T] {
        var items = items
        for index in items.indices.dropLast().reversed() {
            items.swapAt(index, index + Int(next() % UInt64(items.count - index)))
        }
        return items
    }
}

/// A test of one fix over working days: half On, half Off, shuffled once from
/// a stored seed. The app makes the change on On days and takes it back on Off
/// days. A day that can't count is made up later, in the same arm, on the same
/// weekday where it can be.
struct AnalyzerExperiment: Codable, Equatable, Sendable, Identifiable {
    enum Arm: String, Codable, Sendable {
        case on, off
    }

    enum SlotState: String, Codable, Sendable {
        case pending, counted, skipped
    }

    struct Slot: Codable, Equatable, Sendable, Identifiable {
        let day: Date
        let arm: Arm
        var state = SlotState.pending
        /// The day's measure, once counted.
        var value: Double?
        /// The change really was on, for an On day.
        var wasApplied = false

        var id: Date { day }
    }

    var id = UUID()
    let fix: AnalyzerFix
    var plan: String
    let seed: UInt64
    let startedAt: Date
    var slots: [Slot]
    /// The last day first planned; make-ups come after it.
    let lastPlanned: Date
    var makeUps = 0

    init(fix: AnalyzerFix, plan: String, seed: UInt64, startedAt: Date, slots: [Slot]) {
        self.fix = fix
        self.plan = plan
        self.seed = seed
        self.startedAt = startedAt
        self.slots = slots
        self.lastPlanned = slots.last?.day ?? startedAt
    }

    // MARK: Scheduling

    /// The next `count` working days after `now`.
    static func workingDays(after now: Date, count: Int, weekendsCount: Bool, calendar: Calendar = .current) -> [Date] {
        var out: [Date] = []
        var cursor = calendar.startOfDay(for: now)
        while out.count < count {
            cursor = calendar.startOfDay(1, from: cursor)
            if weekendsCount || !calendar.isDateInWeekend(cursor) { out.append(cursor) }
        }
        return out
    }

    static func schedule(after now: Date, seed: UInt64, weekendsCount: Bool, calendar: Calendar = .current) -> [Slot] {
        let days = workingDays(after: now, count: AnalyzerRules.experimentDays, weekendsCount: weekendsCount, calendar: calendar)
        return zip(days, arms(for: days, seed: seed, calendar: calendar)).map { Slot(day: $0, arm: $1) }
    }

    /// Half On and half Off. Each weekday's days split between the arms, so a
    /// slow Friday falls on both sides; what's left over splits evenly. Runs
    /// and lopsided weeks are drawn again, from the same stream.
    static func arms(for days: [Date], seed: UInt64, calendar: Calendar = .current) -> [Arm] {
        var random = AnalyzerRandom(seed: seed)
        for _ in 0..<256 {
            let arms = draw(days, &random, calendar: calendar)
            if isFair(arms) { return arms }
        }
        return days.indices.map { $0 % 2 == 0 ? .on : .off }
    }

    private static func draw(_ days: [Date], _ random: inout AnalyzerRandom, calendar: Calendar) -> [Arm] {
        var arms = [Arm](repeating: .off, count: days.count)
        let byWeekday = Dictionary(grouping: days.indices) { calendar.component(.weekday, from: days[$0]) }
        var spare: [Int] = []
        for weekday in byWeekday.keys.sorted() {
            let same = random.shuffled(byWeekday[weekday] ?? [])
            for pair in stride(from: 0, to: same.count - 1, by: 2) {
                let first = random.coin()
                arms[same[pair]] = first ? .on : .off
                arms[same[pair + 1]] = first ? .off : .on
            }
            if same.count % 2 == 1, let last = same.last { spare.append(last) }
        }
        let mixed = random.shuffled(spare)
        for (position, index) in mixed.enumerated() { arms[index] = position < mixed.count / 2 ? .on : .off }
        return arms
    }

    /// No long runs, and both arms in every week's worth of days.
    static func isFair(_ arms: [Arm]) -> Bool {
        var run = 0
        var previous: Arm?
        for arm in arms {
            run = arm == previous ? run + 1 : 1
            previous = arm
            if run > AnalyzerRules.longestRun { return false }
        }
        return stride(from: 0, to: arms.count, by: 5).allSatisfy { start in
            let week = arms[start..<min(start + 5, arms.count)]
            return week.count < 5 || (2...3).contains(week.filter { $0 == .on }.count)
        }
    }

    func slot(on day: Date) -> Slot? { slots.first { $0.day == day } }

    /// Settles a finished day. A day with no value, or an On day the change
    /// wasn't on, doesn't count, and is made up.
    mutating func resolve(day: Date, value: Double?, today: Date, calendar: Calendar = .current) {
        guard let index = slots.firstIndex(where: { $0.day == day && $0.state == .pending }) else { return }
        if let value, slots[index].arm == .off || slots[index].wasApplied {
            slots[index].state = .counted
            slots[index].value = value
        } else {
            slots[index].state = .skipped
            makeUp(slots[index], today: today, calendar: calendar)
        }
    }

    /// The first free same weekday after both the plan and today.
    private mutating func makeUp(_ slot: Slot, today: Date, calendar: Calendar) {
        guard makeUps < AnalyzerRules.maxMakeUps else { return }
        makeUps += 1
        let weekday = calendar.component(.weekday, from: slot.day)
        var cursor = max(lastPlanned, today)
        repeat {
            cursor = calendar.startOfDay(1, from: cursor)
        } while calendar.component(.weekday, from: cursor) != weekday || self.slot(on: cursor) != nil
        slots.append(Slot(day: cursor, arm: slot.arm))
        slots.sort { $0.day < $1.day }
    }

    // MARK: Where it stands

    var isFinished: Bool { !slots.contains { $0.state == .pending } }

    /// In order, skipped days left out.
    var visibleSlots: [Slot] { slots.filter { $0.state != .skipped } }

    var countedDays: Int { slots.filter { $0.state == .counted }.count }

    var outcome: AnalyzerOutcome {
        let counted = slots.filter { $0.state == .counted }
        return AnalyzerOutcome.judge(on: counted.filter { $0.arm == .on }.compactMap(\.value),
                                     off: counted.filter { $0.arm == .off }.compactMap(\.value),
                                     measure: fix.measure)
    }

    /// The day after the last planned one.
    func resultDay(calendar: Calendar = .current) -> Date {
        calendar.startOfDay(1, from: slots.last?.day ?? startedAt)
    }
}

/// What a test showed, by rule. Ten days is a small test, so "It worked" takes
/// a clear gap in the right direction and little overlap.
struct AnalyzerOutcome: Codable, Equatable, Sendable {
    enum Verdict: String, Codable, Sendable {
        case worked, noDifference, notEnoughDays
    }

    let verdict: Verdict
    let onMedian: Double?
    let offMedian: Double?
    let onDays: Int
    let offDays: Int
    /// How often an On day beats an Off day, ties counting half: 0...1.
    let winShare: Double

    static func judge(on: [Double], off: [Double], measure: AnalyzerMeasureKind) -> AnalyzerOutcome {
        let share = winShare(on: on, off: off)
        let onMedian = AnalyzerMath.median(on), offMedian = AnalyzerMath.median(off)
        var verdict = Verdict.notEnoughDays
        if on.count >= AnalyzerRules.verdictDays, off.count >= AnalyzerRules.verdictDays, let a = onMedian, let b = offMedian {
            let gap = max(measure.minimumGap, b * AnalyzerRules.verdictGapShare)
            verdict = share >= AnalyzerRules.verdictWinShare && a - b >= gap ? .worked : .noDifference
        }
        return AnalyzerOutcome(verdict: verdict, onMedian: onMedian, offMedian: offMedian, onDays: on.count, offDays: off.count,
                               winShare: share)
    }

    /// The Mann-Whitney U of the On days over every On and Off pair.
    static func winShare(on: [Double], off: [Double]) -> Double {
        guard !on.isEmpty, !off.isEmpty else { return 0 }
        var wins = 0.0
        for a in on {
            for b in off {
                if a > b { wins += 1 } else if a == b { wins += 0.5 }
            }
        }
        return wins / Double(on.count * off.count)
    }
}
