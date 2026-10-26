import Foundation
import OSLog
import SwiftData

/// The session goal and the debrief after a session (Pro, behind
/// `FeatureFlags.debrief`).
///
/// When a session starts, the goal typed on the ready screen moves onto it.
/// When it ends, the debrief is written on this Mac by Apple's on-device
/// model and kept with the session. Without Apple Intelligence, the goal is
/// still kept and the debrief is a plain summary: time, focus rate and top
/// apps.
@MainActor
@Observable
final class DebriefCoordinator {
    /// How a session's debrief stands.
    enum Status: Equatable {
        case written
        case writing
        /// The plain summary only, and why.
        case plain(PlainReason)
    }

    enum PlainReason: Equatable {
        /// No Apple Intelligence on this Mac (macOS 26, turned on).
        case needsAppleIntelligence
        /// Too little tracked to write about.
        case tooShort
        /// The model gave up this time.
        case failed
    }

    /// Sessions whose debrief is being written now.
    private(set) var writing: Set<UUID> = []
    /// Sessions the model failed on this run of the app.
    private(set) var failed: Set<UUID> = []

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let isOptedOut: (String) -> Bool
    @ObservationIgnored private let entitlements: Entitlements
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendarSource = CalendarGoalSource()
    @ObservationIgnored var model: DebriefModel
    /// Whether the switch is on; tests turn it on before it ships.
    @ObservationIgnored var isShipped: Bool = FeatureFlags.debrief

    private static let logger = Logger(subsystem: "com.anar.focusguard", category: "debrief")

    /// Less than this tracked, and there's nothing to write about.
    static let minimumTracked: TimeInterval = 2 * 60

    init(context: ModelContext, isOptedOut: @escaping (String) -> Bool,
         model: DebriefModel? = nil, entitlements: Entitlements? = nil, defaults: UserDefaults = .standard) {
        self.context = context
        self.isOptedOut = isOptedOut
        self.model = model ?? DebriefModels.live()
        self.entitlements = entitlements ?? .shared
        self.defaults = defaults
    }

    /// Goals and debriefs are on for this user.
    var isEnabled: Bool { isShipped && entitlements.isUnlocked(.debrief) }

    /// Whether this Mac can write debriefs (Apple Intelligence on macOS 26).
    var canWrite: Bool { model.isAvailable }

    // MARK: - Goal

    /// Moves the goal typed on the ready screen onto the session that just
    /// started, and clears the field for the next one.
    func sessionStarted(_ session: Session?) {
        guard let session, isEnabled, session.goal == nil else { return }
        let typed = (defaults.string(forKey: SessionGoal.key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        session.goal = String(typed.prefix(SessionGoal.maxLength))
        defaults.set("", forKey: SessionGoal.key)
        Persistence.save(context)
    }

    /// Goals to offer under the empty field: the last one if it wasn't done,
    /// and the calendar event on now.
    func goalSuggestions(now: Date = .now) -> [GoalSuggestion] {
        guard isEnabled else { return [] }
        var descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.goal != nil && $0.endedAt != nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let last = Persistence.fetch(context, descriptor).first
        return GoalSuggestion.make(lastGoal: last?.goal, lastVerdict: last?.goalVerdict,
                                   calendarTitle: calendarSource.currentTitle(now: now))
    }

    // MARK: - Debrief

    func sessionEnded(_ session: Session) {
        write(for: session)
    }

    /// Works out the session's project and, where the model can run, writes
    /// its debrief in the background. Safe to call again: a session is only
    /// written once. Also runs when a trial starts from the debrief row.
    func write(for session: Session) {
        guard isEnabled, session.endedAt != nil, session.debriefData == nil,
              !writing.contains(session.id) else { return }
        let facts = DebriefFacts(session: session, isOptedOut: isOptedOut)
        let known = knownProjects()
        if session.project == nil {
            session.project = ProjectGuess.guess(goal: facts.goal, titles: facts.titles, apps: facts.apps, known: known)
            Persistence.save(context)
        }
        guard model.isAvailable, facts.tracked >= Self.minimumTracked else { return }

        let id = session.id
        writing.insert(id)
        failed.remove(id)
        Task {
            defer { writing.remove(id) }
            do {
                let draft = DebriefCleanup.tidy(try await model.write(DebriefPrompt(facts: facts)),
                                                hasGoal: facts.goal != nil)
                guard !session.isDeleted, session.modelContext != nil else { return }
                session.storedDebrief = draft
                if session.goalVerdict == nil { session.goalVerdict = draft.verdict }
                if draft.project != nil {
                    session.project = ProjectGuess.guess(goal: facts.goal, modelProject: draft.project,
                                                         titles: facts.titles, apps: facts.apps, known: known)
                }
                Persistence.save(context)
            } catch {
                failed.insert(id)
                Self.logger.error("debrief failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func status(for session: Session) -> Status {
        if session.debriefData != nil { return .written }
        if writing.contains(session.id) { return .writing }
        if failed.contains(session.id) { return .plain(.failed) }
        if !model.isAvailable { return .plain(.needsAppleIntelligence) }
        return .plain(.tooShort)
    }

    /// What the pane shows: the written debrief, or the plain summary.
    func debrief(for session: Session) -> SessionDebrief {
        let facts = DebriefFacts(session: session, isOptedOut: isOptedOut)
        if let stored = session.storedDebrief {
            return .written(stored, facts: facts, label: session.displayName, verdict: session.goalVerdict)
        }
        var plain = SessionDebrief.plain(facts, label: session.displayName)
        plain.verdict = session.goal == nil ? nil : session.goalVerdict
        return plain
    }

    func session(id: UUID) -> Session? {
        var descriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return Persistence.fetch(context, descriptor).first
    }

    /// The newest finished session, for the pane once the recap is gone.
    func latestFinished() -> Session? {
        var descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.endedAt != nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return Persistence.fetch(context, descriptor).first
    }

    /// The user's own call on the goal, over the debrief's.
    func correct(_ session: Session, to verdict: GoalVerdict) {
        guard session.goal != nil else { return }
        session.goalVerdict = verdict
        Persistence.save(context)
    }

    /// Projects earlier sessions counted toward, most used first.
    private func knownProjects() -> [String] {
        let since = Calendar.current.date(byAdding: .day, value: -90, to: .now) ?? .distantPast
        let rows = Persistence.fetch(context, FetchDescriptor<Session>(
            predicate: #Predicate { $0.project != nil && $0.startedAt >= since }
        ))
        var counts: [String: Int] = [:]
        for name in rows.compactMap(\.project) { counts[name, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}
