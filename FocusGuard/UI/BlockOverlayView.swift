import SwiftUI

struct BlockOverlayView: View {
    let message: OverlayMessage

    @State private var countdown: Int
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(message: OverlayMessage) {
        self.message = message
        self._countdown = State(initialValue: message.overrideSeconds)
    }

    private var canOverride: Bool { countdown <= 0 }

    var body: some View {
        ZStack {
            // Dark calm backdrop. Not pure-black so it feels like macOS, not a TV off.
            Color.black.opacity(0.78)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                // Stop sign / shield mark
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        .frame(width: 120, height: 120)
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 12) {
                    Text(message.motivational)
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .lineLimit(3)

                    Text(detailLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                }

                actions
                    .padding(.top, 10)
            }
            .frame(maxWidth: 720)
            .padding(40)
        }
        .preferredColorScheme(.dark)
        .onReceive(ticker) { _ in
            if countdown > 0 {
                countdown -= 1
                if countdown <= 0 { ticker.upstream.connect().cancel() }
            }
        }
    }

    private var detailLine: String {
        if let host = message.host {
            return "Blocking \(host) (\(message.appName)) so you can refocus."
        }
        return "Blocking \(message.appName) so you can refocus."
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                message.onPostpone()
            } label: {
                Text("Refocus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 180, height: 40)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.escape, modifiers: [])    // Esc → Refocus

            Button {
                if canOverride { message.onOverride() }
            } label: {
                HStack(spacing: 6) {
                    if !canOverride {
                        ZStack {
                            Circle()
                                .stroke(Color.white.opacity(0.25), lineWidth: 1.5)
                                .frame(width: 18, height: 18)
                            Text("\(countdown)")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    Text(canOverride ? "Let me through" : "Wait \(countdown)s…")
                        .font(.system(size: 14))
                }
                .frame(width: 180, height: 40)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.white)
            .disabled(!canOverride)
            .opacity(canOverride ? 1 : 0.6)
            .keyboardShortcut(.return, modifiers: [])    // Return → Let me through
        }
    }
}
