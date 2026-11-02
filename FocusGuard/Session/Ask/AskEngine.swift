import Foundation

/// An answer as the page shows it.
struct AskAnswer: Equatable, Sendable {
    let lead: String
    let detail: String
    let visual: AskVisual?
    let basis: String
    let action: AskAction?
    let suggestion: String?
    /// Whether the on-device model wrote the words.
    let onDevice: Bool

    init(_ facts: AskFacts, lead: String? = nil, detail: String? = nil, onDevice: Bool = false) {
        self.lead = lead ?? facts.lead
        self.detail = detail ?? facts.detail
        self.visual = facts.visual
        self.basis = facts.basis
        self.action = facts.action
        self.suggestion = facts.suggestion
        self.onDevice = onDevice
    }
}

/// Asks the on-device model to put the facts in its own words, and keeps
/// them only when they say nothing the facts don't (`CoachWriter.accept`).
/// Without a model, with nothing to work from, or when it strays, the
/// template words stay.
struct AskWriter {
    let model: (any OnDeviceModel)?

    static let instructions = """
        You answer one person's question about their own focus time, tracked by an app on their Mac. \
        Use only the facts you are given. Never add numbers, sites, apps, days or times that are not in the facts, \
        and never guess at what they did inside an app or a page. Speak to the person as "you", plain and short. \
        No emoji, no quotation marks, no exclamation marks.
        """

    static let shape = AnswerShape.object([
        .init("lead", "The answer in one short sentence, at most 12 words", .text),
        .init("detail", "One or two sentences with the numbers behind it, at most 40 words", .text),
    ])

    private struct Answer: Decodable {
        let lead: String
        let detail: String
    }

    func write(_ facts: AskFacts, question: String) async -> AskAnswer {
        let plain = AskAnswer(facts)
        guard let model, !facts.facts.isEmpty else { return plain }
        let prompt = "Question: \(question)\nFacts:\n" + facts.facts.map { "- \($0)" }.joined(separator: "\n")
            + "\nPlain answer: \(facts.lead) \(facts.detail)"
        guard let answer = try? await model.respond(Answer.self, instructions: Self.instructions, prompt: prompt,
                                                    shape: Self.shape) else { return plain }
        let allowed = facts.facts + [facts.lead, facts.detail]
        // Both or neither, so the lead and the detail never disagree.
        guard let lead = CoachWriter.accept(answer.lead, allowed: allowed, maxLength: 100),
              let detail = CoachWriter.accept(answer.detail, allowed: allowed, maxLength: 280) else { return plain }
        return AskAnswer(facts, lead: lead, detail: detail, onDevice: true)
    }
}

/// Answers one question: sorts it (model or keywords), works out the facts
/// by rules (on `StatsStore` for anything that reads the store), and has
/// the model word them, or keeps the template words.
struct AskEngine {
    let stats: StatsStore
    var model: (any OnDeviceModel)?
    var coach = AskCoachInput()
    var coachShipped = FeatureFlags.coach
    var settings = AskContext()
    /// Questions asked before this one, so a suggestion offers a new one.
    var asked: [String] = []
    var now: Date = .now
    var calendar: Calendar = .current
    var locale: Locale = .current

    func answer(_ text: String) async -> AskAnswer {
        let question = await AskClassifier(model: model).classify(text)
        let builder = AskFactsBuilder(now: now, calendar: calendar, locale: locale, context: settings)
        let facts: AskFacts
        switch question.intent {
        case .coachExperiment:
            facts = builder.coach(coach, shipped: coachShipped)
        case .unknown:
            facts = builder.cantAnswer(suggestion: AskSuggestions.next(after: asked + [text], limit: 1).first)
        default:
            facts = await stats.askFacts(question, settings: settings, now: now, calendar: calendar, locale: locale)
        }
        return await AskWriter(model: model).write(facts, question: text)
    }
}

/// The Ask page's conversation. Kept in memory only, for as long as the
/// window is open; "New question" clears it.
@MainActor
@Observable
final class AskConversation {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let question: String
        /// Nil while it's being worked out.
        var answer: AskAnswer?
        /// Its button was used.
        var acted = false
    }

    private(set) var turns: [Turn] = []
    /// What went wrong with the last button, for a moment.
    private(set) var actionNote: (turn: UUID, text: String)?

    /// Apple's model, or nil without Apple Intelligence.
    @ObservationIgnored var model: () -> (any OnDeviceModel)? = OnDeviceAI.writer
    @ObservationIgnored private var generation = 0

    var isWorking: Bool { turns.last.map { $0.answer == nil } ?? false }

    /// The chips under the conversation: questions not asked yet.
    var suggestions: [String] { AskSuggestions.next(after: turns.map(\.question)) }

    func ask(_ text: String, appState: AppState) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isWorking else { return }
        let engine = AskEngine(stats: appState.stats, model: model(),
                               coach: AskCoachInput(finished: WeeklyCoach.shared.state.finished,
                                                    running: WeeklyCoach.shared.state.running),
                               settings: Self.settings(appState), asked: turns.map(\.question))
        let turn = Turn(question: question)
        turns.append(turn)
        actionNote = nil
        let round = generation
        Task {
            let answer = await engine.answer(question)
            guard self.generation == round, let index = self.turns.firstIndex(where: { $0.id == turn.id }) else { return }
            self.turns[index].answer = answer
        }
    }

    /// "New question": back to the first page; an answer still on its way is dropped.
    func clear() {
        generation += 1
        turns = []
        actionNote = nil
    }

    /// Carries out an answer's button, the way the rest of the app does it.
    func perform(_ action: AskAction, in turnID: UUID, appState: AppState) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }), !turns[index].acted else { return }
        switch action.kind {
        case let .limit(host, minutes):
            guard appState.limits.addLimit(target: host, isSite: true, minutes: minutes) != nil else {
                actionNote = (turnID, String(localized: "That limit couldn't be set. Try it in Settings › Blocking."))
                return
            }
        case let .startSession(minutes):
            let actions = FocusActions(sessions: appState.sessionManager, breaks: appState.breakManager,
                                       startBreak: { [weak appState] in appState?.startBreak(durationMinutes: $0) })
            switch actions.start(minutes: minutes) {
            case .started: break
            case .alreadyRunning:
                actionNote = (turnID, String(localized: "A session is already running."))
                return
            case .onStrictBreak:
                actionNote = (turnID, String(localized: "The break has to finish first."))
                return
            }
        case let .planSession(at):
            appState.habits.plan(appState.habits.plannedSlots + [at])
        }
        turns[index].acted = true
        actionNote = nil
    }

    /// What the rules need from settings right now.
    static func settings(_ appState: AppState) -> AskContext {
        AskContext(limitedSites: Set(appState.limits.statuses.filter(\.isSite).map(\.target)),
                   busy: appState.sessionManager.currentSession != nil || appState.breakManager.isOnBreak,
                   sessionMinutes: FocusActions.usualMinutes())
    }
}
