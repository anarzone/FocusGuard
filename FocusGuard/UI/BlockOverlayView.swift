import SwiftUI

/// Live session details for the block screen, read once a second while it's up.
struct BlockContext {
    let sessionLabel: String
    let timeline: SessionTimeline
    let progress: Double
    /// Time spent in the session so far, pauses left out.
    let elapsed: TimeInterval
    /// Nil for open-ended sessions.
    let timeLeft: TimeInterval?
    let endsAt: Date?
    /// When the current drift started.
    let awaySince: Date?
    /// Length of the focus run the drift interrupted.
    let zoneBefore: TimeInterval
    /// Name of the app "Back to …" returns to, if known.
    let backToAppName: String?
}

/// Full-screen pause when a drift outlasts the block threshold. Shows what
/// you drifted to, the live session ring (with the drift in orange), and
/// three ways out: back to work (default), "it's for work", or — after a
/// short countdown — a 2-minute pass.
struct BlockOverlayView: View {
    let message: OverlayMessage
    @State private var countdown: Int

    init(message: OverlayMessage) {
        self.message = message
        self._countdown = State(initialValue: message.overrideSeconds)
    }

    private var canOverride: Bool { countdown <= 0 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            content(context: message.context(), now: timeline.date)
        }
        .preferredColorScheme(.dark)
        .task {
            while countdown > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                countdown -= 1
            }
        }
    }

    private func content(context: BlockContext?, now: Date) -> some View {
        let label = context?.sessionLabel ?? "your session"
        let place = message.host ?? message.appName

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                AppGlyph(kind: message.host == nil ? AppGlyph.kind(forBundleId: message.bundleId, name: message.appName) : .generic,
                         bundleId: message.host == nil ? message.bundleId : nil, host: message.host, size: 26)
                Text(place).font(.system(size: 14, weight: .semibold))
                if let since = context?.awaySince {
                    Text("· \(Self.clock(now.timeIntervalSince(since))) away from \(label)")
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.distraction.opacity(0.16)))
            .overlay(Capsule().strokeBorder(Theme.distraction.opacity(0.5), lineWidth: 0.5))

            Text("Let's get back to \(label).")
                .font(.system(size: 44, weight: .bold))
                .kerning(-0.8)
                .multilineTextAlignment(.center)
                .padding(.top, 26)

            Text(subtitle(context: context, place: place))
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .padding(.horizontal, 40)

            if let context {
                SessionRingView(timeline: context.timeline, progress: context.progress, size: 236, lineWidth: 15) {
                    VStack(spacing: 2) {
                        // Open-ended sessions have nothing to count down: show
                        // how far in you are instead.
                        Text(SessionClock.format(context.timeLeft ?? context.elapsed))
                            .font(.system(size: 48, weight: .semibold).monospacedDigit())
                            .contentTransition(.numericText(countsDown: context.timeLeft != nil))
                        Text(context.timeLeft == nil ? "into this session" : "left in this session")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(.top, 34)

                if context.zoneBefore >= 60 {
                    Text("You were \(counted(Int(context.zoneBefore / 60), "minute")) in the zone before this. Pick it back up.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.62))
                        .padding(.top, 18)
                }
            }

            actions(backTo: context?.backToAppName)
                .padding(.top, 30)

            HStack(spacing: 22) {
                hint("esc", "back to work")
                hint("return", canOverride ? "let me through, for 2 minutes" : "let me through, in \(countdown) s")
            }
            .padding(.top, 26)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 820)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 14/255, green: 14/255, blue: 22/255).opacity(0.55))
    }

    private func subtitle(context: BlockContext?, place: String) -> String {
        if let ends = context?.endsAt {
            return "\(place) will still be there when your session ends at \(ends.formatted(date: .omitted, time: .shortened))."
        }
        return message.motivational
    }

    private func actions(backTo appName: String?) -> some View {
        HStack(spacing: 12) {
            Button(action: message.onBackToWork) {
                Text(appName.map { "Back to \($0)" } ?? "Back to work")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 26)
                    .frame(height: 44)
                    .background(Capsule().fill(Theme.focusFill))
                    .shadow(color: Theme.focusFill.opacity(0.35), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Button(action: message.onAllowForSession) {
                Text("It's for work")
                    .font(.system(size: 15))
                    .padding(.horizontal, 22)
                    .frame(height: 44)
                    .background(Capsule().fill(.white.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("Stop nudging about \(message.host ?? message.appName) until this session ends.")

            Button {
                if canOverride { message.onOverride() }
            } label: {
                HStack(spacing: 8) {
                    if !canOverride {
                        ZStack {
                            Circle().stroke(.white.opacity(0.18), lineWidth: 2)
                            Circle().trim(from: 0, to: CGFloat(countdown) / CGFloat(max(1, message.overrideSeconds)))
                                .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(countdown)").font(.system(size: 9, weight: .semibold).monospacedDigit())
                        }
                        .frame(width: 20, height: 20)
                    }
                    Text("Let me through")
                }
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(canOverride ? 0.9 : 0.5))
                .padding(.horizontal, 20)
                .frame(height: 44)
            }
            .buttonStyle(.plain)
            .disabled(!canOverride)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(canOverride ? "Let me through for 2 minutes" : "Let me through, available in \(counted(countdown, "second"))")
        }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.1)))
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.45))
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}
