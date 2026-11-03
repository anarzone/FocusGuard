import Foundation

/// One line of the note: a bold lead and the rest, after a coloured dot.
struct CoachPoint: Codable, Hashable, Sendable {
    enum Tone: String, Codable, Sendable { case focus, drift, other }
    let lead: String
    let rest: String
    let tone: Tone

    var sentence: String { lead + rest }
}

extension CoachPoint {
    /// A whole sentence with a "|" where the bold lead ends, so a translation
    /// can put the words in its own order and choose what's bold.
    init(_ sentence: String, tone: Tone) {
        let parts = sentence.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        self.init(lead: parts[0], rest: parts.count > 1 ? parts[1] : "", tone: tone)
    }
}

/// The note in plain template words, before any model rewords it.
struct CoachDraft: Equatable, Sendable {
    let headline: String
    let points: [CoachPoint]
    /// Why the experiment might help.
    let why: String?
    /// Everything the note may say, for the model and to check what it writes.
    let facts: [String]

    // MARK: - Templates

    /// - Parameter week: how last week went, for what to say when no pattern
    ///   stands out.
    static func make(_ finding: CoachFinding?, experiment: CoachExperiment?, week: (focus: TimeInterval, drift: TimeInterval)? = nil,
                     locale: Locale = .current, calendar: Calendar = .current) -> CoachDraft {
        let points = finding.map { Self.points(for: $0, locale: locale, calendar: calendar) } ?? []
        let why = experiment.map { Self.why(for: $0, finding: finding, locale: locale, calendar: calendar) }
        var facts = points.map(\.sentence)
        if let experiment {
            let title = experiment.title(locale: locale, calendar: calendar)
            let effect = experiment.effect(locale: locale, calendar: calendar)
            facts.append(String(localized: "Suggested experiment: \(title). \(effect)", comment: "A fact given to the on-device model"))
        }
        return CoachDraft(headline: finding.map { Self.headline(for: $0, locale: locale, calendar: calendar) }
                              ?? noPattern(week),
                          points: points, why: why, facts: facts)
    }

    /// With no pattern to report. "Steady" is only for a week that went well:
    /// at a 20% focus rate, or on a few minutes, it says the wrong thing.
    private static func noPattern(_ week: (focus: TimeInterval, drift: TimeInterval)?) -> String {
        guard let week else { return String(localized: "A steady week, with nothing that stood out.") }
        if week.focus + week.drift < 2 * 3600 {
            return String(localized: "Too little tracked last week to see a pattern.")
        }
        let rate = FocusRate.of(focused: week.focus, drifted: week.drift)
        if rate < 0.6 {
            let shown = percent(rate)
            return String(localized: "No one pattern stood out, but your focus rate was only \(shown).")
        }
        return rate < 0.75 ? String(localized: "No pattern stood out last week.")
            : String(localized: "A steady week, with nothing that stood out.")
    }

    static func headline(for finding: CoachFinding, locale: Locale, calendar: Calendar) -> String {
        switch finding {
        case .timeOfDay(let f):
            let when = f.weak.phrase(locale: locale, calendar: calendar)
            return String(localized: "Your sessions \(when) are where focus slips.", comment: "The phrase says when: after 17:00, before noon")
        case .afterSessions(let f):
            return String(localized: "You reach for \(f.name) right after most sessions.")
        case .driftDay(let f):
            let day = capitalized(weekday(f.day, locale: locale, calendar: calendar))
            return String(localized: "\(day) drifted most.", comment: "A day of the week, Monday")
        case .lateStarts:
            return String(localized: "Days that started early focused more.")
        case .switching(let f):
            let day = weekday(f.day, locale: locale, calendar: calendar)
            let often = every(f.minutesPerSwitch)
            return String(localized: "\(day)'s sessions switched apps \(often).", comment: "A day of the week, then how often: every 2 minutes")
        case .sessionLength(let f):
            let best = percent(f.rate), others = percent(f.longerRate)
            return String(localized: "Your \(f.minutes)-minute sessions went best: \(best), against \(others) for longer ones.")
        case .meetingDays(let f):
            let kept = percent(f.heavyFocus / max(1, f.otherFocus))
            return String(localized: "Days with \(f.callHours) hours of calls kept \(kept) of your usual focus.")
        case .appChain(let f):
            return String(localized: "\(f.sourceName) led straight to \(f.name) \(f.count) times.",
                          comment: "Plural on count: 1 time / 2 times. Two app or site names")
        case .weeklyRhythm(let f):
            let days = capitalized(CoachExperiment.weekdays(f.weekday, locale: locale, calendar: calendar))
            let weeks = spelled(f.weeks)
            return String(localized: "\(days) have been your weakest day \(weeks) weeks running.",
                          comment: "Mondays, then a number in words: three")
        }
    }

