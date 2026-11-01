import Foundation

// MARK: - What an answer shows

/// The colour of an answer's chart: focus indigo or drift orange.
enum AskTone: Equatable, Sendable {
    case focus, drift
}

/// An upright bar, as a share of the tallest one possible.
struct AskBar: Equatable, Sendable {
    /// Shown under some bars only: "08", "10".
    let label: String?
    /// 0...1.
    let value: Double
    let highlighted: Bool
}

/// One horizontal bar: a name, the bar and its number.
struct AskRow: Equatable, Sendable {
    let name: String
    /// 0...1 of the bar's width.
    let value: Double
    /// "3h 40m", "88%".
    let text: String
}

/// The one small chart beside an answer, with what it shows in words for
/// VoiceOver.
enum AskVisual: Equatable, Sendable {
    /// Upright bars, such as focus rate by hour.
    case bars([AskBar], tone: AskTone, summary: String)
    /// Horizontal bars, such as drift by site.
    case rows([AskRow], tone: AskTone, summary: String)
}

/// A button under an answer. Only what the app already does elsewhere: a
/// daily limit on a site (as in Settings), or starting or planning a
/// session (as the menu and the morning plan do).
struct AskAction: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case limit(host: String, minutes: Int)
        case startSession(minutes: Int)
        /// A session at this time, offered by a notification when it
        /// comes, like the morning plan's "Plan them".
        case planSession(at: Date)
    }

    let kind: Kind
    /// "Limit x.com to 15 minutes a day".
    let title: String
    /// What it says once done: "x.com is limited to 15 minutes a day".
    let doneTitle: String
}

/// Everything an answer says, worked out by rules from the store. `lead`
/// and `detail` are the template words; the model may reword them, from
/// `facts` alone.
struct AskFacts: Equatable, Sendable {
    var lead: String
    var detail: String
    /// Plain statements the words may draw on, and nothing else. Empty when
    /// there was nothing to work from, and the model isn't asked then.
    var facts: [String] = []
    var visual: AskVisual?
    /// "From the last 4 weeks · 36 sessions".
    var basis: String
    var action: AskAction?
    /// A question to ask instead, when this one couldn't be answered.
    var suggestion: String?
}

/// What the rules need from settings, read on the main actor.
struct AskContext: Equatable, Sendable {
    /// Sites that already have a daily limit.
    var limitedSites: Set<String> = []
    /// A session or a break is on, so nothing offers to start one.
    var busy = false
    /// The length the menu would start with.
    var sessionMinutes = 50
}

/// A finished session: how long it ran and how it went.
struct AskSession: Equatable, Sendable {
    let start: Date
    /// Running minutes, pauses left out.
    let minutes: Int
    let focus: TimeInterval
    let drift: TimeInterval
}

/// The weekly coach's experiments, as Ask reads them.
struct AskCoachInput: Equatable, Sendable {
    /// The last one to end, with its result.
    var finished: CoachTrial?
    /// This week's.
    var running: CoachTrial?
}

// MARK: - The rules

/// Works out each kind of answer from day summaries and sessions, by rules.
/// Every number an answer shows comes from here; the model only rewords.
struct AskFactsBuilder {
    let now: Date
    var calendar: Calendar = .current
    var locale: Locale = .current
    var context = AskContext()

    /// Answers look back this many days.
    static let lookbackDays = 28
    static let period = "From the last 4 weeks"
    /// An hour counts toward "best hours" with this much focus and drift
    /// over the four weeks.
    static let activeHour: TimeInterval = 30 * 60
    /// A day counts as tracked with this much time on it.
    static let activeDay: TimeInterval = 10 * 60

    // MARK: Best hours

