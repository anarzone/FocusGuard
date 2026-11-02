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
    static let period = String(localized: "From the last 4 weeks")
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

        let bestRate = percent(rate(best)), bestSpan = span(best), held = percent(share)
        let detail: String
        if let weakest, rate(weakest) < rate(best) {
            let weakRate = percent(rate(weakest)), weakSpan = span(weakest)
            detail = String(localized: "Your focus rate then is \(bestRate), against \(weakRate) from \(weakSpan). Those hours hold \(held) of all the time you focused.",
                            comment: "From 09:00 to 12:00")
        } else {
            detail = String(localized: "Your focus rate then is \(bestRate). Those hours hold \(held) of all the time you focused.")
        }

        let overallRate = percent(overall)
        var facts = [
            String(localized: "Best hours: \(bestSpan), with a focus rate of \(bestRate)."),
            String(localized: "Share of all focused time in those hours: \(held)."),
            String(localized: "Focus rate across all hours: \(overallRate)."),
        ]
        if let weakest {
            let weakRate = percent(rate(weakest)), weakSpan = span(weakest)
            facts.append(String(localized: "Weakest hours: \(weakSpan), with a focus rate of \(weakRate)."))
        }
        if let day = bestWeekday(days, overall: overall) {
            let name = weekdayName(day.weekday), dayRate = percent(day.rate)
            facts.append(String(localized: "Best day of the week: \(name), with a focus rate of \(dayRate)."))
        }
        facts.append(Self.rateMeaning)

        let shown = (active.min() ?? 0)...(active.max() ?? 23)
        let shownFrom = clock(shown.lowerBound), shownTo = clock(shown.upperBound + 1), part = partOfDay(best.lowerBound)
        let bars = shown.map { hour in
            AskBar(label: hour % 2 == 0 ? String(format: "%02d", hour) : nil,
                   value: focus[hour] + drift[hour] > 0 ? rate(hour..<(hour + 1)) : 0,
                   highlighted: best.contains(hour))
        }
        return AskFacts(
            lead: String(localized: "\(part): \(bestSpan).", comment: "Mornings: 09:00 to 12:00."),
            detail: detail,
            facts: facts + [basis],
            visual: .bars(bars, tone: .focus,
                          summary: String(localized: "Focus rate by hour, \(shownFrom) to \(shownTo): highest from \(bestSpan), at \(bestRate).")),
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
        let time = clock(best.lowerBound)
        let title: String
        switch (tomorrow, best.lowerBound < 12) {
        case (true, true):  title = String(localized: "Plan tomorrow's first session at \(time)")
        case (true, false): title = String(localized: "Plan a session at \(time) tomorrow")
        default:            title = String(localized: "Plan a session at \(time) today")
        }
        return AskAction(kind: .planSession(at: at), title: title,
                         doneTitle: String(localized: "Planned. A reminder comes at \(time)"))
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
        let basis = hours.map { hours -> String in
            let period = Self.period, from = clock(hours.from), to = clock(hours.to)
            return String(localized: "\(period) · \(from) to \(to)", comment: "From the last 4 weeks · 09:00 to 12:00")
        } ?? basisLine(days, sessions: sessionCount)
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
        let when = hours.map { hours -> String in
            let from = clock(hours.from), to = clock(hours.to)
            return String(localized: "between \(from) and \(to)", comment: "Times in a sentence: Your sessions between 12:00 and 17:00 ...")
        } ?? String(localized: "in the last 4 weeks", comment: "Goes inside a sentence: You drifted 3h ...")
        let totalText = WindowFormat.hm(total)
        guard total >= 5 * 60 else {
            return AskFacts(lead: String(localized: "Hardly anything."),
                            detail: String(localized: "You drifted \(totalText) \(when), on \(counted) days tracked.",
                                           comment: "Plural on the number of days: 1 day / 2 days. When: between 12:00 and 17:00, or in the last 4 weeks"),
                            facts: [String(localized: "Drift \(when): \(totalText)."), basis], basis: basis)
        }

        let top = seconds.sorted { $0.value > $1.value }.prefix(3)
            .map { (key: $0.key, name: groups[$0.key]?.name ?? $0.key, seconds: $0.value) }
        guard let first = top.first else { return tooLittle(basis) }
        let firstDays = daysWith[first.key] ?? 0
        let lead: String
        switch firstDays {
        case 0:       lead = String(localized: "\(first.name), most of all.")
        case counted: lead = String(localized: "\(first.name), on all \(counted) days.", comment: "Plural on days: 1 day / 2 days")
        default:      lead = String(localized: "\(first.name), on \(firstDays) of the \(counted) days.", comment: "Plural on the last number: 1 day / 2 days")
        }
        let firstText = WindowFormat.hm(first.seconds)
        let detail: String
        if top.count > 1 {
            let nextName = top[1].name, nextText = WindowFormat.hm(top[1].seconds)
            detail = String(localized: "It took \(firstText) of the \(totalText) you drifted \(when). \(nextName) comes next, at \(nextText).",
                            comment: "When: between 12:00 and 17:00, or in the last 4 weeks")
        } else {
            detail = String(localized: "It was all \(totalText) of the drift \(when).", comment: "When: between 12:00 and 17:00, or in the last 4 weeks")
        }

        var facts = [String(localized: "Drift \(when): \(totalText) in all, over \(counted) days tracked.", comment: "Plural on the number of days: 1 day / 2 days")]
        for (index, item) in top.enumerated() {
            let time = WindowFormat.hm(item.seconds), onDays = daysWith[item.key] ?? 0
            switch index {
            case 0:  facts.append(String(localized: "Biggest distraction \(when): \(item.name), \(time), on \(onDays) of those days."))
            case 1:  facts.append(String(localized: "Second distraction \(when): \(item.name), \(time), on \(onDays) of those days."))
            default: facts.append(String(localized: "Third distraction \(when): \(item.name), \(time), on \(onDays) of those days."))
            }
        }

        let widest = max(1, first.seconds)
        return AskFacts(
            lead: lead,
            detail: detail,
            facts: facts + [basis],
            visual: .rows(top.map { AskRow(name: $0.name, value: $0.seconds / widest, text: WindowFormat.hm($0.seconds)) },
                          tone: .drift,
                          summary: String(localized: "Drift \(when): \(Self.nameList(top.map { ($0.name, WindowFormat.hm($0.seconds)) }))")),
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
        let allSessions = sessionsThisWeek + sessionsLastWeek
        let basis = String(localized: "From this week so far and last week · \(allSessions) sessions", comment: "Plural on sessions: 1 session / 2 sessions")
        let thisTracked = thisWeek.focus + thisWeek.neutral + thisWeek.distraction
        let lastTracked = lastWeek.focus + lastWeek.neutral + lastWeek.distraction
        guard thisTracked >= 60 || lastTracked >= 60 else { return tooLittle(basis) }
        let thisFocus = WindowFormat.hm(thisWeek.focus), thenFocus = WindowFormat.hm(sameDaysLast.focus)
        guard lastTracked >= 60 else {
            return AskFacts(lead: String(localized: "Nothing to compare with yet."),
                            detail: String(localized: "Last week had nothing tracked. This week you've focused \(thisFocus) so far."),
                            facts: [String(localized: "Focused this week so far: \(thisFocus)."), String(localized: "Last week: nothing tracked.")],
                            basis: basis)
        }

        let change = thisWeek.focus - sameDaysLast.focus
        let threshold = max(10 * 60, sameDaysLast.focus * 0.05)
        let lead: String
        let changeText = WindowFormat.hm(abs(change))
        if abs(change) < threshold {
            lead = String(localized: "About the same as last week.")
        } else if change > 0 {
            lead = String(localized: "Up \(changeText) on the same days last week.")
        } else {
            lead = String(localized: "Down \(changeText) on the same days last week.")
        }

        let rateNow = FocusRate.of(focused: thisWeek.focus, drifted: thisWeek.distraction)
        let rateThen = FocusRate.of(focused: sameDaysLast.focus, drifted: sameDaysLast.distraction)
        let nowRate = percent(rateNow), thenRate = percent(rateThen)
        let detail: String
        if thisWeek.focus + thisWeek.distraction >= 60, sameDaysLast.focus + sameDaysLast.distraction >= 60 {
            let points = Int((rateNow * 100).rounded()) - Int((rateThen * 100).rounded())
            if points == 0 {
                detail = String(localized: "You've focused \(thisFocus) so far, against \(thenFocus) by this point last week. Your focus rate is \(nowRate), the same as then.")
            } else if points > 0 {
                detail = String(localized: "You've focused \(thisFocus) so far, against \(thenFocus) by this point last week. Your focus rate is \(nowRate), up from \(thenRate).")
            } else {
                detail = String(localized: "You've focused \(thisFocus) so far, against \(thenFocus) by this point last week. Your focus rate is \(nowRate), down from \(thenRate).")
            }
        } else {
            detail = String(localized: "You've focused \(thisFocus) so far, against \(thenFocus) by this point last week.")
        }

        let lastFocus = WindowFormat.hm(lastWeek.focus)
        let driftNow = WindowFormat.hm(thisWeek.distraction), driftThen = WindowFormat.hm(sameDaysLast.distraction)
        let facts = [
            String(localized: "Focused this week so far: \(thisFocus), focus rate \(nowRate), \(sessionsThisWeek) sessions.",
                   comment: "Plural on sessions: 1 session / 2 sessions"),
            String(localized: "Focused by this point last week: \(thenFocus), focus rate \(thenRate)."),
            String(localized: "Focused in all of last week: \(lastFocus), \(sessionsLastWeek) sessions.",
                   comment: "Plural on sessions: 1 session / 2 sessions"),
            String(localized: "Drift this week so far: \(driftNow); by this point last week: \(driftThen)."),
            Self.rateMeaning,
        ]
        let rows = [(String(localized: "This week"), thisWeek.focus), (String(localized: "Last week, same days"), sameDaysLast.focus),
                    (String(localized: "All of last week"), lastWeek.focus)]
        let widest = max(1, rows.map(\.1).max() ?? 1)
        return AskFacts(
            lead: lead,
            detail: detail,
            facts: facts,
            visual: .rows(rows.map { AskRow(name: $0.0, value: $0.1 / widest, text: WindowFormat.hm($0.1)) }, tone: .focus,
                          summary: String(localized: "Focused time: \(Self.nameList(rows.map { ($0.0, WindowFormat.hm($0.1)) }))")),
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
        let name = weekdayName(worst.key, plural: true), capitalName = CoachDraft.capitalized(name)
        let worstText = WindowFormat.hm(worst.value), othersText = WindowFormat.hm(others), topText = WindowFormat.hm(topPerDay)

        let lead: String
        let detail: String
        if standsOut {
            lead = String(localized: "\(capitalName), with \(worstText) of drift on an average one.", comment: "Mondays")
            if let top, topPerDay >= 60, top.value.seconds >= (drift[worst.key] ?? 0) * 0.25 {
                detail = String(localized: "That's against \(othersText) on other days. \(top.value.name) takes \(topText) of it.")
            } else {
                detail = String(localized: "That's against \(othersText) on other days.")
            }
        } else {
            let all = WindowFormat.hm(drift.values.reduce(0, +) / Double(max(1, seen.values.reduce(0, +))))
            lead = String(localized: "No day stands out.")
            detail = String(localized: "Drift runs about \(all) a day, whatever the day. \(capitalName) are a little higher, at \(worstText).", comment: "Mondays")
        }

        let worstDays = seen[worst.key] ?? 0
        var facts = [
            String(localized: "Most drift: \(name), \(worstText) on an average one, over \(worstDays) days.", comment: "Mondays. Plural on days: 1 day / 2 days"),
            String(localized: "Other days average \(othersText) of drift."),
        ]
        if let top, topPerDay >= 60 {
            facts.append(String(localized: "Biggest distraction on \(name): \(top.value.name), \(topText) on an average one.", comment: "Mondays"))
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
                          summary: String(localized: "Average drift by day of the week: most on \(name), \(worstText).", comment: "Mondays")),
            basis: basis,
            action: standsOut ? top.flatMap { limitAction(key: $0.key, host: $0.value.host, days: days) } : nil
        )
    }

    // MARK: Session length

    /// Lengths sessions are grouped by, in minutes.
    static let lengths: [(name: String, phrase: String, minutes: Range<Int>)] = [
        (String(localized: "Under 25 min"), String(localized: "under 25 minutes", comment: "Goes inside a sentence: Sessions under 25 minutes"), 5..<25),
        (String(localized: "25 to 44 min"), String(localized: "of 25 to 44 minutes", comment: "Goes inside a sentence: Sessions of 25 to 44 minutes"), 25..<45),
        (String(localized: "45 to 74 min"), String(localized: "of 45 to 74 minutes", comment: "Goes inside a sentence: Sessions of 45 to 74 minutes"), 45..<75),
        (String(localized: "75 min or more"), String(localized: "of 75 minutes or more", comment: "Goes inside a sentence: Sessions of 75 minutes or more"), 75..<Int.max),
    ]

    func sessionLength(_ sessions: [AskSession]) -> AskFacts {
        let counted = sessions.filter { $0.minutes >= 5 }
        let basis = basisLine(sessions: counted.count)
        guard counted.count >= 3 else {
            return AskFacts(lead: String(localized: "Too few sessions to tell yet."),
                            detail: String(localized: "After a few more sessions, this compares how different lengths went."),
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
            return AskFacts(lead: String(localized: "Too few sessions to tell yet."),
                            detail: String(localized: "After a few more sessions, this compares how different lengths went."),
                            facts: [], basis: basis)
        }

        let bestPhrase = Self.lengths[best.index].phrase, bestRate = percent(best.rate), bestCount = best.sessions.count
        func fact(_ phrase: String, _ rate: String, _ sessions: Int) -> String {
            String(localized: "Sessions \(phrase): focus rate \(rate), \(sessions) sessions.", comment: "Plural on the last number: 1 session / 2 sessions. The phrase: of 25 to 44 minutes")
        }
        let lead: String, detail: String
        var facts = [fact(bestPhrase, bestRate, bestCount)]
        if rated.count == 1 {
            lead = String(localized: "Only one length to go on so far.")
            detail = String(localized: "Your sessions \(bestPhrase) run at \(bestRate) focus rate across \(bestCount) sessions. Try a few shorter or longer ones to compare.",
                            comment: "Plural on the last number: 1 session / 2 sessions. The phrase: of 25 to 44 minutes")
        } else {
            lead = String(localized: "Sessions \(bestPhrase).", comment: "The phrase: of 25 to 44 minutes")
            if let worst = rated.min(by: { $0.rate < $1.rate }), worst.index != best.index {
                let worstRate = percent(worst.rate), worstPhrase = Self.lengths[worst.index].phrase
                detail = String(localized: "Your focus rate in those is \(bestRate) across \(bestCount) sessions, against \(worstRate) in sessions \(worstPhrase).",
                                comment: "Plural on the first number: 1 session / 2 sessions. The phrase: of 25 to 44 minutes")
            } else {
                detail = String(localized: "Your focus rate in those is \(bestRate) across \(bestCount) sessions.",
                                comment: "Plural on sessions: 1 session / 2 sessions")
            }
            for group in rated where group.index != best.index {
                facts.append(fact(Self.lengths[group.index].phrase, percent(group.rate), group.sessions.count))
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
                          summary: String(localized: "Focus rate by session length: \(Self.nameList(groups.map { (Self.lengths[$0.index].name, percent($0.rate)) }))")),
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
        let basis = basisLine(daysTracked: activeDays(month))
        let seen = Self.targets(in: month)
        guard let target = Self.match(question, in: seen) else {
            let names = seen.sorted { $0.seconds > $1.seconds }.prefix(3).map(\.name)
            let list = HabitFormat.list(names)
            let detail = names.isEmpty ? String(localized: "FocusGuard sees which app or site you used, when, and for how long.")
                : String(localized: "FocusGuard sees which app or site you used, when, and for how long. Your most used lately are \(list).")
            return AskFacts(lead: String(localized: "Nothing by that name was tracked."), detail: detail, basis: basis,
                            suggestion: names.first.map { AskSuggestions.timeOn($0) })
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
        case .today:    asked = (month.filter { $0.day == today }.reduce(0) { $0 + usage($1).total }, String(localized: "today", comment: "Goes inside a sentence: Slack: 2h today."))
        case .thisWeek: asked = (week(0), String(localized: "this week", comment: "Goes inside a sentence: Slack: 2h this week."))
        case .lastWeek: asked = (week(1), String(localized: "last week", comment: "Goes inside a sentence: Slack: 2h last week."))
        case .recent:   asked = (monthTally.total, String(localized: "in the last 4 weeks", comment: "Goes inside a sentence: You drifted 3h ..."))
        }
        let perDay = monthTally.total / Double(max(1, daysUsed))
        let kind: String
        switch monthTally.dominant {
        case .focus:       kind = String(localized: "focus", comment: "Goes inside a sentence: mostly counted as focus")
        case .distraction: kind = String(localized: "drift", comment: "Goes inside a sentence: mostly counted as drift")
        case .neutral:     kind = String(localized: "neutral time", comment: "Goes inside a sentence: mostly counted as neutral time")
        }

        let askedText = WindowFormat.hm(asked.seconds), perDayText = WindowFormat.hm(perDay), askedPhrase = asked.phrase
        let lead = asked.seconds >= 60 ? String(localized: "\(target.name): \(askedText) \(askedPhrase).", comment: "An app or site, a compact duration, then when: today")
            : String(localized: "\(target.name): none \(askedPhrase).", comment: "An app or site, then when: today")
        let detail = daysUsed > 0
            ? String(localized: "About \(perDayText) a day on the \(daysUsed) days you used it lately, mostly counted as \(kind).",
                     comment: "Plural on days: 1 day / 2 days. The last part is focus, drift or neutral time")
            : String(localized: "You haven't used it in the last 4 weeks.")
        let weeks = [(String(localized: "This week"), week(0)), (String(localized: "Last week"), week(1)),
                     (String(localized: "2 weeks ago"), week(2)), (String(localized: "3 weeks ago"), week(3))]
        let widest = max(1, weeks.map(\.1).max() ?? 1)
        let facts = [
            String(localized: "Time on \(target.name) \(askedPhrase): \(askedText).", comment: "An app or site, when (today), a compact duration"),
            String(localized: "Days used in the last 4 weeks: \(daysUsed), about \(perDayText) on each."),
            String(localized: "Mostly counted as \(kind).", comment: "Focus, drift or neutral time"),
        ] + weeks.map { week -> String in
            let time = WindowFormat.hm(week.1)
            return String(localized: "\(week.0): \(time).", comment: "A fact: This week: 2h.")
        }
        let action = target.isSite && monthTally.dominant == .distraction
            ? limitAction(dailySeconds: monthTally.total / Double(max(1, activeDays(month))), host: target.key) : nil
        return AskFacts(
            lead: lead,
            detail: detail,
            facts: facts + [basis],
            visual: .rows(weeks.map { AskRow(name: $0.0, value: $0.1 / widest, text: WindowFormat.hm($0.1)) },
                          tone: monthTally.dominant == .distraction ? .drift : .focus,
                          summary: String(localized: "Time on \(target.name) by week: \(Self.nameList(weeks.map { ($0.0, WindowFormat.hm($0.1)) }))")),
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
            // A trailing hyphen is for suffixes: Azerbaijani writes "YouTube-da".
            let longest = target.names.filter { text.contains(" \($0) ") || text.contains(" \($0)-") }.map(\.count).max()
            return longest.map { (target, $0) }
        }
        return found.max { ($0.1, $0.0.isSite ? 1 : 0, $0.0.seconds) < ($1.1, $1.0.isSite ? 1 : 0, $1.0.seconds) }?.0
    }

    // MARK: The coach's experiment

    func coach(_ input: AskCoachInput, shipped: Bool) -> AskFacts {
        guard shipped else { return cantAnswer(suggestion: AskSuggestions.all[0]) }
        guard let trial = input.finished else {
            if let running = input.running {
                let name = running.experiment.shortName(locale: locale, calendar: calendar)
                return AskFacts(lead: String(localized: "It's still running."),
                                detail: String(localized: "This week's experiment is \(name). Ask again next week to see how it went."),
                                basis: String(localized: "From the weekly coach"))
            }
            return AskFacts(lead: String(localized: "No experiment ran last week."),
                            detail: String(localized: "Try one from the weekly coach in Reports, then ask here the week after."),
                            basis: String(localized: "From the weekly coach"), suggestion: AskSuggestions.all[2])
        }

        let name = trial.experiment.shortName(locale: locale, calendar: calendar)
        let weekOf = trial.week.start.formatted(dayMonth)
        let basis = String(localized: "From the week of \(weekOf)", comment: "A date: 3 November")
        guard let before = trial.before, let after = trial.after, let change = trial.change else {
            return AskFacts(lead: String(localized: "Too little to tell."),
                            detail: String(localized: "There wasn't enough tracked that week to measure \(name)."), basis: basis)
        }
        let lead: String
        if trial.improved {
            lead = String(localized: "Yes: \(change).", comment: "A change: +9 pts")
        } else if trial.madeNoDifference {
            lead = String(localized: "It made no difference.")
        } else {
            lead = String(localized: "Not this time: \(change).", comment: "A change: -3 pts")
        }
        let detail = trial.kept ? String(localized: "The experiment was \(name). You kept it on.")
            : String(localized: "The experiment was \(name). It ended with the week, so it's off now.")

        let metric = trial.experiment.metric
        let beforeText = metricText(metric, before), afterText = metricText(metric, after)
        var facts = [String(localized: "The experiment: \(name), in the week of \(weekOf)."),
                     String(localized: "Before: \(beforeText). During it: \(afterText)."),
                     String(localized: "Change: \(change)."),
                     trial.kept ? String(localized: "It was kept on.") : String(localized: "It ended with its week.")]
        if let running = input.running {
            let current = running.experiment.shortName(locale: locale, calendar: calendar)
            facts.append(String(localized: "This week's experiment: \(current)."))
        }

        var visual: AskVisual?
        let beforeName = String(localized: "Before"), duringName = String(localized: "During it")
        switch metric {
        case .sessionRate:
            let then = percent(before), now = percent(after)
            visual = .rows([AskRow(name: beforeName, value: before, text: beforeText),
                            AskRow(name: duringName, value: after, text: afterText)],
                           tone: .focus, summary: String(localized: "Focus rate before \(then), during it \(now)."))
        case .siteMinutes:
            let widest = max(1, before, after)
            let then = Int(before.rounded()), now = Int(after.rounded())
            visual = .rows([AskRow(name: beforeName, value: before / widest, text: beforeText),
                            AskRow(name: duringName, value: after / widest, text: afterText)],
                           tone: .drift, summary: String(localized: "Minutes a day before \(then), during it \(now)."))
        case .firstSession:
            visual = nil
        case .callDayFocus, .weekdayFocus:
            let widest = max(1, before, after)
            let then = WindowFormat.hm(before), now = WindowFormat.hm(after)
            visual = .rows([AskRow(name: beforeName, value: before / widest, text: beforeText),
                            AskRow(name: duringName, value: after / widest, text: afterText)],
                           tone: .focus, summary: String(localized: "Focused \(then) a day before, \(now) during it."))
        }
        return AskFacts(lead: lead, detail: detail, facts: facts + [basis], visual: visual, basis: basis)
    }

    private func metricText(_ metric: CoachMetric, _ value: Double) -> String {
        switch metric {
        case .sessionRate:  return percent(value)
        case .siteMinutes:
            let minutes = Int(value.rounded())
            return String(localized: "\(minutes) min a day")
        case .firstSession: return clock(minutes: Int(value.rounded()))
        case .callDayFocus, .weekdayFocus:
            let time = WindowFormat.hm(value)
            return String(localized: "\(time) focused a day")
        }
    }

    // MARK: Questions it can't answer

    func cantAnswer(suggestion: String?) -> AskFacts {
        AskFacts(lead: String(localized: "That's not something FocusGuard can see."),
                 detail: String(localized: "It sees which app or site you used, when, and for how long. It can't see what you did inside them."),
                 basis: String(localized: "Worked out on this Mac"),
                 suggestion: suggestion)
    }

    // MARK: - Pieces

    static let rateMeaning = String(localized: "Focus rate is focused time against focused plus drifted time.")

    private func tooLittle(_ basis: String) -> AskFacts {
        AskFacts(lead: String(localized: "Too little tracked to tell yet."),
                 detail: String(localized: "Ask again after a few more days of work with FocusGuard running."),
                 basis: basis)
    }

    private func basisLine(_ days: [DaySummary], sessions: Int) -> String {
        sessions > 0 ? basisLine(sessions: sessions) : basisLine(daysTracked: activeDays(days))
    }

    private func basisLine(sessions: Int) -> String {
        let period = Self.period
        return String(localized: "\(period) · \(sessions) sessions", comment: "Plural on sessions: 1 session / 2 sessions. From the last 4 weeks · 36 sessions")
    }

    private func basisLine(daysTracked days: Int) -> String {
        let period = Self.period
        return String(localized: "\(period) · \(days) days tracked", comment: "Plural on days: 1 day tracked / 2 days tracked. From the last 4 weeks · 12 days tracked")
    }

    /// "Slack 2h, Mail 40m", a chart's values for VoiceOver.
    private static func nameList(_ items: [(name: String, value: String)]) -> String {
        items.map { "\($0.name) \($0.value)" }.joined(separator: ", ")
    }

    private func tracked(_ day: DaySummary) -> TimeInterval {
        day.breakdown.focus + day.breakdown.neutral + day.breakdown.distraction
    }

    func activeDays(_ days: [DaySummary]) -> Int {
        days.filter { tracked($0) >= Self.activeDay }.count
    }

    private func startAction(_ minutes: Int) -> AskAction {
        AskAction(kind: .startSession(minutes: minutes), title: String(localized: "Start a \(minutes)-minute session"),
                  doneTitle: String(localized: "Session started"))
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
                         title: String(localized: "Limit \(host) to \(minutes) minutes a day"),
                         doneTitle: String(localized: "\(host) is limited to \(minutes) minutes a day"))
    }

    private func percent(_ rate: Double) -> String {
        CoachDraft.percent(rate)
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
        let from = clock(hours.lowerBound), to = clock(hours.upperBound)
        return String(localized: "\(from) to \(to)", comment: "Two times: 09:00 to 12:00")
    }

    private func partOfDay(_ hour: Int) -> String {
        hour < 12 ? String(localized: "Mornings") : hour < 17 ? String(localized: "Afternoons") : String(localized: "Evenings")
    }

    private var localizedCalendar: Calendar {
        var calendar = calendar
        calendar.locale = locale
        return calendar
    }

    /// "Friday", or "Fridays".
    private func weekdayName(_ weekday: Int, plural: Bool = false) -> String {
        if plural { return FocusGoal.pluralWeekday(weekday, locale: locale, calendar: calendar) }
        let symbols = localizedCalendar.weekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : String(localized: "That day")
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
    /// In the same order as `intents`.
    static let all = [
        String(localized: "When do I focus best?"),
        String(localized: "What pulls me away most?"),
        String(localized: "How did this week compare with last?"),
        String(localized: "Which day drifts most, and why?"),
        String(localized: "How long should my sessions be?"),
        String(localized: "Did last week's experiment work?"),
    ]

    private static let intents: [AskIntent] = [.bestHours, .pullsAway, .weekCompare, .driftDay, .sessionLength, .coachExperiment]

    /// "How much time on Slack this week?", offered when a name wasn't found.
    static func timeOn(_ name: String) -> String {
        String(localized: "How much time on \(name) this week?")
    }

    /// What one of the page's own questions asks, whatever the language.
    static func intent(of question: String) -> AskIntent? {
        let asked = AskText.normalized(question).trimmingCharacters(in: .whitespacesAndNewlines)
        return all.firstIndex { AskText.normalized($0) == asked }.map { intents[$0] }
    }

    /// Up to `limit` suggestions not asked yet, in order; once all have
    /// been asked, all again.
    static func next(after asked: [String], limit: Int = 3) -> [String] {
        let seen = Set(asked.map { AskText.normalized($0).trimmingCharacters(in: .whitespacesAndNewlines) })
        let fresh = all.filter { !seen.contains(AskText.normalized($0)) }
        return Array((fresh.isEmpty ? all : fresh).prefix(limit))
    }
}
