import AppIntents
import Foundation

enum FocusFilterLength: String, AppEnum {
    case whileOn, minutes25, minutes50, minutes90

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Length"
    static let caseDisplayRepresentations: [FocusFilterLength: DisplayRepresentation] = [
        .whileOn: "While the Focus is on",
        .minutes25: "25 min",
        .minutes50: "50 min",
        .minutes90: "90 min",
    ]

    /// Nil: the session runs until the Focus turns off.
    var minutes: Int? {
        switch self {
        case .whileOn:   return nil
        case .minutes25: return 25
        case .minutes50: return 50
        case .minutes90: return 90
        }
    }
}

/// Focus filter (System Settings › Focus › Work › Focus filters): start a
/// session when that Focus turns on, end it when the Focus turns off.
///
/// When a Focus turns off, the system sets every parameter back to its
/// default and calls `perform()` again, so the defaults mean "off": a
/// filter that starts nothing. What to do on the way out is remembered
/// when the session starts.
struct FocusGuardFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Start a Focus Session"
    static let description: IntentDescription? = IntentDescription(
        "Starts a FocusGuard session when this Focus turns on, and can end it when the Focus turns off. Sessions are named automatically when they end."
    )

    @Parameter(title: "Start a session when this Focus turns on", default: false)
    var startSession: Bool

    @Parameter(title: "Length", default: .whileOn)
    var length: FocusFilterLength

    @Parameter(title: "End the session when this Focus turns off", default: true)
    var endSession: Bool

    var displayRepresentation: DisplayRepresentation {
        guard startSession else { return "Don't start a session" }
        let length = length.minutes.map { "\($0)-minute session" } ?? "session while it's on"
        return DisplayRepresentation(stringLiteral: "Start a \(length)")
    }

    static func suggestedFocusFilters(for context: FocusFilterSuggestionContext) async -> [FocusGuardFocusFilter] {
        var suggestion = FocusGuardFocusFilter()
        suggestion.startSession = true
        suggestion.length = .whileOn
        suggestion.endSession = true
        return [suggestion]
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let actions = try await FocusActions.live()
        FocusFilterResponder().apply(startSession: startSession, minutes: length.minutes,
                                     endWhenOff: endSession, actions: actions)
        return .result()
    }
}

/// What the Focus filter does with each delivery. A session someone started
/// themselves is never ended by a Focus turning off, and one already running
/// isn't replaced when the Focus turns on.
@MainActor
struct FocusFilterResponder {
    var defaults: UserDefaults = .standard

    enum Keys {
        /// The session the filter started, while it runs.
        static let startedSession = "focusFilter.startedSessionID"
        /// Whether to end it when the Focus turns off, as set when it started.
        static let endWhenOff = "focusFilter.endWhenOff"
    }

    enum Outcome: Equatable {
        case started
        case ended
        case leftAlone
    }

    @discardableResult
    func apply(startSession: Bool, minutes: Int?, endWhenOff: Bool, actions: FocusActions) -> Outcome {
        let ours = defaults.string(forKey: Keys.startedSession).flatMap(UUID.init(uuidString:))
        let current = actions.sessions.currentSession?.id

        if startSession {
            // Delivered again while on (an edit, a relaunch): nothing to do.
            guard current == nil, actions.breaks.current == nil else { return .leftAlone }
            guard case .started = actions.start(minutes: minutes, openEnded: minutes == nil) else { return .leftAlone }
            defaults.set(actions.sessions.currentSession?.id.uuidString, forKey: Keys.startedSession)
            defaults.set(endWhenOff, forKey: Keys.endWhenOff)
            return .started
        }

        // The Focus turned off (or this Focus doesn't start sessions).
        defer {
            defaults.removeObject(forKey: Keys.startedSession)
            defaults.removeObject(forKey: Keys.endWhenOff)
        }
        guard let ours, ours == current, defaults.bool(forKey: Keys.endWhenOff) else { return .leftAlone }
        actions.end()
        return .ended
    }
}