    func bestHours(_ days: [DaySummary], sessionCount: Int) -> AskFacts {
        let basis = basisLine(days, sessions: sessionCount)
        var focus = [TimeInterval](repeating: 0, count: 24), drift = focus
        for day in days {
            for hour in 0..<24 {
                focus[hour] += day.focusByHour[hour]
                drift[hour] += day.driftByHour[hour]
            }
        }
        let active = Set((0..<24).filter { focus[$0] + drift[$0] >= Self.activeHour })
        guard activeDays(days) >= 3, active.count >= 2, focus.reduce(0, +) > 0 else { return tooLittle(basis) }

        func sum(_ values: [TimeInterval], _ hours: Range<Int>) -> TimeInterval { hours.reduce(0) { $0 + values[$1] } }
        func rate(_ hours: Range<Int>) -> Double { FocusRate.of(focused: sum(focus, hours), drifted: sum(drift, hours)) }

        // The best run of up to three active hours, and the weakest of the same length.
        var windows: [Range<Int>] = []
        for length in stride(from: 3, through: 1, by: -1) {
            windows = (0...(24 - length)).map { $0..<($0 + length) }.filter { $0.allSatisfy(active.contains) }
            if !windows.isEmpty { break }
        }
        guard let best = windows.max(by: { (rate($0), sum(focus, $0)) < (rate($1), sum(focus, $1)) }) else {
            return tooLittle(basis)
        }
        let weakest = windows.filter { !$0.overlaps(best) }.min { rate($0) < rate($1) }
        let share = sum(focus, best) / max(1, focus.reduce(0, +))
        let overall = FocusRate.of(focused: focus.reduce(0, +), drifted: drift.reduce(0, +))

        var detail = "Your focus rate then is \(percent(rate(best)))"
        if let weakest, rate(weakest) < rate(best) {
            detail += ", against \(percent(rate(weakest))) from \(span(weakest))"
        }
        detail += ". Those hours hold \(percent(share)) of all the time you focused."

        var facts = [
            "Best hours: \(span(best)), with a focus rate of \(percent(rate(best))).",
            "Share of all focused time in those hours: \(percent(share)).",
            "Focus rate across all hours: \(percent(overall)).",
        ]
        if let weakest { facts.append("Weakest hours: \(span(weakest)), with a focus rate of \(percent(rate(weakest))).") }
        if let day = bestWeekday(days, overall: overall) {
            facts.append("Best day of the week: \(weekdayName(day.weekday)), with a focus rate of \(percent(day.rate)).")
        }
        facts.append(Self.rateMeaning)

        let shown = (active.min() ?? 0)...(active.max() ?? 23)
        let bars = shown.map { hour in
            AskBar(label: hour % 2 == 0 ? String(format: "%02d", hour) : nil,
                   value: focus[hour] + drift[hour] > 0 ? rate(hour..<(hour + 1)) : 0,
                   highlighted: best.contains(hour))
        }
        return AskFacts(
            lead: "\(partOfDay(best.lowerBound)): \(span(best)).",
            detail: detail,
            facts: facts + [basis],
            visual: .bars(bars, tone: .focus,
                          summary: "Focus rate by hour, \(clock(shown.lowerBound)) to \(clock(shown.upperBound + 1)): "
                              + "highest from \(span(best)), at \(percent(rate(best)))."),
            basis: basis,
            action: bestHoursAction(best)
        )
    }

    /// Start now inside the best hours; otherwise plan one for when they next come.
    private func bestHoursAction(_ best: Range<Int>) -> AskAction? {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(bySettingHour: best.lowerBound, minute: 0, second: 0, of: today),
              let end = calendar.date(byAdding: .hour, value: best.count, to: start) else { return nil }
        if start <= now, now.addingTimeInterval(20 * 60) <= end {
            return context.busy ? nil : startAction(context.sessionMinutes)
        }
        let tomorrow = start.addingTimeInterval(-HabitSchedule.slotLead) <= now
        guard let at = tomorrow ? calendar.date(byAdding: .day, value: 1, to: start) : start else { return nil }
        let title: String
        switch (tomorrow, best.lowerBound < 12) {
        case (true, true):  title = "Plan tomorrow's first session at \(clock(best.lowerBound))"
        case (true, false): title = "Plan a session at \(clock(best.lowerBound)) tomorrow"
        default:            title = "Plan a session at \(clock(best.lowerBound)) today"
        }
        return AskAction(kind: .planSession(at: at), title: title,
                         doneTitle: "Planned. A reminder comes at \(clock(best.lowerBound))")
    }

    private func bestWeekday(_ days: [DaySummary], overall: Double) -> (weekday: Int, rate: Double)? {
        var tallies: [Int: (focus: TimeInterval, drift: TimeInterval, days: Int)] = [:]
        for day in days where tracked(day) >= Self.activeDay {
            let weekday = calendar.component(.weekday, from: day.day)
            var tally = tallies[weekday] ?? (0, 0, 0)
            tally.focus += day.breakdown.focus
            tally.drift += day.breakdown.distraction
            tally.days += 1
            tallies[weekday] = tally
        }
        let rated = tallies.filter { $0.value.days >= 2 && $0.value.focus + $0.value.drift >= 3600 }
            .map { (weekday: $0.key, rate: FocusRate.of(focused: $0.value.focus, drifted: $0.value.drift)) }
        guard let best = rated.max(by: { $0.rate < $1.rate }), best.rate >= overall + 0.05 else { return nil }
        return best
    }

    // MARK: What pulls you away

