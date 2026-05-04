import SwiftUI

/// Calm full-screen view shown when a break starts. The visual contract is
/// the opposite of the distraction block: soft gradient, friendly copy, no
/// gated countdown — Skip / +5 / Close are all available immediately.
struct BreakOverlayView: View {
    let breakManager: BreakManager
    var onSkip: () -> Void
    var onExtend: (Int) -> Void
    var onClose: () -> Void

    @AppStorage(SettingsKeys.Breaks.strictMode) private var strictMode = false

    /// Rotating wellness prompt — refreshed every ~20s.
    @State private var prompt: String = BreakOverlayView.prompts.randomElement()!
    @State private var promptTimer: Timer?
    @State private var nowTick: Date = .now

    private static let prompts: [String] = [
        "Stand up and stretch for 30 seconds.",
        "Look out the window — focus on something 20 feet away.",
        "Take 5 slow breaths.",
        "Drink some water.",
        "Roll your shoulders. Unclench your jaw.",
        "Walk to another room and back.",
        "Close your eyes. Just for a moment.",
        "Wiggle your fingers and toes.",
    ]

    var body: some View {
        ZStack {
            // Soft gradient backdrop — blue/green, very different from the
            // red/dark distraction block.
            LinearGradient(
                colors: [
                    Color(red: 86/255,  green: 165/255, blue: 199/255).opacity(0.92),
                    Color(red: 102/255, green: 187/255, blue: 158/255).opacity(0.92),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Text("Time to rest")
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(2)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.75))

                Text(remainingLabel)
                    .font(.system(size: 130, weight: .thin, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .kerning(-2)

                Text(prompt)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)

                Spacer()

                HStack(spacing: 14) {
                    Button { onExtend(5) } label: {
                        Label("+5 minutes", systemImage: "plus.circle")
                            .padding(.horizontal, 18).padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .background(Color.white.opacity(0.18), in: Capsule())
                    .foregroundStyle(.white)

                    if !strictMode {
                        Button { onSkip() } label: {
                            Label("Skip break", systemImage: "forward.fill")
                                .padding(.horizontal, 18).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .background(Color.white.opacity(0.18), in: Capsule())
                        .foregroundStyle(.white)

                        Button { onClose() } label: {
                            Label("Hide", systemImage: "eye.slash")
                                .padding(.horizontal, 18).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .background(Color.white.opacity(0.18), in: Capsule())
                        .foregroundStyle(.white)
                    } else {
                        Text("Strict mode is on — break runs to completion.")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .padding(.bottom, 60)
            }
        }
        .onAppear {
            startPromptRotation()
        }
        .onDisappear {
            promptTimer?.invalidate()
            promptTimer = nil
        }
        .task {
            // Drive the countdown — observe BreakManager.current via a 1Hz
            // tick. Cheap; the view is on screen for at most a few minutes.
            while !Task.isCancelled {
                nowTick = .now
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private var remainingLabel: String {
        guard let state = breakManager.current else { return "0:00" }
        let remaining = Int(state.remaining(now: nowTick))
        let m = remaining / 60
        let s = remaining % 60
        return String(format: "%d:%02d", m, s)
    }

    private func startPromptRotation() {
        promptTimer?.invalidate()
        promptTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in
                prompt = BreakOverlayView.prompts.randomElement() ?? prompt
            }
        }
    }
}