    static func points(for finding: CoachFinding, locale: Locale, calendar: Calendar) -> [CoachPoint] {
        switch finding {
        case .timeOfDay(let f):
            let weak = capitalized(f.weak.phrase(locale: locale, calendar: calendar)), weakRate = percent(f.weakRate)
            let strong = capitalized(f.strong.phrase(locale: locale, calendar: calendar)), strongRate = percent(f.strongRate)
            var points = [
                CoachPoint(String(localized: "\(weak): \(weakRate)| focus rate across \(f.weakSessions) sessions.",
                                  comment: "Plural on sessions: 1 session / 2 sessions. The | ends the bold start"), tone: .drift),
                CoachPoint(String(localized: "\(strong): \(strongRate)| across \(f.strongSessions) sessions.",
                                  comment: "Plural on sessions: 1 session / 2 sessions. The | ends the bold start"), tone: .focus),
            ]
            if f.lateDriftShare >= 0.5 {
                let late = percent(f.lateDriftShare)
                points.append(CoachPoint(String(localized: "Most of that drift came late:| \(late) of it after the 25th minute.",
                                                comment: "The | ends the bold start"), tone: .other))
            }
            return points
        case .afterSessions(let f):
            let daily = minutes(f.dailySeconds)
            return [
                CoachPoint(String(localized: "\(f.name) within \(f.withinMinutes) minutes| of finishing \(f.count) of \(f.sessions) sessions.",
                                  comment: "The | ends the bold start"), tone: .drift),
                CoachPoint(String(localized: "About \(daily) a day| on \(f.name) last week.", comment: "The | ends the bold start"), tone: .other),
            ]
        case .driftDay(let f):
            let day = capitalized(weekday(f.day, locale: locale, calendar: calendar))
            let drift = duration(f.drift), usual = duration(f.othersAverage), target = duration(f.targetSeconds)
            return [
                CoachPoint(String(localized: "\(day): \(drift) of drift,| against \(usual) on the other days.",
                                  comment: "The | ends the bold start"), tone: .drift),
                CoachPoint(String(localized: "\(f.name) was \(target)| of it.", comment: "The | ends the bold start"), tone: .other),
            ]
        case .lateStarts(let f):
            let cutoff = clock(minutes: f.cutoff, locale: locale, calendar: calendar)
            let early = duration(f.earlyFocus), late = duration(f.lateFocus)
            return [
                CoachPoint(String(localized: "First session before \(cutoff): \(early) focused| a day, over \(f.earlyDays) days.",
                                  comment: "Plural on days: 1 day / 2 days. The | ends the bold start"), tone: .focus),
                CoachPoint(String(localized: "From \(cutoff) or later: \(late)| a day, over \(f.lateDays) days.",
                                  comment: "Plural on days: 1 day / 2 days. The | ends the bold start"), tone: .drift),
            ]
        case .switching(let f):
            let day = capitalized(weekday(f.day, locale: locale, calendar: calendar))
            let often = every(f.minutesPerSwitch), usual = every(f.usualMinutesPerSwitch)
            let hours = f.hours.phrase(locale: locale, calendar: calendar)
            return [
                CoachPoint(String(localized: "\(day): a new app \(often)| in sessions, \(f.switches) changes in all.",
                                  comment: "Plural on changes: 1 change / 2 changes. The | ends the bold start"), tone: .drift),
                f.noneOnOtherDays
                    ? CoachPoint(String(localized: "Other days:| no changes like these.", comment: "The | ends the bold start"), tone: .focus)
                    : CoachPoint(String(localized: "Other days:| \(usual).", comment: "How often: every 2 minutes. The | ends the bold start"), tone: .focus),
                CoachPoint(String(localized: "Most of those sessions| ran \(hours).", comment: "When: after 17:00. The | ends the bold start"),
                           tone: .other),
            ]
        case .sessionLength(let f):
            let best = percent(f.rate), others = percent(f.longerRate)
            return [
                CoachPoint(String(localized: "\(f.minutes)-minute sessions: \(best)| focus rate across \(f.sessions) sessions.",
                                  comment: "Plural on the last number: 1 session / 2 sessions. The | ends the bold start"), tone: .focus),
                CoachPoint(String(localized: "Longer ones: \(others)| across \(f.longerSessions) sessions.",
                                  comment: "Plural on sessions: 1 session / 2 sessions. The | ends the bold start"), tone: .drift),
                CoachPoint(String(localized: "Over \(f.weeks) weeks,| not just last week.",
                                  comment: "Plural on weeks: 1 week / 2 weeks. The | ends the bold start"), tone: .other),
            ]
        case .meetingDays(let f):
            let heavy = duration(f.heavyFocus), others = duration(f.otherFocus)
            return [
                CoachPoint(String(localized: "\(f.heavyDays) days with \(f.callHours) hours of calls or more: \(heavy)| focused a day.",
                                  comment: "Plural on the first number: 1 day / 2 days. The | ends the bold start"), tone: .drift),
                CoachPoint(String(localized: "The other \(f.otherDays) days: \(others)| a day.",
                                  comment: "Plural on days: 1 day / 2 days. The | ends the bold start"), tone: .focus),
            ]
        case .appChain(let f):
            let daily = minutes(f.dailySeconds)
            return [
                CoachPoint(String(localized: "From \(f.sourceName) to \(f.name)| within seconds, \(f.count) times last week.",
                                  comment: "Plural on count: 1 time / 2 times. The | ends the bold start"), tone: .drift),
                CoachPoint(String(localized: "About \(daily) a day| on \(f.name) last week.", comment: "The | ends the bold start"), tone: .other),
            ]
        case .weeklyRhythm(let f):
            let days = capitalized(CoachExperiment.weekdays(f.weekday, locale: locale, calendar: calendar))
            let focus = duration(f.focus), others = duration(f.othersFocus)
            return [
                CoachPoint(String(localized: "\(days): \(focus) focused| on average, the lowest of each of the last \(f.weeks) weeks.",
                                  comment: "Mondays. The | ends the bold start"), tone: .drift),
                CoachPoint(String(localized: "Your other days: \(others)| on average.", comment: "The | ends the bold start"), tone: .focus),
            ]
        }
    }

