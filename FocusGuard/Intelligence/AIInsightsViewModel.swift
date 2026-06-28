import Foundation

/// Owns the state of the on-demand insights card. Created once and held by
/// `AppState`; the Reports view calls `generate(...)` on button press. Nothing
/// here runs automatically — no network happens until the user clicks.
@MainActor
final class AIInsightsViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded([String])
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let session: URLSession
    private var task: Task<Void, Never>?

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// True when AI is enabled and a secret is configured — gates the button.
    var isConfigured: Bool {
        let settings = AISettings.load()
        return settings.enabled && settings.hasSecret
    }

    func generate(
        rangeLabel: String,
        breakdown: BreakdownSnapshot,
        distractions: [DistractionEntry],
        currentStreak: Int,
        weeklyAverageFocusSeconds: TimeInterval
    ) {
        task?.cancel()
        let settings = AISettings.load()
        guard settings.enabled else {
            state = .failed("AI insights are turned off. Enable them in Settings → AI.")
            return
        }
        guard let provider = settings.makeProvider(session: session) else {
            state = .failed(LLMError.missingCredential.localizedDescription)
            return
        }

        let summary = FocusSummaryBuilder.summary(.init(
            rangeLabel: rangeLabel,
            breakdown: breakdown,
            distractions: distractions,
            currentStreak: currentStreak,
            weeklyAverageFocusSeconds: weeklyAverageFocusSeconds
        ))

        state = .loading
        task = Task { [weak self] in
            do {
                let tips = try await AIInsightsService.tips(summary: summary, provider: provider)
                if Task.isCancelled { return }
                self?.state = tips.isEmpty
                    ? .failed("The model didn't return any tips. Try again.")
                    : .loaded(tips)
            } catch {
                if Task.isCancelled { return }
                let message = (error as? LLMError)?.localizedDescription ?? error.localizedDescription
                self?.state = .failed(message)
            }
        }
    }

    func reset() {
        task?.cancel()
        state = .idle
    }
}
