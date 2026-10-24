import AppIntents
import SwiftUI

enum FocusPeriodOption: String, AppEnum {
    case today, yesterday, thisWeek

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Period"
    static let caseDisplayRepresentations: [FocusPeriodOption: DisplayRepresentation] = [
        .today: "Today",
        .yesterday: "Yesterday",
        .thisWeek: "This week",
    ]

    var period: FocusPeriod {
        switch self {
        case .today:     return .today
        case .yesterday: return .yesterday
        case .thisWeek:  return .thisWeek
        }
    }
}

/// "How focused was I today?": focused time, focus rate and sessions.
/// Returns the focused minutes, so a shortcut can use the number.
struct FocusSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Focused Time"
    static let description: IntentDescription? = IntentDescription("Says how much you focused, your focus rate and how many sessions you ran.")

    @Parameter(title: "Period", default: .today)
    var period: FocusPeriodOption

    static var parameterSummary: some ParameterSummary {
        Summary("Get focused time for \(\.$period)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog & ShowsSnippetView {
        let appState = try await SurfaceHost.ready()
        let summary = await FocusNumbers.summary(period.period, container: appState.container)
        return .result(
            value: Int(summary.focused / 60),
            dialog: IntentDialog(stringLiteral: FocusNumbers.sentence(for: summary)),
            view: FocusSummarySnippet(summary: summary, goal: FocusGoal.dailySeconds)
        )
    }
}

/// The Spotlight and Siri answer: today's ring against the goal, then the
/// numbers.
struct FocusSummarySnippet: View {
    let summary: FocusSummary
    let goal: TimeInterval

    private static let indigo = Color(red: 0x61 / 255, green: 0x55 / 255, blue: 0xF5 / 255)

    private var showsGoal: Bool { summary.period != .thisWeek && goal > 0 }
    private var progress: Double { showsGoal ? min(1, summary.focused / goal) : summary.focusRate }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().stroke(Self.indigo.opacity(0.16), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: max(0.001, progress))
                    .stroke(Self.indigo, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(heading).font(.caption).foregroundStyle(.secondary)
                Text("\(FocusNumbers.duration(summary.focused)) focused")
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                if let goalLine { Text(goalLine).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 4) {
                row("Focus rate", "\(summary.focusPercent)%")
                row("Sessions", "\(summary.sessions)")
                if summary.bestStretch >= 60 { row("Best stretch", "\(Int(summary.bestStretch / 60)) min") }
            }
        }
        .padding(16)
    }

    private var heading: String {
        switch summary.period {
        case .today:     return "Today, so far"
        case .yesterday: return "Yesterday"
        case .thisWeek:  return "This week, so far"
        }
    }

    private var goalLine: String? {
        guard showsGoal else { return nil }
        let left = goal - summary.focused
        let goalText = FocusNumbers.duration(goal)
        if left <= 0 { return "\(goalText) goal reached" }
        return summary.period == .today
            ? "\(FocusNumbers.duration(left)) to your \(goalText) goal"
            : "\(FocusNumbers.duration(left)) short of the \(goalText) goal"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
        .font(.caption)
        .frame(width: 140)
    }
}
