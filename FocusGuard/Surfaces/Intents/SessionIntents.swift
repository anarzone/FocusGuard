import AppIntents
import Foundation

// Actions for Shortcuts, Siri and Spotlight. They run in the app's own
// process (the system launches FocusGuard if it isn't running) and act on
// the live session through `FocusActions`.

struct StartFocusSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Focus Session"
    static let description: IntentDescription? = IntentDescription("Starts a FocusGuard focus session. Leave the length empty to use your usual one.")

    @Parameter(title: "Minutes", inclusiveRange: (5, 480))
    var minutes: Int?

    @Parameter(title: "Name", description: "Leave empty to have it named when it ends.")
    var name: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Start a \(\.$minutes)-minute focus session") {
            \.$name
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let actions = try await FocusActions.live()
        return .result(dialog: IntentDialog(stringLiteral: IntentWords.start(actions.start(minutes: minutes, label: name))))
    }
}

struct EndFocusSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "End Focus Session"
    static let description: IntentDescription? = IntentDescription("Ends the running FocusGuard session.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let actions = try await FocusActions.live()
        return .result(dialog: IntentDialog(stringLiteral: IntentWords.end(actions.end())))
    }
}

enum PauseModeOption: String, AppEnum {
    case toggle, pause, resume

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pause or resume"
    static let caseDisplayRepresentations: [PauseModeOption: DisplayRepresentation] = [
        .toggle: "Pause or resume",
        .pause: "Pause",
        .resume: "Resume",
    ]

    var mode: FocusActions.PauseMode {
        switch self {
        case .toggle: return .toggle
        case .pause:  return .pause
        case .resume: return .resume
        }
    }
}

struct PauseFocusSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or Resume Focus Session"
    static let description: IntentDescription? = IntentDescription("Pauses the running FocusGuard session, or resumes it if it's paused.")

    @Parameter(title: "Action", default: .toggle)
    var action: PauseModeOption

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) the focus session")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let actions = try await FocusActions.live()
        return .result(dialog: IntentDialog(stringLiteral: IntentWords.pause(actions.pauseOrResume(action.mode))))
    }
}

struct TakeBreakIntent: AppIntent {
    static let title: LocalizedStringResource = "Take a Break"
    static let description: IntentDescription? = IntentDescription("Starts a FocusGuard break. A running session ends first.")

    @Parameter(title: "Minutes", default: 10, inclusiveRange: (1, 60))
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Take a \(\.$minutes)-minute break")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let actions = try await FocusActions.live()
        return .result(dialog: IntentDialog(stringLiteral: IntentWords.takeBreak(actions.takeBreak(minutes: minutes))))
    }
}

struct CurrentFocusSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Current Focus Session"
    static let description: IntentDescription? = IntentDescription("Says what's running in FocusGuard: the session and its time left, or the break.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let actions = try await FocusActions.live()
        let now = Date()
        if let state = actions.breaks.current {
            let until = state.startedAt.addingTimeInterval(state.plannedDuration)
            return .result(value: "Break", dialog: IntentDialog(stringLiteral: "On a break until \(IntentWords.clock(until))."))
        }
        guard let session = actions.sessions.currentSession else {
            return .result(value: "", dialog: "No focus session is running.")
        }
        let elapsed = actions.sessions.runningSeconds(for: session, now: now)
        let left = session.plannedDurationMinutes.map { max(0, TimeInterval($0 * 60) - elapsed) }
        var line = "“\(session.displayName)”"
        if session.pausedAt != nil { line += " is paused" }
        if let left {
            line += session.pausedAt != nil ? ", with \(IntentWords.minutes(left)) left." : ": \(IntentWords.minutes(left)) left."
        } else {
            line += session.pausedAt != nil ? " after \(IntentWords.minutes(elapsed))." : ": \(IntentWords.minutes(elapsed)) so far."
        }
        return .result(value: session.displayName, dialog: IntentDialog(stringLiteral: line))
    }
}

/// What the intents say back, kept apart so it can be tested.
enum IntentWords {
    static func start(_ result: FocusActions.StartResult) -> String {
        switch result {
        case .started(let name, let minutes, let endsAt):
            guard let minutes, let endsAt else { return "Started “\(name)”." }
            return "Started a \(minutes)-minute focus session. It ends at \(clock(endsAt))."
        case .alreadyRunning(let name):
            return "“\(name)” is already running."
        case .onStrictBreak(let until):
            return "You're on a break until \(clock(until)). Strict breaks can't end early."
        }
    }

    static func end(_ result: FocusActions.EndResult) -> String {
        switch result {
        case .ended(let name, let minutes):
            return "Ended “\(name)” after \(minutes == 1 ? "1 minute" : "\(minutes) minutes")."
        case .nothingRunning:
            return "No focus session is running."
        }
    }

    static func pause(_ result: FocusActions.PauseResult) -> String {
        switch result {
        case .paused(let name, let left):
            return left.map { "Paused “\(name)”, with \(minutes($0)) left." } ?? "Paused “\(name)”."
        case .resumed(let name, let endsAt):
            return endsAt.map { "Resumed “\(name)”. It ends at \(clock($0))." } ?? "Resumed “\(name)”."
        case .alreadyPaused(let name):
            return "“\(name)” is already paused."
        case .alreadyRunning(let name):
            return "“\(name)” is already running."
        case .nothingRunning:
            return "No focus session is running."
        }
    }

    static func takeBreak(_ result: FocusActions.BreakResult) -> String {
        switch result {
        case .started(let length, let until, let endedSession):
            let start = "Started a \(length)-minute break. Back at \(clock(until))."
            return endedSession.map { "Ended “\($0)”. " + start } ?? start
        case .alreadyOnBreak(let until):
            return "You're already on a break until \(clock(until))."
        }
    }

    /// "18 minutes", rounded up so time that's left never reads 0.
    static func minutes(_ seconds: TimeInterval) -> String {
        let value = AppState.minutesRoundedUp(seconds)
        return value == 1 ? "1 minute" : "\(value) minutes"
    }

    /// "15:40" (or "3:40 PM"), in the user's own time format.
    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
