import SwiftUI

// MARK: - Length

/// The length of the next session: the big number and when it would end,
/// over the shipped ruler.
struct LengthModule: View {
    @Binding var minutes: Int
    let now: Date

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(big)
                        .font(.system(size: 30, weight: .semibold).monospacedDigit())
                        .kerning(-0.9)
                        .contentTransition(.numericText(value: Double(minutes)))
                        .animation(.snappy(duration: 0.2), value: minutes)
                    Text(minutes < 120 ? "min" : "hours")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 4)
                Text("ends \(menuClock(now.addingTimeInterval(TimeInterval(minutes * 60))))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 2)
            .accessibilityElement(children: .combine)

            LengthRuler(minutes: $minutes)
        }
        .menuModule(padding: EdgeInsets(top: 10, leading: 12, bottom: 4, trailing: 12))
    }

    /// "50", or "2:30" from two hours.
    private var big: String {
        minutes < 120 ? "\(minutes)" : String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

/// A plain row that opens something: "Pick a length and start fresh ›".
struct MenuLinkRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .contentShape(Rectangle())
            .menuModule(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Drift

/// On a distracting app or site in a session: how long, when the tab
/// pauses (or the screen blocks), and the way back.
struct DriftModule: View {
    let drift: DriftInfo
    let now: Date
    let policy: OverridePolicy
    /// "Xcode", for "Back to Xcode".
    let backTo: String?
    let onBack: () -> Void
    let onForWork: () -> Void

    var body: some View {
        let away = max(0, Int(now.timeIntervalSince(drift.since)))
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                AppGlyph(
                    kind: AppGlyph.kind(forBundleId: drift.snapshot.bundleIdentifier, name: drift.snapshot.appName),
                    bundleId: host == nil ? drift.snapshot.bundleIdentifier : nil,
                    host: host,
                    size: 30
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(drift.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("You've been here \(away / 60):\(String(format: "%02d", away % 60))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.primaryText.opacity(0.8))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 7) {
                    if let fraction = countdown {
                        DriftCountdownRing(fraction: fraction)
                    }
                    Text(caption)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.primaryText.opacity(0.8))
                        .multilineTextAlignment(.trailing)
                        .fixedSize()
                }
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 6) {
                CapsuleButton(title: backTo.map { "Back to \($0)" } ?? "Back to work", prominent: true,
                              height: 30, action: onBack)
                CapsuleButton(title: forWorkTitle(away: away), prominent: false, height: 30,
                              fill: MenuPalette.onTint, action: onForWork)
                    .disabled(forWorkWait(away: away) > 0)
                    .help("Stop nudging about \(drift.displayName) until this session ends.")
            }
        }
        .menuModule(tint: Theme.distraction, padding: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
    }

    private var host: String? {
        guard drift.snapshot.url != nil, drift.displayName != drift.snapshot.appName else { return nil }
        return drift.displayName
    }

    /// How much of the run-up to the pause (or block) has gone, 0...1.
    private var countdown: Double? {
        guard let blocksAt = drift.blocksAt, blocksAt > now else { return nil }
        let total = blocksAt.timeIntervalSince(drift.since)
        guard total > 0 else { return nil }
        return min(1, max(0, now.timeIntervalSince(drift.since) / total))
    }

    private var caption: String {
        let noun = drift.pausesTab ? "Tab" : "Screen"
        if let blocksAt = drift.blocksAt {
            let left = Int(blocksAt.timeIntervalSince(now).rounded(.up))
            if left > 0 { return "\(drift.pausesTab ? "Tab pauses" : "Screen blocks")\nin \(left) s" }
        }
        return "\(noun)\n\(drift.pausesTab ? "paused" : "blocked")"
    }

    /// Strict holds "It's for work" back for a few seconds.
    private func forWorkWait(away: Int) -> Int {
        max(0, policy.forWorkWaitSeconds - away)
    }

    private func forWorkTitle(away: Int) -> String {
        let wait = forWorkWait(away: away)
        return wait > 0 ? "It's for work · \(wait) s" : "It's for work"
    }
}

/// A small ring that fills as a countdown runs.
struct DriftCountdownRing: View {
    let fraction: Double
    var size: CGFloat = 22
    var color: Color = Theme.distraction

    var body: some View {
        ZStack {
            Circle().stroke(Theme.control, lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(fraction))
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1.5)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Daily limit

/// A site or app with a daily limit, while it's in front: how much is left,
/// or, once it has run out, that it's done until midnight and what the
/// preset allows.
struct LimitModule: View {
    let status: LimitStatus
    let policy: OverridePolicy
    /// The site's tab is paused rather than the screen blocked.
    let pausesTab: Bool
    let now: Date
    let onExtraTime: () -> Void
    let onChange: () -> Void

    /// "5 more min" waits this long after the module appears, on presets that wait.
    @State private var extraReadyAt: Date?

    var body: some View {
        if status.isUsedUp {
            reached
        } else {
            progress
        }
    }

    // In progress

    private var progress: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                glyph
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("Daily limit · \(status.minutes) min")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.primaryText.opacity(0.8))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(usedMinutes)")
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        .kerning(-0.4)
                    Text("of \(allowanceMinutes) min")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                .fixedSize()
            }
            LimitBar(fraction: status.allowance > 0 ? status.used / status.allowance : 1)
            Text(progressLine)
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .menuModule(raised: true, padding: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        .accessibilityElement(children: .combine)
    }

    private var progressLine: String {
        let left = AppState.minutesRoundedUp(status.remaining)
        if status.extraMinutes > 0 {
            let until = menuClock(now.addingTimeInterval(status.remaining))
            return status.extraLeft == 0 ? "Open until \(until). That was today's extra time." : "Open until \(until)."
        }
        let after = pausesTab ? "the tab pauses" : "it's blocked"
        return "\(counted(left, "min", plural: "min")) left today. After that \(after) until \(menuClock(midnight))."
    }

    // Reached

    private var reached: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                glyph
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(status.name) is done for today")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(usedMinutes) of \(allowanceMinutes) min · back at \(menuClock(midnight))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.primaryText.opacity(0.8))
                        .lineLimit(1)
                }
            }
            LimitBar(fraction: 1)
            Text(pausesTab ? "The tab is paused. Everything else works as usual."
                           : "It's blocked until \(menuClock(midnight)). Everything else works as usual.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if offersExtra {
                    let wait = extraWait
                    CapsuleButton(title: wait > 0 ? "\(policy.extraTime.minutes) more min · \(wait) s"
                                                  : "\(policy.extraTime.minutes) more min",
                                  prominent: false, height: 30, fill: MenuPalette.onTint, semibold: wait == 0,
                                  action: onExtraTime)
                        .disabled(wait > 0)
                }
                CapsuleButton(title: "Change limit", prominent: false, height: 30, fill: MenuPalette.onTint,
                              action: onChange)
            }
            Text(rulesLine)
                .font(.system(size: 11))
                .foregroundStyle(Theme.primaryText.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .menuModule(tint: Theme.distraction, padding: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        .onAppear {
            if extraReadyAt == nil {
                extraReadyAt = now.addingTimeInterval(TimeInterval(policy.extraTime.waitSeconds))
            }
        }
    }

    private var offersExtra: Bool { policy.extraTime.isOffered && status.extraLeft > 0 }

    private var extraWait: Int {
        guard let extraReadyAt else { return policy.extraTime.waitSeconds }
        return max(0, Int(extraReadyAt.timeIntervalSince(now).rounded(.up)))
    }

    /// What the preset allows, in one line.
    private var rulesLine: String {
        let extra = policy.extraTime
        guard extra.isOffered else { return "Strict: no extra time. Changes to the limit start tomorrow." }
        if status.extraLeft == 0 { return "That was today's extra time." }
        if extra.timesPerDay == 1 {
            let wait = extra.waitSeconds > 0 ? ", after a \(extra.waitSeconds)-second wait" : ""
            return "\(extra.minutes) more minutes once a day\(wait)."
        }
        return "\(extra.minutes) more minutes, up to \(extra.timesPerDay) times a day · \(status.extraLeft) left today."
    }

    private var glyph: some View {
        AppGlyph(kind: status.isSite ? .generic : AppGlyph.kind(forBundleId: status.target, name: status.name),
                 bundleId: status.isSite ? nil : status.target,
                 host: status.isSite ? status.target : nil,
                 size: 30)
    }

    private var usedMinutes: Int { min(allowanceMinutes, Int(status.used / 60)) }
    private var allowanceMinutes: Int { status.minutes + status.extraMinutes }

    private var midnight: Date {
        Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 60 * 60)
    }
}