    static func why(for experiment: CoachExperiment, finding: CoachFinding?, locale: Locale, calendar: Calendar) -> String {
        switch experiment {
        case let .siteLimit(host, minutes):
            return String(localized: "\(host) stays open to you, but it blocks once you've had \(minutes) minutes in a day.")
        case .shorterSessions:
            if case .timeOfDay(let f)? = finding, f.lateDriftShare >= 0.5 {
                return String(localized: "Most of the drift came after the 25th minute, so a shorter session ends before it does.")
            }
            return String(localized: "A shorter session is easier to keep focused all the way through.")
        case let .stricterPreset(hours, preset):
            let when = hours.phrase(locale: locale, calendar: calendar)
            switch preset {
            case .strict:   return String(localized: "With Strict \(when), a distraction is blocked as soon as it opens.", comment: "Strict is a preset's name. When: after 17:00")
            case .standard: return String(localized: "With Standard \(when), a distraction is blocked after 90 seconds.", comment: "Standard is a preset's name. When: after 17:00")
            case .gentle:   return String(localized: "With Gentle \(when), a distraction is blocked after 3 minutes.", comment: "Gentle is a preset's name. When: after 17:00")
            }
        case let .earlierMorningPlan(hour):
            let time = CoachExperiment.clock(hour, locale: locale, calendar: calendar)
            return String(localized: "The morning plan suggests today's sessions; from \(time) it comes before the day fills up.")
        case let .sessionLength(minutes):
            return String(localized: "Your \(minutes)-minute sessions held their focus best, so every session starts at that length.")
        case let .sessionBeforeFirstCall(minutes):
            return String(localized: "A \(minutes)-minute session before the first call gets some focus in before the calls break up the day.")
        case let .weekdayGoal(weekday, _):
            let days = CoachExperiment.weekdays(weekday, locale: locale, calendar: calendar)
            return String(localized: "A goal you can meet on \(days) keeps the streak going, and every other day keeps your usual goal.", comment: "Mondays")
        }
    }