    func pullsAway(_ days: [DaySummary], hours: AskHours?, sessionCount: Int) -> AskFacts {
        let basis = hours.map { "\(Self.period) · \(clock($0.from)) to \(clock($0.to))" }
            ?? basisLine(days, sessions: sessionCount)
        guard activeDays(days) >= 3 else { return tooLittle(basis) }

        var seconds: [String: TimeInterval] = [:]
        var daysWith: [String: Int] = [:]
        var groups: [String: ReportBuilder.DistractionGroup] = [:]
        var counted = 0
        for day in days {
            for (key, group) in day.distractions where groups[key] == nil { groups[key] = group }
            var onDay: [String: TimeInterval] = [:]
            if let hours {
                guard let active = day.hours, active.lowerBound < hours.to, active.upperBound >= hours.from else { continue }
                for hour in hours.from..<hours.to {
                    for (key, time) in day.distractionsByHour[hour] ?? [:] { onDay[key, default: 0] += time }
                }
            } else {
                guard tracked(day) >= Self.activeDay else { continue }
                for (key, group) in day.distractions { onDay[key, default: 0] += group.seconds }
            }
            counted += 1
            for (key, time) in onDay {
                seconds[key, default: 0] += time
                if time >= 60 { daysWith[key, default: 0] += 1 }
            }
        }

        let total = seconds.values.reduce(0, +)
        let when = hours.map { "between \(clock($0.from)) and \(clock($0.to))" } ?? "in the last 4 weeks"
        guard total >= 5 * 60 else {
            return AskFacts(lead: "Hardly anything.",
                            detail: "You drifted \(WindowFormat.hm(total)) \(when), on \(count(counted, "day")) tracked.",
                            facts: ["Drift \(when): \(WindowFormat.hm(total)).", basis], basis: basis)
        }

        let top = seconds.sorted { $0.value > $1.value }.prefix(3)
            .map { (key: $0.key, name: groups[$0.key]?.name ?? $0.key, seconds: $0.value) }
        guard let first = top.first else { return tooLittle(basis) }
        let firstDays = daysWith[first.key] ?? 0
        let lead: String
        switch firstDays {
        case 0:       lead = "\(first.name), most of all."
        case counted: lead = "\(first.name), on all \(count(counted, "day"))."
        default:      lead = "\(first.name), on \(firstDays) of the \(count(counted, "day"))."
        }
        let detail: String
        if top.count > 1 {
            detail = "It took \(WindowFormat.hm(first.seconds)) of the \(WindowFormat.hm(total)) you drifted \(when). "
                + "\(top[1].name) comes next, at \(WindowFormat.hm(top[1].seconds))."
        } else {
            detail = "It was all \(WindowFormat.hm(total)) of the drift \(when)."
        }

        var facts = ["Drift \(when): \(WindowFormat.hm(total)) in all, over \(count(counted, "day")) tracked."]
        for (index, item) in top.enumerated() {
            let rank = ["Biggest", "Second", "Third"][index]
            facts.append("\(rank) distraction \(when): \(item.name), \(WindowFormat.hm(item.seconds)), "
                         + "on \(daysWith[item.key] ?? 0) of those days.")
        }

        let widest = max(1, first.seconds)
        return AskFacts(
            lead: lead,
            detail: detail,
            facts: facts + [basis],
            visual: .rows(top.map { AskRow(name: $0.name, value: $0.seconds / widest, text: WindowFormat.hm($0.seconds)) },
                          tone: .drift,
                          summary: "Drift \(when): " + top.map { "\($0.name) \(WindowFormat.hm($0.seconds))" }.joined(separator: ", ")),
            basis: basis,
            action: limitAction(key: first.key, host: groups[first.key]?.host, days: days)
        )
    }

    // MARK: This week against last