/// Time used against a limit: orange on a grey track.
struct LimitBar: View {
    let fraction: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.control)
                Capsule().fill(Theme.distraction)
                    .frame(width: max(height, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Auto-start offer

/// "12 minutes in Xcode and Terminal. Make it a session?"
struct AutoStartModule: View {
    let offer: AutoStartOffer
    let minutes: Int
    let now: Date
    let onStart: () -> Void
    let onNotNow: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                AppGlyph(kind: offer.bundleId.map { AppGlyph.kind(forBundleId: $0, name: offer.appNames.first) } ?? .generic,
                         bundleId: offer.bundleId, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(counted(offer.focusMinutes(now: now), "minute")) in \(offer.appList)")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Looks like focus. Make it a session?")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.primaryText.opacity(0.8))
                }
            }
            .accessibilityElement(children: .combine)

            VStack(spacing: 6) {
                CapsuleButton(title: "Start \(minutes) min, counting these \(offer.focusMinutes(now: now))", prominent: true,
                              height: 32, action: onStart)
                HStack(spacing: 6) {
                    CapsuleButton(title: "Not now", prominent: false, height: 28, fill: MenuPalette.onTint, action: onNotNow)
                    CapsuleButton(title: "Stop offering", prominent: false, height: 28, fill: MenuPalette.onTint, action: onStop)
                        .help("You can turn offers back on in Settings")
                }
            }
        }
        .menuModule(tint: Theme.focus, padding: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
    }
}

// MARK: - Call

/// In a session during a call: nudges wait, and the time counts as other.
struct CallModule: View {
    let call: CallInfo
    let paused: Bool
    let onPause: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AppGlyph(kind: call.bundleId.map { AppGlyph.kind(forBundleId: $0, name: call.appName) } ?? .generic,
                         bundleId: call.bundleId, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("On a call · \(call.appName)")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("Since \(menuClock(call.since)) · no nudges until it ends")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.primaryText.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.other).frame(width: 8, height: 8)
                    Text("Call time counts as other")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.primaryText.opacity(0.8))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if paused {
                    Text("Paused till it ends")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    PillButton(title: "Pause till it ends", action: onPause)
                }
            }
        }
        .menuModule(raised: true, padding: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
    }
}

// MARK: - Formatting

/// "19:42", in the user's clock style.
func menuClock(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
}
