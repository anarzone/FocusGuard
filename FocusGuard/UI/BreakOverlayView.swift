import SwiftUI

/// Calm full-screen view shown when a break starts — the opposite of the
/// block screen: warm light, a breathing guide inside the time-left ring,
/// one small suggestion, and no gated buttons (Skip / +5 / Hide are all
/// available immediately, unless break strict mode is on).
struct BreakOverlayView: View {
    let breakManager: BreakManager
    var onSkip: () -> Void
    var onExtend: (Int) -> Void
    var onClose: () -> Void

    @AppStorage(SettingsKeys.Breaks.strictMode) private var strictMode = false
    @Environment(\.colorScheme) private var colorScheme
    @ReduceMotion private var reduceMotion

    private static let tips: [String] = [
        "Stand up and look at something 20 feet away.",
        "Drink some water.",
        "Roll your shoulders. Unclench your jaw.",
        "Walk to another room and back.",
        "Stretch your arms over your head for a few breaths.",
        "Close your eyes. Just for a moment.",
    ]

    /// One breath: 4 s in, 6 s out.
    private static let inhale: Double = 4
    private static let cycle: Double = 10

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let now = context.date
            ZStack {
                background
                VStack(spacing: 0) {
                    Text(headerLine(now: now))
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(2)
                        .textCase(.uppercase)
                        .foregroundStyle(ink.opacity(0.55))
                    Text("Nice work. Let your eyes rest.")
                        .font(.system(size: 40, weight: .bold))
                        .kerning(-0.8)
                        .foregroundStyle(ink)
                        .padding(.top, 10)

                    breathing(now: now)
                        .padding(.top, 30)

                    tipCard(now: now)
                        .padding(.top, 30)

                    controls
                        .padding(.top, 30)
                }
                .padding(40)
            }
        }
    }

    // MARK: - Pieces

    private var ink: Color {
        colorScheme == .dark ? Color(red: 245/255, green: 238/255, blue: 250/255) : Color(red: 43/255, green: 36/255, blue: 51/255)
    }

    private var background: some View {
        let colors: [Color] = colorScheme == .dark
            ? [Color(red: 58/255, green: 42/255, blue: 62/255), Color(red: 44/255, green: 38/255, blue: 70/255), Color(red: 30/255, green: 32/255, blue: 58/255)]
            : [Color(red: 247/255, green: 227/255, blue: 210/255), Color(red: 241/255, green: 212/255, blue: 214/255), Color(red: 220/255, green: 211/255, blue: 238/255)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }

    private func remaining(now: Date) -> TimeInterval {
        breakManager.current?.remaining(now: now) ?? 0
    }

    private func headerLine(now: Date) -> String {
        "Break · back at \(now.addingTimeInterval(remaining(now: now)).formatted(date: .omitted, time: .shortened))"
    }

    /// Breathing orb inside a thin ring that empties as the break runs out.
    private func breathing(now: Date) -> some View {
        let planned = breakManager.current?.plannedDuration ?? 1
        let left = remaining(now: now)
        let t = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.cycle)
        let inhaling = t < Self.inhale
        let phase = inhaling ? t / Self.inhale : 1 - (t - Self.inhale) / (Self.cycle - Self.inhale)
        let eased = 0.5 - cos(phase * .pi) / 2
        let scale = reduceMotion ? 0.82 : 0.62 + 0.38 * eased

        return ZStack {
            Circle().stroke(ink.opacity(0.08), lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, left / planned))))
                .stroke(ink.opacity(0.55), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Circle()
                .fill(RadialGradient(
                    colors: colorScheme == .dark
                        ? [Color(white: 1, opacity: 0.85), Color(red: 200/255, green: 186/255, blue: 240/255, opacity: 0.6), Color(red: 150/255, green: 130/255, blue: 210/255, opacity: 0.35)]
                        : [.white, Color(red: 251/255, green: 233/255, blue: 241/255), Color(red: 207/255, green: 195/255, blue: 240/255)],
                    center: UnitPoint(x: 0.4, y: 0.35), startRadius: 4, endRadius: 150))
                .shadow(color: Color(red: 120/255, green: 90/255, blue: 170/255).opacity(0.25), radius: 30, y: 20)
                .frame(width: 260, height: 260)
                .scaleEffect(scale)

            VStack(spacing: 6) {
                Text(reduceMotion ? "Breathe slowly" : (inhaling ? "Breathe in" : "Breathe out"))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color(red: 43/255, green: 36/255, blue: 51/255))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.6), value: inhaling)
                Text("\(SessionClock.format(left)) left")
                    .font(.system(size: 15).monospacedDigit())
                    .foregroundStyle(Color(red: 43/255, green: 36/255, blue: 51/255).opacity(0.6))
            }
        }
        .frame(width: 340, height: 340)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Break, \(Int((left / 60).rounded(.up))) minutes left. Breathe in for 4 seconds, out for 6.")
    }

    private func tipCard(now: Date) -> some View {
        // A new suggestion every 20 seconds.
        let index = Int(now.timeIntervalSinceReferenceDate / 20) % Self.tips.count
        return HStack(spacing: 12) {
            Image(systemName: "sun.max")
                .font(.system(size: 18))
                .foregroundStyle(ink.opacity(0.6))
            Text(Self.tips[index])
                .font(.system(size: 16))
                .foregroundStyle(ink)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.5), value: index)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(colorScheme == .dark ? 0.08 : 0.55)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(ink.opacity(0.08), lineWidth: 0.5))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            pill("+5 minutes") { onExtend(5) }
            if strictMode {
                Text("Strict breaks are on, so this one runs to the end.")
                    .font(.system(size: 13))
                    .foregroundStyle(ink.opacity(0.6))
                    .padding(.leading, 6)
            } else {
                pill("End break", action: onSkip)
                Button(action: onClose) {
                    Text("Hide — keep the timer in the menu bar")
                        .font(.system(size: 14))
                        .foregroundStyle(ink.opacity(0.6))
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(ink)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(Capsule().fill(.white.opacity(colorScheme == .dark ? 0.1 : 0.6)))
                .overlay(Capsule().strokeBorder(ink.opacity(0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
