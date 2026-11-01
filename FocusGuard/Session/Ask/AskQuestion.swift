import Foundation

/// What a question on the Ask page is about. Each kind has its own rules
/// for the facts (`AskFactsBuilder`); the model only ever picks a kind,
/// it never answers on its own.
enum AskIntent: String, CaseIterable, Sendable {
    case bestHours
    case pullsAway
    case weekCompare
    case driftDay
    case sessionLength
    case coachExperiment
    case appTime
    /// Nothing FocusGuard can see answers it.
    case unknown

    /// What each kind means, for the model choosing one.
    var meaning: String {
        switch self {
        case .bestHours:       return "when they focus best: the best hours or days for focus"
        case .pullsAway:       return "what distracts them or pulls them away, maybe at a time of day"
        case .weekCompare:     return "how this week compares with last week"
        case .driftDay:        return "which day of the week they drift or get distracted most"
        case .sessionLength:   return "how long their focus sessions should be, or which lengths go best"
        case .coachExperiment: return "whether the weekly coach's experiment from last week worked"
        case .appTime:         return "how much time they spent on one app or website they name"
        case .unknown:         return "anything else, such as what they did inside an app or a page"
        }
    }
}

/// Hours of the day a question names: "after lunch" is 13:00 to 15:00.
struct AskHours: Equatable, Sendable {
    /// 0...23.
    let from: Int
    /// 1...24, after `from`.
    let to: Int

    func contains(_ hour: Int) -> Bool { from <= hour && hour < to }

    /// The hours a question names, if it names any.
    static func parse(_ text: String) -> AskHours? {
        let t = AskText.normalized(text)
        if t.contains("lunch") { return AskHours(from: 13, to: 15) }
        if let hour = clockHour(in: t) {
            let after = t.contains("after \(hour.word)") || t.contains("from \(hour.word)")
            let start = after ? hour.value : max(0, hour.value - 1)
            return AskHours(from: start, to: min(24, start + 2))
        }
        let words = AskText.words(t)
        if words.contains("morning") || words.contains("mornings") { return AskHours(from: 6, to: 12) }
        if words.contains("afternoon") || words.contains("afternoons") { return AskHours(from: 12, to: 17) }
        if words.contains("evening") || words.contains("evenings") || words.contains("tonight") { return AskHours(from: 17, to: 22) }
        if words.contains("night") || words.contains("nights") || t.contains("late at night") { return AskHours(from: 21, to: 24) }
        return nil
    }

    /// "3pm", "3 pm", "15:00", "at 15" → the hour, 0...23, and how it was written.
    private static func clockHour(in text: String) -> (value: Int, word: String)? {
        if let match = text.firstMatch(of: /(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)/) {
            guard var hour = Int(match.1), (1...12).contains(hour) else { return nil }
            let pm = match.3.hasPrefix("p")
            if pm && hour < 12 { hour += 12 }
            if !pm && hour == 12 { hour = 0 }
            return (hour, String(match.0))
        }
        if let match = text.firstMatch(of: /(\d{1,2}):(\d{2})/), let hour = Int(match.1), (0...23).contains(hour) {
            return (hour, String(match.0))
        }
        if let match = text.firstMatch(of: /(?:at|after|around|from) (\d{1,2})\b/), let hour = Int(match.1), (0...23).contains(hour) {
            // "after 2" in the working day means 14:00.
            let value = hour < 7 ? hour + 12 : hour
            return (value, String(match.1))
        }
        return nil
    }
}

/// The stretch of days a question names.
enum AskPeriod: Equatable, Sendable {
    case today
    case thisWeek
    case lastWeek
    /// The last four weeks, when it names none.
    case recent

    static func parse(_ text: String) -> AskPeriod {
        let t = AskText.normalized(text)
        if AskText.words(t).contains("today") { return .today }
        if t.contains("last week") || t.contains("previous week") { return .lastWeek }
        if t.contains("this week") { return .thisWeek }
        return .recent
    }
}