    /// - Parameters:
    ///   - thisWeek: this week so far.
    ///   - sameDaysLast: last week, up to the same point.
    ///   - lastWeek: all of last week.
    func weekCompare(thisWeek: BreakdownSnapshot, sameDaysLast: BreakdownSnapshot, lastWeek: BreakdownSnapshot,
                     sessionsThisWeek: Int, sessionsLastWeek: Int) -> AskFacts {
        let basis = "From this week so far and last week · \(count(sessionsThisWeek + sessionsLastWeek, "session"))"
        let thisTracked = thisWeek.focus + thisWeek.neutral + thisWeek.distraction
        let lastTracked = lastWeek.focus + lastWeek.neutral + lastWeek.distraction
        guard thisTracked >= 60 || lastTracked >= 60 else { return tooLittle(basis) }
        guard lastTracked >= 60 else {
            return AskFacts(lead: "Nothing to compare with yet.",
                            detail: "Last week had nothing tracked. This week you've focused \(WindowFormat.hm(thisWeek.focus)) so far.",
                            facts: ["Focused this week so far: \(WindowFormat.hm(thisWeek.focus)).", "Last week: nothing tracked."],
                            basis: basis)
        }

        let change = thisWeek.focus - sameDaysLast.focus
        let threshold = max(10 * 60, sameDaysLast.focus * 0.05)
        let lead: String
        if abs(change) < threshold {
            lead = "About the same as last week."
        } else if change > 0 {
            lead = "Up \(WindowFormat.hm(change)) on the same days last week."
        } else {
            lead = "Down \(WindowFormat.hm(-change)) on the same days last week."
        }

        let rateNow = FocusRate.of(focused: thisWeek.focus, drifted: thisWeek.distraction)
        let rateThen = FocusRate.of(focused: sameDaysLast.focus, drifted: sameDaysLast.distraction)
        var detail = "You've focused \(WindowFormat.hm(thisWeek.focus)) so far, "
            + "against \(WindowFormat.hm(sameDaysLast.focus)) by this point last week."
        if thisWeek.focus + thisWeek.distraction >= 60, sameDaysLast.focus + sameDaysLast.distraction >= 60 {
            let points = Int((rateNow * 100).rounded()) - Int((rateThen * 100).rounded())
            let versus = points == 0 ? "the same as then" : "\(points > 0 ? "up" : "down") from \(percent(rateThen))"
            detail += " Your focus rate is \(percent(rateNow)), \(versus)."
        }

        let facts = [
            "Focused this week so far: \(WindowFormat.hm(thisWeek.focus)), focus rate \(percent(rateNow)), "
                + "\(count(sessionsThisWeek, "session")).",
            "Focused by this point last week: \(WindowFormat.hm(sameDaysLast.focus)), focus rate \(percent(rateThen)).",
            "Focused in all of last week: \(WindowFormat.hm(lastWeek.focus)), \(count(sessionsLastWeek, "session")).",
            "Drift this week so far: \(WindowFormat.hm(thisWeek.distraction)); "
                + "by this point last week: \(WindowFormat.hm(sameDaysLast.distraction)).",
            Self.rateMeaning,
        ]
        let rows = [("This week", thisWeek.focus), ("Last week, same days", sameDaysLast.focus), ("All of last week", lastWeek.focus)]
        let widest = max(1, rows.map(\.1).max() ?? 1)
        return AskFacts(
            lead: lead,
            detail: detail,
            facts: facts,
            visual: .rows(rows.map { AskRow(name: $0.0, value: $0.1 / widest, text: WindowFormat.hm($0.1)) }, tone: .focus,
                          summary: "Focused time: " + rows.map { "\($0.0) \(WindowFormat.hm($0.1))" }.joined(separator: ", ")),
            basis: basis,
            action: change <= -threshold && !context.busy ? startAction(context.sessionMinutes) : nil
        )
    }

    // MARK: The day that drifts most

    /// - Parameter days: finished days only, so today's part-day doesn't count.
    func driftDay(_ days: [DaySummary], sessionCount: Int) -> AskFacts {
        let basis = basisLine(days, sessions: sessionCount)
        var drift: [Int: TimeInterval] = [:], seen: [Int: Int] = [:]
        var byWeekday: [Int: [DaySummary]] = [:]
        for day in days where tracked(day) >= Self.activeDay {
            let weekday = calendar.component(.weekday, from: day.day)
            drift[weekday, default: 0] += day.breakdown.distraction
            seen[weekday, default: 0] += 1
            byWeekday[weekday, default: []].append(day)
        }
        guard seen.count >= 3, seen.values.reduce(0, +) >= 5 else { return tooLittle(basis) }

        let average = Dictionary(uniqueKeysWithValues: seen.map { ($0.key, (drift[$0.key] ?? 0) / Double($0.value)) })
        let candidates = average.filter { (seen[$0.key] ?? 0) >= 2 }
        guard let worst = (candidates.isEmpty ? average : candidates).max(by: { $0.value < $1.value }) else { return tooLittle(basis) }
        let otherDays = seen.values.reduce(0, +) - (seen[worst.key] ?? 0)
        let others = otherDays > 0 ? (drift.values.reduce(0, +) - (drift[worst.key] ?? 0)) / Double(otherDays) : 0
        let standsOut = worst.value >= others * 1.2 && worst.value - others >= 10 * 60

        // What took the time on that day.
        var groups: [String: ReportBuilder.DistractionGroup] = [:]
        for day in byWeekday[worst.key] ?? [] {
            for (key, group) in day.distractions {
                if groups[key] == nil { groups[key] = group } else { groups[key]?.seconds += group.seconds }
            }
        }
        let top = groups.max { $0.value.seconds < $1.value.seconds }
        let topPerDay = (top?.value.seconds ?? 0) / Double(max(1, seen[worst.key] ?? 1))
        let name = weekdayName(worst.key, plural: true)

        let lead: String
        var detail: String
        if standsOut {
            lead = "\(name), with \(WindowFormat.hm(worst.value)) of drift on an average one."
            detail = "That's against \(WindowFormat.hm(others)) on other days."
            if let top, topPerDay >= 60, top.value.seconds >= (drift[worst.key] ?? 0) * 0.25 {
                detail += " \(top.value.name) takes \(WindowFormat.hm(topPerDay)) of it."
            }
        } else {
            let all = drift.values.reduce(0, +) / Double(max(1, seen.values.reduce(0, +)))
            lead = "No day stands out."
            detail = "Drift runs about \(WindowFormat.hm(all)) a day, whatever the day. "
                + "\(name) are a little higher, at \(WindowFormat.hm(worst.value))."
        }

        var facts = [
            "Most drift: \(name), \(WindowFormat.hm(worst.value)) on an average one, over \(count(seen[worst.key] ?? 0, "day")).",
            "Other days average \(WindowFormat.hm(others)) of drift.",
        ]
        if let top, topPerDay >= 60 {
            facts.append("Biggest distraction on \(name): \(top.value.name), \(WindowFormat.hm(topPerDay)) on an average one.")
        }

        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        let tallest = max(1, average.values.max() ?? 1)
        let symbols = localizedCalendar.shortWeekdaySymbols
        let bars = order.map { weekday in
            AskBar(label: symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : nil,
                   value: (average[weekday] ?? 0) / tallest,
                   highlighted: standsOut && weekday == worst.key)
        }
        return AskFacts(
            lead: lead,
            detail: detail,
            facts: facts + [basis],
            visual: .bars(bars, tone: .drift,
                          summary: "Average drift by day of the week: most on \(name), \(WindowFormat.hm(worst.value))."),
            basis: basis,
            action: standsOut ? top.flatMap { limitAction(key: $0.key, host: $0.value.host, days: days) } : nil
        )
    }