    // MARK: - Formatting

    static func percent(_ rate: Double) -> String {
        let value = Int((rate * 100).rounded())
        return String(localized: "\(value)%", comment: "Percentage")
    }

    /// "41 min".
    static func minutes(_ seconds: TimeInterval) -> String {
        let value = Int((seconds / 60).rounded())
        return String(localized: "\(value) min", comment: "Compact minutes")
    }

    /// "2h 10m", "50m".
    static func duration(_ seconds: TimeInterval) -> String {
        FocusGoal.format(minutes: Int((seconds / 60).rounded()))
    }

    /// "every minute", "every 2 minutes".
    static func every(_ minutes: Double) -> String {
        let value = Int(minutes.rounded())
        return minutes < 1.5 ? String(localized: "every minute")
            : String(localized: "every \(value) minutes", comment: "How often. Never 1, so there's no singular")
    }

    /// "three", for small counts in a sentence.
    static func spelled(_ n: Int) -> String {
        guard (0...10).contains(n) else { return "\(n)" }
        let words = NumberFormatter()
        words.numberStyle = .spellOut
        return words.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func weekday(_ day: Date, locale: Locale, calendar: Calendar) -> String {
        var style = Date.FormatStyle().weekday(.wide)
        style.locale = locale
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return day.formatted(style)
    }

    static func clock(minutes: Int, locale: Locale, calendar: Calendar) -> String {
        let date = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0,
                                 of: Date(timeIntervalSince1970: 0)) ?? .now
        return HabitFormat.time(date, locale: locale, calendar: calendar)
    }

    static func capitalized(_ text: String) -> String {
        text.prefix(1).localizedUppercase + text.dropFirst()
    }
}

/// Words the note ends up with, and whether the model wrote them.
struct CoachWording: Equatable, Sendable {
    let headline: String
    let why: String?
    let onDevice: Bool
}

/// Asks the on-device model to reword the draft's headline and "why", and
/// keeps its words only when they say nothing the facts don't. Without a
/// model, or when it strays or fails, the template words stay.
struct CoachWriter {
    let model: (any OnDeviceModel)?
    /// What the model is told: `instructions`, or `monthInstructions` for
    /// the month review.
    var brief: String = CoachWriter.instructions

    static let instructions = """
        You reword a weekly focus note for one person. Use only the facts you are given. Never add \
        numbers, sites, apps, days or times that are not in the facts. Speak to the person as "you", \
        plain and kind. No emoji, no quotation marks, no exclamation marks.
        """

    static let monthInstructions = """
        You reword the headline of a monthly focus review for one person. Use only the facts you are \
        given. Never add numbers, sites, apps, days, months or times that are not in the facts. Speak \
        to the person as "you", plain and kind. No emoji, no quotation marks, no exclamation marks.
        """

    private struct Answer: Decodable {
        let headline: String
        let why: String?
    }

    static func shape(withWhy: Bool) -> AnswerShape {
        var fields = [AnswerShape.Field("headline", "The note's headline: one sentence, at most 14 words", .text)]
        if withWhy {
            fields.append(.init("why", "One sentence, at most 24 words, on why the experiment might help", .text))
        }
        return .object(fields)
    }