/// A question, sorted: the kind the model or the keywords picked, and what
/// its words say about when.
struct AskQuestion: Equatable, Sendable {
    let text: String
    let intent: AskIntent
    let hours: AskHours?
    let period: AskPeriod

    init(text: String, intent: AskIntent) {
        self.text = text
        self.intent = intent
        self.hours = AskHours.parse(text)
        self.period = AskPeriod.parse(text)
    }
}

/// Lower-cased words, for matching questions by hand.
enum AskText {
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
    }

    /// Words without punctuation or a trailing "'s": "week's" is "week".
    static func words(_ text: String) -> Set<String> {
        Set(normalized(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { raw in
                var word = String(raw)
                if word.hasSuffix("'s") { word.removeLast(2) }
                return word.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            })
    }
}

/// Picks the kind of question from its words alone: what Ask does when
/// Apple Intelligence isn't available, or the model can't say.
enum AskIntentMatcher {
    private static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    private static let driftWords: Set<String> = [
        "drift", "drifts", "drifting", "drifted", "distract", "distracts", "distracted", "distracting",
        "distraction", "distractions", "slip", "slips", "worst", "waste", "wasted", "wasting",
    ]

    static func match(_ text: String) -> AskIntent {
        let t = AskText.normalized(text)
        let words = AskText.words(t)
        func has(_ options: String...) -> Bool { options.contains(where: words.contains) }
        func says(_ options: String...) -> Bool { options.contains(where: t.contains) }
        let drift = !words.isDisjoint(with: driftWords)
        let days = has("day", "days", "weekday", "weekdays")
            || weekdays.contains { words.contains($0) || words.contains($0 + "s") }

        if has("experiment", "experiments", "coach") { return .coachExperiment }
        if has("session", "sessions") && (has("long", "longer", "short", "shorter", "length", "lengths", "minutes")
                                          || has("best", "better", "worst")) {
            return .sessionLength
        }
        if days && drift && !has("today") { return .driftDay }
        if says("time on ", "time in ", "spend on ", "spent on ", "spend in ", "spent in ", "hours on ", "minutes on ",
                "how much time", "how long on ", "how long in ", "how long was i on", "how often") {
            return .appTime
        }
        if has("week") && has("compare", "compared", "comparison", "vs", "versus", "than", "last", "previous",
                              "better", "worse", "go", "went", "going") {
            return .weekCompare
        }
        if drift || has("pull", "pulls", "pulling", "away", "procrastinate", "procrastinating", "interrupt", "interrupts") {
            return .pullsAway
        }
        if has("focus", "focused", "focusing", "productive", "productivity", "concentrate", "peak", "zone")
            || (has("best") && has("hours", "time", "times")) {
            return .bestHours
        }
        return .unknown
    }
}

/// Sorts a question with the on-device model, choosing from `AskIntent`
/// only. Without the model, or when it fails, the keywords decide; when the
/// model can't place it but the keywords can, they win too.
struct AskClassifier {
    let model: (any OnDeviceModel)?

    static let instructions = """
        You sort one question a person asks about their own focus time, tracked by an app on their Mac, \
        into the kind it asks about. Pick the closest kind. Pick unknown when none fits.
        """

    private struct Answer: Decodable {
        let kind: String
    }

    static var shape: AnswerShape {
        .object([.init("kind", "The kind of question", .choice(AskIntent.allCases.map(\.rawValue)))])
    }

    static func prompt(_ text: String) -> String {
        "Kinds:\n" + AskIntent.allCases.map { "- \($0.rawValue): \($0.meaning)" }.joined(separator: "\n")
            + "\n\nQuestion: \(text)"
    }

    func classify(_ text: String) async -> AskQuestion {
        let fallback = AskIntentMatcher.match(text)
        guard let model,
              let answer = try? await model.respond(Answer.self, instructions: Self.instructions,
                                                    prompt: Self.prompt(text), shape: Self.shape),
              let intent = AskIntent(rawValue: answer.kind) else {
            return AskQuestion(text: text, intent: fallback)
        }
        return AskQuestion(text: text, intent: intent == .unknown ? fallback : intent)
    }
}