    // MARK: Session length

    /// Lengths sessions are grouped by, in minutes.
    static let lengths: [(name: String, phrase: String, minutes: Range<Int>)] = [
        ("Under 25 min", "under 25 minutes", 5..<25),
        ("25 to 44 min", "of 25 to 44 minutes", 25..<45),
        ("45 to 74 min", "of 45 to 74 minutes", 45..<75),
        ("75 min or more", "of 75 minutes or more", 75..<Int.max),
    ]

    func sessionLength(_ sessions: [AskSession]) -> AskFacts {
        let counted = sessions.filter { $0.minutes >= 5 }
        let basis = "\(Self.period) · \(count(counted.count, "session"))"
        guard counted.count >= 3 else {
            return AskFacts(lead: "Too few sessions to tell yet.",
                            detail: "After a few more sessions, this compares how different lengths went.",
                            facts: [], basis: basis)
        }

        struct Group { let index: Int; let sessions: [AskSession]; let rate: Double; let counted: TimeInterval }
        let groups = Self.lengths.indices.compactMap { index -> Group? in
            let inside = counted.filter { Self.lengths[index].minutes.contains($0.minutes) }
            guard !inside.isEmpty else { return nil }
            let focus = inside.reduce(0) { $0 + $1.focus }, drift = inside.reduce(0) { $0 + $1.drift }
            return Group(index: index, sessions: inside, rate: FocusRate.of(focused: focus, drifted: drift), counted: focus + drift)
        }
        let rated = groups.filter { $0.sessions.count >= 2 && $0.counted >= 10 * 60 }
        guard let best = rated.max(by: { ($0.rate, $0.sessions.count) < ($1.rate, $1.sessions.count) }) else {
            return AskFacts(lead: "Too few sessions to tell yet.",
                            detail: "After a few more sessions, this compares how different lengths went.",
                            facts: [], basis: basis)
        }

        let bestPhrase = Self.lengths[best.index].phrase
        let lead: String, detail: String
        var facts = ["Sessions \(bestPhrase): focus rate \(percent(best.rate)), \(count(best.sessions.count, "session"))."]
        if rated.count == 1 {
            lead = "Only one length to go on so far."
            detail = "Your sessions \(bestPhrase) run at \(percent(best.rate)) focus rate across \(count(best.sessions.count, "session")). "
                + "Try a few shorter or longer ones to compare."
        } else {
            lead = "Sessions \(bestPhrase)."
            var text = "Your focus rate in those is \(percent(best.rate)) across \(count(best.sessions.count, "session"))"
            if let worst = rated.min(by: { $0.rate < $1.rate }), worst.index != best.index {
                text += ", against \(percent(worst.rate)) in sessions \(Self.lengths[worst.index].phrase)"
            }
            detail = text + "."
            for group in rated where group.index != best.index {
                facts.append("Sessions \(Self.lengths[group.index].phrase): focus rate \(percent(group.rate)), "
                             + "\(count(group.sessions.count, "session")).")
            }
        }
        facts.append(Self.rateMeaning)

        let minutes = best.sessions.map(\.minutes).sorted()
        let median = minutes[minutes.count / 2]
        let suggested = min(120, max(15, Int((Double(median) / 5).rounded()) * 5))
        return AskFacts(
            lead: lead,
            detail: detail,
            facts: facts + [basis],
            visual: .rows(groups.map { AskRow(name: Self.lengths[$0.index].name, value: $0.rate, text: percent($0.rate)) },
                          tone: .focus,
                          summary: "Focus rate by session length: "
                              + groups.map { "\(Self.lengths[$0.index].name) \(percent($0.rate))" }.joined(separator: ", ")),
            basis: basis,
            action: context.busy ? nil : startAction(suggested)
        )
    }

