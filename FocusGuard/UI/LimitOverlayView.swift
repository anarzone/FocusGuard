import SwiftUI

/// The daily-limit screen's words, from the preset and today's numbers.
struct LimitCopy: Equatable {
    /// "youtube.com", or the app's name.
    let name: String
    let preset: DriftResponse
    /// The limit itself, before extra time.
    let minutesADay: Int
    let extraTime: OverridePolicy.ExtraTime
    /// Extra-time grants left today.
    let extraLeft: Int
    /// When it opens again: the start of tomorrow.
    let reopensAt: Date

    var headline: String { "That's your \(name) time for today." }

    private var reopens: String { "It opens again tomorrow at \(MomentText.time(reopensAt))." }

    var subtitle: String {
        if !extraTime.isOffered { return "\(preset.title) is on, so there's no extra time. \(reopens)" }
        if extraLeft == 0 { return "You've had today's extra time. \(reopens)" }
        return "\(reopens) Everything else works as usual."
    }

    var offersExtraTime: Bool { extraTime.isOffered && extraLeft > 0 }

    /// What extra time this preset gives, under the buttons.
    var note: String? {
        if !extraTime.isOffered {
            return preset.overridePolicy.limitChangesWaitForTomorrow
                ? "Want a different limit? In \(preset.title) you can change it for tomorrow." : nil
        }
        guard extraLeft > 0 else { return nil }
        let wait = extraTime.waitSeconds > 0 ? ", after a \(extraTime.waitSeconds)-second wait" : ""
        if extraTime.timesPerDay == 1 {
            return "\(preset.title) gives one extra \(extraTime.minutes) minutes a day\(wait)."
        }
        return "\(preset.title) gives an extra \(extraTime.minutes) minutes up to \(extraTime.timesPerDay) times a day\(wait). "
            + "\(extraLeft) left today."
    }

    var footer: String {
        "\(preset.title) · \(name), \(MomentText.counted(minutesADay, "minute")) a day · resets at \(MomentText.time(reopensAt)) ·"
    }

    var editLink: String { preset.overridePolicy.limitChangesWaitForTomorrow ? "Change for tomorrow" : "Edit limit" }
}

/// Full-screen pause when a daily limit runs out, in sessions and out. The
/// limit ring is full; the ways out are leaving, starting a session (when
/// none is running) and, while the preset allows it, a few more minutes
/// (`OverridePolicy.ExtraTime`). Limits reset at 00:00.
struct LimitOverlayView: View {
    let message: OverlayMessage
    let limit: LimitBlock

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            content(now: timeline.date)
        }
    }

    private func content(now: Date) -> some View {
        let status = message.limitStatus()
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        // The preset whose extra time this block carries; they're all different.
        let preset = DriftResponse.allCases.first { $0.overridePolicy.extraTime == limit.extraTime } ?? .effective
        let copy = LimitCopy(name: limit.name, preset: preset,
                             minutesADay: status?.minutes ?? limit.minutesToday,
                             extraTime: limit.extraTime, extraLeft: limit.extraLeft, reopensAt: tomorrow)
        let extraLeft = MomentText.secondsLeft(wait: limit.extraTime.waitSeconds, shownAt: message.shownAt, now: now)
        let sessionMinutes = message.sessionMinutes()

        return ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                limitRing(used: status?.used)

                MomentPlacePill(request: message.request, status: "Daily limit reached")
                    .padding(.top, 26)

                Text(copy.headline)
                    .font(.system(size: 40, weight: .bold))
                    .kerning(-0.8)
                    .foregroundStyle(Theme.primaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)

                Text(copy.subtitle)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .padding(.horizontal, 40)

                HStack(spacing: 12) {
                    Button(message.host.map { "Close \($0)" } ?? message.backToAppName().map { "Back to \($0)" } ?? "Back to work",
                           action: message.onBackToWork)
                        .buttonStyle(MomentButtonStyle(kind: .primary))
                        .keyboardShortcut(.cancelAction)

                    if message.canStartSession() {
                        Button { message.onStartFocus(sessionMinutes) } label: {
                            Label {
                                Text("Start \(sessionMinutes) minutes of focus")
                            } icon: {
                                Image(systemName: "shield").foregroundStyle(Theme.focus)
                            }
                        }
                        .buttonStyle(MomentButtonStyle(kind: .quiet))
                    }

                    if copy.offersExtraTime {
                        MomentWaitingButton(title: "\(limit.extraTime.minutes) more minutes", secondsLeft: extraLeft,
                                      wait: limit.extraTime.waitSeconds, action: message.onExtraTime)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.top, 34)

                if let note = copy.note {
                    Text(note)
                        .font(.system(size: 13))
                        .foregroundStyle(MomentPalette.tertiaryText)
                        .multilineTextAlignment(.center)
                        .padding(.top, 14)
                }
            }
            .frame(maxWidth: 860)
            .padding(.horizontal, 40)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            MomentFooter(systemImage: "clock", iconColor: Theme.secondaryText, text: copy.footer,
                         link: (copy.editLink, message.onEditLimits))
                .padding(.bottom, 26)
        }
        .background(MomentPalette.veil.ignoresSafeArea())
    }

    /// The limit's ring, full once it has run out.
    private func limitRing(used: TimeInterval?) -> some View {
        let allowance = Double(max(1, limit.minutesToday)) * 60
        let share = min(1, (used ?? allowance) / allowance)
        return ZStack {
            Circle().stroke(MomentPalette.ringTrack, lineWidth: 12)
            Circle().trim(from: 0, to: share)
                .stroke(Theme.distraction, style: StrokeStyle(lineWidth: 12, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text("\(limit.minutesToday) min")
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    .kerning(-0.7)
                    .foregroundStyle(Theme.primaryText)
                Text("of \(limit.minutesToday) used today")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(12)
        .frame(width: 168, height: 168)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily limit used: \(limit.minutesToday) of \(limit.minutesToday) minutes on \(limit.name)")
    }
}
