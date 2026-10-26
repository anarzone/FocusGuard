import Foundation

/// One line of the note: a bold lead and the rest, after a coloured dot.
struct CoachPoint: Codable, Hashable, Sendable {
    enum Tone: String, Codable, Sendable { case focus, drift, other }
    let lead: String
    let rest: String
    let tone: Tone

    var sentence: String { lead + rest }
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

    static func make(_ finding: CoachFinding?, experiment: CoachExperiment?,
                     locale: Locale = .current, calendar: Calendar = .current) -> CoachDraft {
        let points = finding.map { points(for: $0, locale: locale, calendar: calendar) } ?? []
        let why = experiment.map { why(for: $0, finding: finding, locale: locale, calendar: calendar) }
        var facts = points.map(\.sentence)
        if let experiment {
            facts.append("Suggested experiment: \(experiment.title(locale: locale, calendar: calendar)). "
                         + experiment.effect(locale: locale, calendar: calendar))
        }
        return CoachDraft(headline: finding.map { headline(for: $0, locale: locale, calendar: calendar) }
                              ?? "A steady week, with nothing that stood out.",
                          points: points, why: why, facts: facts)
    }

    static func headline(for finding: CoachFinding, locale: Locale, calendar: Calendar) -> String {
        switch finding {
        case .timeOfDay(let f):
            return "Your sessions \(f.weak.phrase(locale: locale, calendar: calendar)) are where focus slips."
        case .afterSessions(let f):
            return "You reach for \(f.name) right after most sessions."
        case .driftDay(let f):
            return "\(weekday(f.day, locale: locale, calendar: calendar)) drifted most."
        case .lateStarts:
            return "Days that started early focused more."
        }
    }

    static func points(for finding: CoachFinding, locale: Locale, calendar: Calendar) -> [CoachPoint] {
        switch finding {
        case .timeOfDay(let f):
            var points = [
                CoachPoint(lead: "\(capitalized(f.weak.phrase(locale: locale, calendar: calendar))): \(percent(f.weakRate))",
                           rest: " focus rate across \(counted(f.weakSessions, "session")).", tone: .drift),
                CoachPoint(lead: "\(capitalized(f.strong.phrase(locale: locale, calendar: calendar))): \(percent(f.strongRate))",
                           rest: " across \(counted(f.strongSessions, "session")).", tone: .focus),
            ]
            if f.lateDriftShare >= 0.5 {
                points.append(CoachPoint(lead: "Most of that drift came late:",
                                         rest: " \(percent(f.lateDriftShare)) of it after the 25th minute.", tone: .other))
            }
            return points
        case .afterSessions(let f):
            return [
                CoachPoint(lead: "\(f.name) within \(f.withinMinutes) minutes",
                           rest: " of finishing \(f.count) of \(f.sessions) sessions.", tone: .drift),
                CoachPoint(lead: "About \(minutes(f.dailySeconds)) a day",
                           rest: " on \(f.name) last week.", tone: .other),
            ]
        case .driftDay(let f):
            return [
                CoachPoint(lead: "\(weekday(f.day, locale: locale, calendar: calendar)): \(duration(f.drift)) of drift,",
                           rest: " against \(duration(f.othersAverage)) on the other days.", tone: .drift),
                CoachPoint(lead: "\(f.name) was \(duration(f.targetSeconds))", rest: " of it.", tone: .other),
            ]
        case .lateStarts(let f):
            let cutoff = clock(minutes: f.cutoff, locale: locale, calendar: calendar)
            return [
                CoachPoint(lead: "First session before \(cutoff): \(duration(f.earlyFocus)) focused",
                           rest: " a day, over \(counted(f.earlyDays, "day")).", tone: .focus),
                CoachPoint(lead: "From \(cutoff) or later: \(duration(f.lateFocus))",
                           rest: " a day, over \(counted(f.lateDays, "day")).", tone: .drift),
            ]
        }
    }

    static func why(for experiment: CoachExperiment, finding: CoachFinding?, locale: Locale, calendar: Calendar) -> String {
        switch experiment {
        case let .siteLimit(host, minutes):
            return "\(host) stays open to you, but it blocks once you've had \(minutes) minutes in a day."
        case .shorterSessions:
            if case .timeOfDay(let f)? = finding, f.lateDriftShare >= 0.5 {
                return "Most of the drift came after the 25th minute, so a shorter session ends before it does."
            }
            return "A shorter session is easier to keep focused all the way through."
        case let .stricterPreset(hours, preset):
            let when = hours.phrase(locale: locale, calendar: calendar)
            switch preset {
            case .strict:   return "With Strict \(when), a distraction is blocked as soon as it opens."
            case .standard: return "With Standard \(when), a distraction is blocked after 90 seconds."
            case .gentle:   return "With Gentle \(when), a distraction is blocked after 3 minutes."
            }
        case let .earlierMorningPlan(hour):
            return "The morning plan suggests today's sessions; from \(CoachExperiment.clock(hour, locale: locale, calendar: calendar)) it comes before the day fills up."
        }
    }

    // MARK: - Formatting

    static func percent(_ rate: Double) -> String { "\(Int((rate * 100).rounded()))%" }

    /// "41 min".
    static func minutes(_ seconds: TimeInterval) -> String { "\(Int((seconds / 60).rounded())) min" }

    /// "2h 10m", "50m".
    static func duration(_ seconds: TimeInterval) -> String {
        FocusGoal.format(minutes: Int((seconds / 60).rounded()))
    }

    static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(count == 1 ? noun : noun + "s")"
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
        text.prefix(1).uppercased() + text.dropFirst()
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

    static let instructions = """
        You reword a weekly focus note for one person. Use only the facts you are given. Never add \
        numbers, sites, apps, days or times that are not in the facts. Speak to the person as "you", \
        plain and kind. No emoji, no quotation marks, no exclamation marks.
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
        guard let answer = try? await model.respond(Answer.self, instructions: Self.instructions, prompt: prompt,
                                                    shape: Self.shape(withWhy: draft.why != nil)) else { return plain }

        let allowed = draft.facts + [draft.headline, draft.why ?? ""]
        let headline = Self.accept(answer.headline, allowed: allowed, maxLength: 110)
        let why = draft.why == nil ? nil : answer.why.flatMap { Self.accept($0, allowed: allowed, maxLength: 170) }
        return CoachWording(headline: headline ?? draft.headline, why: why ?? draft.why,
                            onDevice: headline != nil || why != nil)
    }

    /// The model's reply as one clean sentence, or nil when it's empty, too
    /// long, or names a number or a site that isn't in `allowed`.
    static func accept(_ reply: String, allowed: [String], maxLength: Int) -> String? {
        let line = reply.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let text = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’*_ "))
        guard text.count >= 12, text.count <= maxLength else { return nil }
        let source = allowed.joined(separator: " ").lowercased()
        let known = Set(numbers(in: source))
        guard numbers(in: text).allSatisfy(known.contains) else { return nil }
        let sites = text.lowercased().split(whereSeparator: { $0.isWhitespace || ",;:()".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".!?")) }
            .filter { $0.contains(".") }
        guard sites.allSatisfy(source.contains) else { return nil }
        return text.last.map { ".!?".contains($0) } == true ? text : text + "."
    }

    static func numbers(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isNumber }).map(String.init)
    }
}