    // MARK: Time on an app or site

    /// - Parameter days: from three weeks before this one, today last.
    func appTime(_ days: [DaySummary], question: String, period: AskPeriod) -> AskFacts {
        let today = calendar.startOfDay(for: now)
        let monthStart = calendar.date(byAdding: .day, value: -(Self.lookbackDays - 1), to: today) ?? today
        let month = days.filter { $0.day >= monthStart }
        let basis = "\(Self.period) · \(count(activeDays(month), "day")) tracked"
        let seen = Self.targets(in: month)
        guard let target = Self.match(question, in: seen) else {
            let names = seen.sorted { $0.seconds > $1.seconds }.prefix(3).map(\.name)
            var detail = "FocusGuard sees which app or site you used, when, and for how long."
            if !names.isEmpty { detail += " Your most used lately are \(HabitFormat.list(names))." }
            return AskFacts(lead: "Nothing by that name was tracked.", detail: detail, basis: basis,
                            suggestion: names.first.map { "How much time on \($0) this week?" })
        }

        func usage(_ day: DaySummary) -> ClassificationTally {
            var tally = ClassificationTally()
            if target.isSite {
                for group in day.apps.values { if let time = group.hosts[target.key] { tally.add(time) } }
            } else if let group = day.apps[target.key] {
                tally.add(group.tally)
            }
            return tally
        }

        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        func week(_ back: Int) -> TimeInterval {
            guard let start = calendar.date(byAdding: .weekOfYear, value: -back, to: weekStart),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { return 0 }
            return days.filter { $0.day >= start && $0.day < end }.reduce(0) { $0 + usage($1).total }
        }
        var monthTally = ClassificationTally()
        var daysUsed = 0
        for day in month {
            let tally = usage(day)
            monthTally.add(tally)
            if tally.total >= 60 { daysUsed += 1 }
        }

        let asked: (seconds: TimeInterval, phrase: String)
        switch period {
        case .today:    asked = (month.filter { $0.day == today }.reduce(0) { $0 + usage($1).total }, "today")
        case .thisWeek: asked = (week(0), "this week")
        case .lastWeek: asked = (week(1), "last week")
        case .recent:   asked = (monthTally.total, "in the last 4 weeks")
        }
        let perDay = monthTally.total / Double(max(1, daysUsed))
        let kind: String
        switch monthTally.dominant {
        case .focus:       kind = "focus"
        case .distraction: kind = "drift"
        case .neutral:     kind = "neutral time"
        }

        let lead = asked.seconds >= 60 ? "\(target.name): \(WindowFormat.hm(asked.seconds)) \(asked.phrase)."
            : "\(target.name): none \(asked.phrase)."
        let detail = daysUsed > 0
            ? "About \(WindowFormat.hm(perDay)) a day on the \(count(daysUsed, "day")) you used it lately, mostly counted as \(kind)."
            : "You haven't used it in the last 4 weeks."
        let weeks = [("This week", week(0)), ("Last week", week(1)), ("2 weeks ago", week(2)), ("3 weeks ago", week(3))]
        let widest = max(1, weeks.map(\.1).max() ?? 1)
        let facts = [
            "Time on \(target.name) \(asked.phrase): \(WindowFormat.hm(asked.seconds)).",
            "Days used in the last 4 weeks: \(daysUsed), about \(WindowFormat.hm(perDay)) on each.",
            "Mostly counted as \(kind).",
        ] + weeks.map { "\($0.0): \(WindowFormat.hm($0.1))." }
        let action = target.isSite && monthTally.dominant == .distraction
            ? limitAction(dailySeconds: monthTally.total / Double(max(1, activeDays(month))), host: target.key) : nil
        return AskFacts(
            lead: lead,
            detail: detail,
            facts: facts + [basis],
            visual: .rows(weeks.map { AskRow(name: $0.0, value: $0.1 / widest, text: WindowFormat.hm($0.1)) },
                          tone: monthTally.dominant == .distraction ? .drift : .focus,
                          summary: "Time on \(target.name) by week: "
                              + weeks.map { "\($0.0) \(WindowFormat.hm($0.1))" }.joined(separator: ", ")),
            basis: basis,
            action: action
        )
    }

    /// An app or a site seen in the days, by what a question may call it.
    struct Target: Equatable {
        /// The bundle id, or the host.
        let key: String
        let name: String
        let isSite: Bool
        let seconds: TimeInterval
        /// Lower-cased: "youtube.com" and "youtube"; "slack".
        let names: [String]
    }

