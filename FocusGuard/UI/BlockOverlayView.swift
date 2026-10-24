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
}

/// Full-screen pause when a drift outlasts the block threshold, or a daily
/// limit runs out. A drift shows what you drifted to, the live session ring
/// (with the drift in orange), and up to three ways out: back to work
/// (default), "it's for work", or — if the preset allows it — a 2-minute
/// pass. Each waits as long as the preset says (`OverridePolicy`).
struct BlockOverlayView: View {
    let message: OverlayMessage
    /// Whole seconds since the screen came up; every button's wait counts from it.
    @State private var shownFor = 0

    private var policy: OverridePolicy? {
        if case .drift(let policy) = message.request.reason { return policy }
        return nil
    }

    private var limit: LimitBlock? {
        if case .dailyLimit(let limit) = message.request.reason { return limit }
        return nil
    }

    /// Seconds left before a button with this wait opens.
    private func left(_ wait: Int) -> Int { max(0, wait - shownFor) }

    private var longestWait: Int {
        if let policy { return max(policy.passWaitSeconds, policy.forWorkWaitSeconds) }
        return limit?.extraTime.waitSeconds ?? 0
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            if let limit {
                limitContent(limit)
            } else {
                content(context: message.context(), now: timeline.date)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            while shownFor < longestWait, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                shownFor += 1
            }
        }
    }

    private func content(context: BlockContext?, now: Date) -> some View {
        let label = context?.sessionLabel ?? "your session"
        let place = message.host ?? message.appName
        let policy = policy ?? .standard
        let passLeft = left(policy.passWaitSeconds)

        return VStack(spacing: 0) {
            placePill(place) {
                if let since = context?.awaySince {
                    Text("· \(Self.clock(now.timeIntervalSince(since))) away from \(label)")
                }
            }

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

            actions(policy: policy)
                .padding(.top, 30)

            HStack(spacing: 22) {
                hint("esc", "back to work")
                if policy.allowsPass {
                    hint("return", passLeft == 0 ? "let me through, for \(Self.minutes(policy.passSeconds))" : "let me through, in \(passLeft) s")
                }
            }
            .padding(.top, 26)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 820)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.backdrop)
    }

    /// A daily limit ran out: back to work, or a few more minutes while the preset allows it.
    private func limitContent(_ limit: LimitBlock) -> some View {
        let place = message.host ?? message.appName
        let extraLeft = left(limit.extraTime.waitSeconds)
        let offersExtra = limit.extraLeft > 0

        return VStack(spacing: 0) {
            placePill(place) {
                Text("· \(limit.minutesToday) of \(limit.minutesToday) min today")
            }

            Text("That's your \(limit.minutesToday) minutes on \(place) for today.")
                .font(.system(size: 44, weight: .bold))
                .kerning(-0.8)
                .multilineTextAlignment(.center)
                .padding(.top, 26)

            Text(limit.extraTime.isOffered
                 ? "It opens again at midnight."
                 : "It opens again at midnight. You can change the limit for tomorrow.")
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .padding(.horizontal, 40)

            HStack(spacing: 12) {
                backButton
                if offersExtra {
                    waitingButton("\(limit.extraTime.minutes) more minutes", secondsLeft: extraLeft,
                                  wait: limit.extraTime.waitSeconds, action: message.onExtraTime)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel(extraLeft == 0 ? "\(limit.extraTime.minutes) more minutes"
                                            : "\(limit.extraTime.minutes) more minutes, available in \(counted(extraLeft, "second"))")
                }
            }
            .padding(.top, 30)

            HStack(spacing: 22) {
                hint("esc", "back to work")
                if offersExtra {
                    hint("return", extraLeft == 0 ? "\(limit.extraTime.minutes) more minutes" : "\(limit.extraTime.minutes) more minutes, in \(extraLeft) s")
                }
            }
            .padding(.top, 26)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 820)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.backdrop)
    }

    private static let backdrop = Color(red: 14/255, green: 14/255, blue: 22/255).opacity(0.55)

    private func placePill<Detail: View>(_ place: String, @ViewBuilder detail: () -> Detail) -> some View {
        HStack(spacing: 10) {
            AppGlyph(kind: message.host == nil ? AppGlyph.kind(forBundleId: message.bundleId, name: message.appName) : .generic,
                     bundleId: message.host == nil ? message.bundleId : nil, host: message.host, size: 26)
            Text(place).font(.system(size: 14, weight: .semibold))
            detail()
                .font(.system(size: 14).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.distraction.opacity(0.16)))
        .overlay(Capsule().strokeBorder(Theme.distraction.opacity(0.5), lineWidth: 0.5))
    }

    private func subtitle(context: BlockContext?, place: String) -> String {
        if let ends = context?.endsAt {
            return "\(place) will still be there when your session ends at \(ends.formatted(date: .omitted, time: .shortened))."
        }
        return message.motivational
    }

    private var backButton: some View {
        Button(action: message.onBackToWork) {
            Text(message.backToAppName().map { "Back to \($0)" } ?? "Back to work")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 26)
                .frame(height: 44)
                .background(Capsule().fill(Theme.focusFill))
                .shadow(color: Theme.focusFill.opacity(0.35), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }

    private func actions(policy: OverridePolicy) -> some View {
        let forWorkLeft = left(policy.forWorkWaitSeconds)
        let passLeft = left(policy.passWaitSeconds)
        return HStack(spacing: 12) {
            backButton

            Button {
                if forWorkLeft == 0 { message.onAllowForSession() }
            } label: {
                HStack(spacing: 8) {
                    if forWorkLeft > 0 { CountdownRing(left: forWorkLeft, total: policy.forWorkWaitSeconds) }
                    Text("It's for work")
                }
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(forWorkLeft == 0 ? 1 : 0.5))
                .padding(.horizontal, 22)
                .frame(height: 44)
                .background(Capsule().fill(.white.opacity(0.12)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(forWorkLeft > 0)
            .help("Stop nudging about \(message.host ?? message.appName) until this session ends.")
            .accessibilityLabel(forWorkLeft == 0 ? "It's for work" : "It's for work, available in \(counted(forWorkLeft, "second"))")

            if policy.allowsPass {
                waitingButton("Let me through", secondsLeft: passLeft, wait: policy.passWaitSeconds, action: message.onOverride)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(passLeft == 0 ? "Let me through for \(Self.minutes(policy.passSeconds))"
                                        : "Let me through, available in \(counted(passLeft, "second"))")
            }
        }
    }

    /// A quiet button that opens after `wait` seconds, with a ring counting down.
    private func waitingButton(_ title: String, secondsLeft: Int, wait: Int, action: @escaping () -> Void) -> some View {
        Button {
            if secondsLeft == 0 { action() }
        } label: {
            HStack(spacing: 8) {
                if secondsLeft > 0 { CountdownRing(left: secondsLeft, total: wait) }
                Text(title)
            }
            .font(.system(size: 15))
            .foregroundStyle(.white.opacity(secondsLeft == 0 ? 0.9 : 0.5))
            .padding(.horizontal, 20)
            .frame(height: 44)
        }
        .buttonStyle(.plain)
        .disabled(secondsLeft > 0)
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

    /// "2 minutes" for a pass length.
    private static func minutes(_ seconds: TimeInterval) -> String {
        counted(Int((seconds / 60).rounded()), "minute")
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}

/// The small ring on a button that isn't open yet, with the seconds left.
private struct CountdownRing: View {
    let left: Int
    let total: Int

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 2)
            Circle().trim(from: 0, to: CGFloat(left) / CGFloat(max(1, total)))
                .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(left)").font(.system(size: 9, weight: .semibold).monospacedDigit())
        }
        .frame(width: 20, height: 20)
    }
}
