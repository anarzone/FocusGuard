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

    var headline: String { String(localized: "Let's get back to \(sessionLabel).") }

    var subtitle: String {
        if preset.overridePolicy.allowsPass {
            guard let endsAt else { return String(localized: "\(place) will still be there when the session ends.") }
            return String(localized: "\(place) will still be there when the session ends at \(MomentText.time(endsAt)).")
        }
        guard let endsAt else {
            return String(localized: "\(preset.title) is on, so there are no passes this session. \(place) is back when it ends.")
        }
        return String(localized: "\(preset.title) is on, so there are no passes this session. \(place) is back at \(MomentText.time(endsAt)).")
    }

    var footer: String {
        if preset.overridePolicy.locksDuringSession {
            return String(localized: "\(preset.title) · presets can change between sessions, not during one")
        }
        if tabPaused {
            guard let endsAt else { return String(localized: "\(preset.title) · the \(place) tab stays paused until the session ends") }
            return String(localized: "\(preset.title) · the \(place) tab stays paused until \(MomentText.time(endsAt))")
        }
        let minutes = Int((preset.overridePolicy.passSeconds / 60).rounded())
        return String(localized: "\(preset.title) · a pass lasts \(minutes) minutes and counts as drift", comment: "Plural on minutes: 1 minute / 2 minutes")
    }

    /// "Drifted 1:42", or "Drifted just now" for the first few seconds.
    static func away(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds >= 10 else { return String(localized: "Drifted just now") }
        let s = Int(seconds)
        let time = "\(s / 60):\(String(format: "%02d", s % 60))"
        return String(localized: "Drifted \(time)", comment: "Minutes and seconds since the drift began: Drifted 1:42")
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
        let copy = BlockCopy(place: place, preset: preset,
                             sessionLabel: context?.sessionLabel
                                ?? String(localized: "your session", comment: "Stands in for a session's name: Let's get back to your session."),
                             endsAt: context?.endsAt, tabPaused: message.host != nil && message.isTabPaused())
        let backApp = message.backToAppName()
        let back = backApp.map { String(localized: "Back to \($0)") } ?? String(localized: "Back to work")
        let backHint = backApp.map { String(localized: "back to \($0)", comment: "Beside the esc key") }
            ?? String(localized: "back to work", comment: "Beside the esc key")
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
                        Text("You were \(Int(context.zoneBefore / 60)) minutes in the zone before this. Pick it back up.", comment: "Plural on minutes: 1 minute / 2 minutes")
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
                    MomentKeyHint(key: String(localized: "esc", comment: "Name of the Escape key"), text: backHint)
                    if policy.allowsPass {
                        MomentKeyHint(key: String(localized: "return", comment: "Name of the Return key"),
                                      text: passLeft == 0 || policy.passWaitSeconds == 0
                                ? String(localized: "let me through, for \(passMinutes) minutes", comment: "Plural on minutes: 1 minute / 2 minutes")
                                : String(localized: "let me through, in \(passLeft) s", comment: "Seconds until the button opens"))
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

    private var passMinutes: Int {
        Int((policy.passSeconds / 60).rounded())
    }

    private func ring(_ context: BlockContext) -> some View {
        let m = context.timeline.minutesPerCell
        let done = (context.timeline.focusCells + context.timeline.driftCells + context.timeline.otherCells) * m
        let left = context.timeLeft
        var remaining = ""
        if let left {
            let time = MomentText.clock(left)
            remaining = context.endsAt.map { String(localized: "\(time) left, ends at \(MomentText.time($0)).") }
                ?? String(localized: "\(time) left.")
        }
        let label = [
            String(localized: "Session ring: \(done) minutes in."),
            String(localized: "\(context.timeline.focusCells * m) focused, \(context.timeline.driftCells * m) drifted, \(context.timeline.otherCells * m) other.",
                   comment: "Minutes in each state of a session"),
            remaining,
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
                Text(left == nil ? String(localized: "into this session", comment: "Under a clock counting up")
                     : context.endsAt.map { String(localized: "left · ends \(MomentText.time($0))", comment: "Under a countdown clock") }
                        ?? String(localized: "left", comment: "Under a countdown clock: the time remaining"))
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

            MomentWaitingButton(title: String(localized: "It's for work"), secondsLeft: forWorkLeft, wait: policy.forWorkWaitSeconds,
                          waiting: .quiet, open: .quiet, action: message.onAllowForSession)
                .help("Stop nudging about \(place) until this session ends.")

            if policy.allowsPass {
                MomentWaitingButton(title: String(localized: "Let me through"), secondsLeft: passLeft, wait: policy.passWaitSeconds,
                              action: message.onOverride)
                    .keyboardShortcut(.defaultAction)
                    .help(Text("Opens \(place) for \(passMinutes) minutes. The time counts as drift.", comment: "Plural on minutes: 1 minute / 2 minutes"))
            } else if inSession {
                Button("End the session early…") { confirmingEnd.toggle() }
                    .buttonStyle(MomentButtonStyle(kind: .link))
                    .accessibilityHint("Asks before ending the session")
            }
        }
    }

    /// "End Evening focus now?", in place under the buttons.
    private func endConfirm(_ context: BlockContext) -> some View {
        let minutes = max(1, Int(context.elapsed / 60))
        let detail = policy.forWorkWaitSeconds > 0
            ? String(localized: "It's saved as \(minutes) minutes. \(preset.title) has no passes. “It's for work” opens after \(policy.forWorkWaitSeconds) seconds, for sites that really are work.",
                     comment: "Plural on minutes: 1 minute / 2 minutes")
            : String(localized: "It's saved as \(minutes) minutes. \(preset.title) has no passes.", comment: "Plural on minutes: 1 minute / 2 minutes")
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("End \(context.sessionLabel) now?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(detail)
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
