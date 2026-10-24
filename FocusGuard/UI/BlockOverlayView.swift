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

/// The block screen's words, from the preset and the session.
struct BlockCopy: Equatable {
    /// "x.com", or the app's name.
    let place: String
    let preset: DriftResponse
    let sessionLabel: String
    let endsAt: Date?
    /// The site's tab behind the screen is paused.
    let tabPaused: Bool

    var headline: String { "Let's get back to \(sessionLabel)." }

    var subtitle: String {
        if preset.overridePolicy.allowsPass {
            guard let endsAt else { return "\(place) will still be there when the session ends." }
            return "\(place) will still be there when the session ends at \(MomentText.time(endsAt))."
        }
        let back = endsAt.map { "\(place) is back at \(MomentText.time($0))." } ?? "\(place) is back when it ends."
        return "\(preset.title) is on, so there are no passes this session. \(back)"
    }

    var footer: String {
        if preset.overridePolicy.locksDuringSession {
            return "\(preset.title) · presets can change between sessions, not during one"
        }
        if tabPaused {
            let until = endsAt.map { "until \(MomentText.time($0))" } ?? "until the session ends"
            return "\(preset.title) · the \(place) tab stays paused \(until)"
        }
        let pass = MomentText.counted(Int((preset.overridePolicy.passSeconds / 60).rounded()), "minute")
        return "\(preset.title) · a pass lasts \(pass) and counts as drift"
    }

    /// "Drifted 1:42", or "Drifted just now" for the first few seconds.
    static func away(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds >= 10 else { return "Drifted just now" }
        let s = Int(seconds)
        return "Drifted \(s / 60):\(String(format: "%02d", s % 60))"
    }
}

/// Full-screen pause when a drift outlasts the preset's threshold. It shows
/// what you drifted to, the live session ring (the drift in orange), and the
/// ways out the preset allows (`OverridePolicy`):
/// - Gentle: "Let me through" right away.
/// - Standard: "Let me through" after a 5 s countdown on the button.
/// - Strict: no pass; "It's for work" opens after 10 s, and the session can
///   be ended early after an inline confirm.
/// Every pass lasts 2 minutes and counts as drift. A footer names the preset.
struct BlockOverlayView: View {
    let message: OverlayMessage
    let policy: OverridePolicy
    @State private var confirmingEnd = false
    @ReduceMotion private var reduceMotion