    static func targets(in days: [DaySummary]) -> [Target] {
        var apps: [String: (name: String, seconds: TimeInterval)] = [:]
        var sites: [String: TimeInterval] = [:]
        for day in days {
            for (bundleId, group) in day.apps {
                apps[bundleId, default: (group.name, 0)].seconds += group.seconds
                for (host, time) in group.hosts { sites[host, default: 0] += time.total }
            }
        }
        let appTargets = apps.map { key, value in
            Target(key: key, name: value.name, isSite: false, seconds: value.seconds,
                   names: [value.name.lowercased()].filter { $0.count >= 3 })
        }
        let siteTargets = sites.map { host, seconds -> Target in
            let label = host.split(separator: ".").first.map(String.init) ?? host
            return Target(key: host, name: host, isSite: true, seconds: seconds,
                          names: [host] + (label.count >= 4 && label != host ? [label] : []))
        }
        return appTargets + siteTargets
    }

    /// The target a question names: the longest name found as whole words,
    /// the most used on a tie. Sites win over the browser they were in.
    static func match(_ question: String, in targets: [Target]) -> Target? {
        let cleaned = AskText.normalized(question)
            .map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : " " }
        let text = " " + String(cleaned).split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-")) }
            .joined(separator: " ") + " "
        let found = targets.compactMap { target -> (Target, Int)? in
            let longest = target.names.filter { text.contains(" \($0) ") }.map(\.count).max()
            return longest.map { (target, $0) }
        }
        return found.max { ($0.1, $0.0.isSite ? 1 : 0, $0.0.seconds) < ($1.1, $1.0.isSite ? 1 : 0, $1.0.seconds) }?.0
    }

    // MARK: The coach's experiment

    func coach(_ input: AskCoachInput, shipped: Bool) -> AskFacts {
        guard shipped else { return cantAnswer(suggestion: AskSuggestions.all[0]) }
        guard let trial = input.finished else {
            if let running = input.running {
                return AskFacts(lead: "It's still running.",
                                detail: "This week's experiment is \(running.experiment.shortName(locale: locale, calendar: calendar)). "
                                    + "Ask again next week to see how it went.",
                                basis: "From the weekly coach")
            }
            return AskFacts(lead: "No experiment ran last week.",
                            detail: "Try one from the weekly coach in Reports, then ask here the week after.",
                            basis: "From the weekly coach", suggestion: "How did this week compare with last?")
        }

        let name = trial.experiment.shortName(locale: locale, calendar: calendar)
        let basis = "From the week of \(trial.week.start.formatted(dayMonth))"
        guard let before = trial.before, let after = trial.after, let change = trial.change else {
            return AskFacts(lead: "Too little to tell.",
                            detail: "There wasn't enough tracked that week to measure \(name).", basis: basis)
        }
        let lead: String
        if trial.improved {
            lead = "Yes: \(change)."
        } else if change == "no change" || change.hasPrefix("about the same") {
            lead = "It made no difference."
        } else {
            lead = "Not this time: \(change)."
        }
        let detail = "The experiment was \(name). "
            + (trial.kept ? "You kept it on." : "It ended with the week, so it's off now.")

        let metric = trial.experiment.metric
        var facts = ["The experiment: \(name), in the week of \(trial.week.start.formatted(dayMonth)).",
                     "Before: \(metricText(metric, before)). During it: \(metricText(metric, after)).",
                     "Change: \(change).",
                     trial.kept ? "It was kept on." : "It ended with its week."]
        if let running = input.running {
            facts.append("This week's experiment: \(running.experiment.shortName(locale: locale, calendar: calendar)).")
        }

        var visual: AskVisual?
        switch metric {
        case .sessionRate:
            visual = .rows([AskRow(name: "Before", value: before, text: metricText(metric, before)),
                            AskRow(name: "During it", value: after, text: metricText(metric, after))],
                           tone: .focus, summary: "Focus rate before \(percent(before)), during it \(percent(after)).")
        case .siteMinutes:
            let widest = max(1, before, after)
            visual = .rows([AskRow(name: "Before", value: before / widest, text: metricText(metric, before)),
                            AskRow(name: "During it", value: after / widest, text: metricText(metric, after))],
                           tone: .drift, summary: "Minutes a day before \(Int(before.rounded())), during it \(Int(after.rounded())).")
        case .firstSession:
            visual = nil
        case .callDayFocus, .weekdayFocus:
            let widest = max(1, before, after)
            visual = .rows([AskRow(name: "Before", value: before / widest, text: metricText(metric, before)),
                            AskRow(name: "During it", value: after / widest, text: metricText(metric, after))],
                           tone: .focus, summary: "Focused \(WindowFormat.hm(before)) a day before, \(WindowFormat.hm(after)) during it.")
        }
        return AskFacts(lead: lead, detail: detail, facts: facts + [basis], visual: visual, basis: basis)
    }

    private func metricText(_ metric: CoachMetric, _ value: Double) -> String {
        switch metric {
        case .sessionRate:  return percent(value)
        case .siteMinutes:  return "\(Int(value.rounded())) min a day"
        case .firstSession: return clock(minutes: Int(value.rounded()))
        case .callDayFocus, .weekdayFocus: return "\(WindowFormat.hm(value)) focused a day"
        }
    }

    // MARK: Questions it can't answer

    func cantAnswer(suggestion: String?) -> AskFacts {
        AskFacts(lead: "That's not something FocusGuard can see.",
                 detail: "It sees which app or site you used, when, and for how long. It can't see what you did inside them.",
                 basis: "Worked out on this Mac",
                 suggestion: suggestion)
    }

    // MARK: - Pieces

    static let rateMeaning = "Focus rate is focused time against focused plus drifted time."

    private func tooLittle(_ basis: String) -> AskFacts {
        AskFacts(lead: "Too little tracked to tell yet.",
                 detail: "Ask again after a few more days of work with FocusGuard running.",
                 basis: basis)
    }

    private func basisLine(_ days: [DaySummary], sessions: Int) -> String {
        sessions > 0 ? "\(Self.period) · \(count(sessions, "session"))" : "\(Self.period) · \(count(activeDays(days), "day")) tracked"
    }

    private func tracked(_ day: DaySummary) -> TimeInterval {
        day.breakdown.focus + day.breakdown.neutral + day.breakdown.distraction
    }

    func activeDays(_ days: [DaySummary]) -> Int {
        days.filter { tracked($0) >= Self.activeDay }.count
    }

    private func startAction(_ minutes: Int) -> AskAction {
        AskAction(kind: .startSession(minutes: minutes), title: "Start a \(minutes)-minute session",
                  doneTitle: "Session started")
    }

    /// A daily limit on a distracting site, sized from its usual day.
    private func limitAction(key: String, host: String?, days: [DaySummary]) -> AskAction? {
        guard let host else { return nil }
        let total = days.reduce(0) { $0 + ($1.distractions[key]?.seconds ?? 0) }
        return limitAction(dailySeconds: total / Double(max(1, activeDays(days))), host: host)
    }

    /// About 60% of the site's usual day, in 5-minute steps from 10 to 60
    /// minutes, as the weekly coach sizes one. None for a site that already
    /// has a limit or takes under 15 minutes a day.
    func limitAction(dailySeconds: TimeInterval, host: String) -> AskAction? {
        guard dailySeconds >= 15 * 60,
              !context.limitedSites.contains(where: { Classifier.host(host, matches: $0) }) else { return nil }
        let minutes = min(60, max(10, Int((dailySeconds / 60 * 0.6 / 5).rounded()) * 5))
        return AskAction(kind: .limit(host: host, minutes: minutes),
                         title: "Limit \(host) to \(minutes) minutes a day",
                         doneTitle: "\(host) is limited to \(minutes) minutes a day")
    }

    private func percent(_ rate: Double) -> String {
        "\(Int((rate * 100).rounded()))%"
    }

    private func count(_ n: Int, _ noun: String) -> String {
        WindowFormat.count(n, noun)
    }

    /// "09:00", in the user's clock style.
    func clock(_ hour: Int) -> String {
        clock(minutes: hour * 60)
    }

    private func clock(minutes: Int) -> String {
        let base = calendar.startOfDay(for: now)
        let date = calendar.date(byAdding: .minute, value: minutes, to: base) ?? base
        return HabitFormat.time(date, locale: locale, calendar: calendar)
    }

    /// "09:00 to 12:00".
    private func span(_ hours: Range<Int>) -> String {
        "\(clock(hours.lowerBound)) to \(clock(hours.upperBound))"
    }

    private func partOfDay(_ hour: Int) -> String {
        hour < 12 ? "Mornings" : hour < 17 ? "Afternoons" : "Evenings"
    }

    private var localizedCalendar: Calendar {
        var calendar = calendar
        calendar.locale = locale
        return calendar
    }

    /// "Friday", or "Fridays".
    private func weekdayName(_ weekday: Int, plural: Bool = false) -> String {
        let symbols = localizedCalendar.weekdaySymbols
        let name = symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : "That day"
        return plural ? name + "s" : name
    }

    private var dayMonth: Date.FormatStyle {
        var style = Date.FormatStyle().day().month(.wide)
        style.locale = locale
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return style
    }
}

/// The questions the page offers.
enum AskSuggestions {
    static let all = [
        "When do I focus best?",
        "What pulls me away most?",
        "How did this week compare with last?",
        "Which day drifts most, and why?",
        "How long should my sessions be?",
        "Did last week's experiment work?",
    ]

    /// Up to `limit` suggestions not asked yet, in order; once all have
    /// been asked, all again.
    static func next(after asked: [String], limit: Int = 3) -> [String] {
        let seen = Set(asked.map { AskText.normalized($0).trimmingCharacters(in: .whitespacesAndNewlines) })
        let fresh = all.filter { !seen.contains(AskText.normalized($0)) }
        return Array((fresh.isEmpty ? all : fresh).prefix(limit))
    }
}