    func write(_ draft: CoachDraft) async -> CoachWording {
        let plain = CoachWording(headline: draft.headline, why: draft.why, onDevice: false)
        guard let model else { return plain }
        var prompt = "Facts:\n" + draft.facts.map { "- \($0)" }.joined(separator: "\n")
            + "\nPlain headline: \(draft.headline)"
        if let why = draft.why { prompt += "\nPlain reason for the experiment: \(why)" }
        guard let answer = try? await model.respond(Answer.self, instructions: brief, prompt: prompt,
                                                    shape: Self.shape(withWhy: draft.why != nil)) else { return plain }

        let allowed = draft.facts + [draft.headline, draft.why ?? ""]
        // A headline keeps its figures: "Focus rose, afternoons declined
        // slightly" for "82h 30m at 75%" and a 25-point fall isn't rewording.
        let headline = Self.accept(answer.headline, allowed: allowed, maxLength: 110,
                                   mustKeep: Set(Self.numbers(in: draft.headline.lowercased())))
        let why = draft.why == nil ? nil : answer.why.flatMap { Self.accept($0, allowed: allowed, maxLength: 170) }
        return CoachWording(headline: headline ?? draft.headline, why: why ?? draft.why,
                            onDevice: headline != nil || why != nil)
    }

    /// Words that change what a sentence says: fine when the facts use them,
    /// otherwise the model is judging, comparing or explaining by itself.
    private static let meaningWords: Set<String> = [
        "slightly", "somewhat", "barely", "little", "more", "less", "higher", "lower", "better", "worse", "rose", "risen", "fell", "fallen",
        "declined", "dropped", "improved", "improving", "stronger", "weaker", "most", "least", "because", "due", "caused", "since",
        "therefore", "morning", "mornings", "afternoon", "afternoons", "evening", "evenings", "night", "nights", "noon", "lunch",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "mondays", "tuesdays", "wednesdays", "thursdays",
        "fridays", "saturdays", "sundays", "january", "february", "march", "april", "june", "july", "august", "september", "october",
        "november", "december", "etwas", "mehr", "weniger", "besser", "schlechter", "gestiegen", "gesunken", "weil", "wegen", "morgens",
        "vormittags", "nachmittags", "abends", "nachts", "montags", "dienstags", "mittwochs", "donnerstags", "freitags", "samstags", "sonntags",
    ]
    /// Numbers in words dodge the check on digits, and "2m" became "two meters".
    private static let spelledNumbers: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "twenty", "thirty", "forty",
        "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "half", "twice", "double", "meter", "meters", "metre", "metres",
        "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn", "elf", "zwölf", "zwanzig", "dreißig", "hälfte", "doppelt",
    ]

    /// The model's reply as one clean sentence, or nil when it's empty, too
    /// long, drops a number in `mustKeep`, or says something `allowed` doesn't:
    /// a number, a site, a comparison, a cause, a day or a time of day.
    static func accept(_ reply: String, allowed: [String], maxLength: Int, mustKeep: Set<String> = []) -> String? {
        let line = reply.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let text = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’*_ "))
        guard text.count >= 12, text.count <= maxLength else { return nil }
        let source = allowed.joined(separator: " ").lowercased()
        let known = Set(numbers(in: source))
        guard numbers(in: text).allSatisfy(known.contains), mustKeep.isSubset(of: Set(numbers(in: text))) else { return nil }
        let sourceWords = words(in: source), textWords = words(in: text.lowercased())
        guard textWords.subtracting(sourceWords).isDisjoint(with: meaningWords),
              textWords.subtracting(sourceWords).isDisjoint(with: spelledNumbers) else { return nil }
        let sites = text.lowercased().split(whereSeparator: { $0.isWhitespace || ",;:()".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".!?")) }
            .filter { $0.contains(".") }
        guard sites.allSatisfy(source.contains) else { return nil }
        return text.last.map { ".!?".contains($0) } == true ? text : text + "."
    }

    private static func words(in text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isLetter }).map(String.init))
    }

    static func numbers(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isNumber }).map(String.init)
    }
}