    private var preset: DriftResponse { MomentText.preset(for: policy) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            content(context: message.context(), now: timeline.date)
        }
    }

    private func content(context: BlockContext?, now: Date) -> some View {
        let place = message.host ?? message.appName
        let copy = BlockCopy(place: place, preset: preset, sessionLabel: context?.sessionLabel ?? "your session",
                             endsAt: context?.endsAt, tabPaused: message.host != nil && message.isTabPaused())
        let back = message.backToAppName().map { "Back to \($0)" } ?? "Back to work"
        let passLeft = MomentText.secondsLeft(wait: policy.passWaitSeconds, shownAt: message.shownAt, now: now)

        return ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                MomentPlacePill(request: message.request,
                          status: BlockCopy.away(context?.awaySince.map { now.timeIntervalSince($0) }))

                Text(copy.headline)
                    .font(.system(size: 44, weight: .bold))
                    .kerning(-0.9)
                    .foregroundStyle(Theme.primaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)

                Text(context == nil ? message.motivational : copy.subtitle)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .padding(.horizontal, 40)

                if let context {
                    ring(context)
                        .padding(.top, 30)
                    let m = context.timeline.minutesPerCell
                    MomentLegend(focused: context.timeline.focusCells * m,
                               drifted: context.timeline.driftCells * m,
                               other: context.timeline.otherCells * m)
                        .padding(.top, 16)
                    if context.zoneBefore >= 60 {
                        Text("You were \(MomentText.counted(Int(context.zoneBefore / 60), "minute")) in the zone before this. Pick it back up.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.top, 14)
                    }
                }

                actions(back: back, inSession: context != nil, now: now)
                    .padding(.top, 26)

                if confirmingEnd, let context {
                    endConfirm(context)
                        .padding(.top, 16)
                        .transition(Motion.transition(.opacity.combined(with: .move(edge: .top)), reduced: reduceMotion))
                }

                HStack(spacing: 22) {
                    MomentKeyHint(key: "esc", text: back.prefix(1).lowercased() + back.dropFirst())
                    if policy.allowsPass {
                        MomentKeyHint(key: "return", text: passLeft == 0 || policy.passWaitSeconds == 0
                                ? "let me through, for \(passLength)"
                                : "let me through, in \(passLeft) s")
                    }
                }
                .padding(.top, 22)
            }
            .frame(maxWidth: 860)
            .padding(.horizontal, 40)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            MomentFooter(systemImage: "shield", text: copy.footer)
                .padding(.bottom, 26)
        }
        .background(MomentPalette.veil.ignoresSafeArea())
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: confirmingEnd)
    }

    private var passLength: String {
        MomentText.counted(Int((policy.passSeconds / 60).rounded()), "minute")
    }

    private func ring(_ context: BlockContext) -> some View {
        let m = context.timeline.minutesPerCell
        let done = (context.timeline.focusCells + context.timeline.driftCells + context.timeline.otherCells) * m
        let left = context.timeLeft
        let label = [
            "Session ring: \(done) minutes in.",
            "\(context.timeline.focusCells * m) focused, \(context.timeline.driftCells * m) drifted, \(context.timeline.otherCells * m) other.",
            left.map { "\(MomentText.clock($0)) left" + (context.endsAt.map { ", ends at \(MomentText.time($0))." } ?? ".") } ?? "",
        ].joined(separator: " ")

        return MomentRing(timeline: context.timeline, progress: context.progress) {
            VStack(spacing: 2) {
                // Open-ended sessions have nothing to count down: show how
                // far in you are instead.
                Text(MomentText.clock(left ?? context.elapsed))
                    .font(.system(size: 48, weight: .semibold).monospacedDigit())
                    .kerning(-0.9)
                    .foregroundStyle(Theme.primaryText)
                    .contentTransition(.numericText(countsDown: left != nil))
                Text(left == nil ? "into this session" : context.endsAt.map { "left · ends \(MomentText.time($0))" } ?? "left")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private func actions(back: String, inSession: Bool, now: Date) -> some View {
        let forWorkLeft = MomentText.secondsLeft(wait: policy.forWorkWaitSeconds, shownAt: message.shownAt, now: now)
        let passLeft = MomentText.secondsLeft(wait: policy.passWaitSeconds, shownAt: message.shownAt, now: now)
        let place = message.host ?? message.appName

        return HStack(spacing: 12) {
            Button(action: message.onBackToWork) {
                Label(back, systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(MomentButtonStyle(kind: .primary))
            .keyboardShortcut(.cancelAction)

            MomentWaitingButton(title: "It's for work", secondsLeft: forWorkLeft, wait: policy.forWorkWaitSeconds,
                          waiting: .quiet, open: .quiet, action: message.onAllowForSession)
                .help("Stop nudging about \(place) until this session ends.")

            if policy.allowsPass {
                MomentWaitingButton(title: "Let me through", secondsLeft: passLeft, wait: policy.passWaitSeconds,
                              action: message.onOverride)
                    .keyboardShortcut(.defaultAction)
                    .help("Opens \(place) for \(passLength). The time counts as drift.")
            } else if inSession {
                Button("End the session early…") { confirmingEnd.toggle() }
                    .buttonStyle(MomentButtonStyle(kind: .link))
                    .accessibilityHint("Asks before ending the session")
            }
        }
    }

    /// "End Evening focus now?", in place under the buttons.
    private func endConfirm(_ context: BlockContext) -> some View {
        let minutes = MomentText.counted(max(1, Int(context.elapsed / 60)), "minute")
        let forWork = policy.forWorkWaitSeconds > 0
            ? " “It's for work” opens after \(policy.forWorkWaitSeconds) seconds, for sites that really are work." : ""
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("End \(context.sessionLabel) now?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("It's saved as \(minutes). \(preset.title) has no passes.\(forWork)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("End the session", action: message.onEndSession)
                    .buttonStyle(MomentButtonStyle(kind: .destructive, height: 30))
                Button("Keep going") { confirmingEnd = false }
                    .buttonStyle(MomentButtonStyle(kind: .quiet, height: 30))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MomentPalette.quietFill))
    }
}
