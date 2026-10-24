import SwiftUI

/// The session a break follows, for the pill at the top of the break screen.
struct FinishedSession: Equatable {
    let name: String
    let minutes: Int
    let focusPercent: Int

    /// "· 50 min · 92% focused"
    var detail: String { "· \(minutes) min · \(focusPercent)% focused" }
}

/// Calm full-screen view shown when a break starts, the opposite of the
/// block screen: warm light (or dusk in dark mode), a breathing guide inside
/// the time-left ring, one small suggestion, and no gated buttons. +5, End
/// break and Hide work straight away, unless strict breaks are on: then the
/// break runs to the end and only +5 is offered.
struct BreakOverlayView: View {
    let breakManager: BreakManager
    /// The session that just ended, if the break follows one.
    var finished: FinishedSession?
    var onSkip: () -> Void
    var onExtend: (Int) -> Void
    var onClose: () -> Void

    @AppStorage(SettingsKeys.Breaks.strictMode) private var strictMode = false
    @Environment(\.colorScheme) private var colorScheme
    @ReduceMotion private var reduceMotion

    struct Tip: Equatable {
        let symbol: String
        let text: String
    }

    static let tips: [Tip] = [
        Tip(symbol: "sun.max", text: "Stand up and look at something across the room."),
        Tip(symbol: "drop", text: "Drink some water."),
        Tip(symbol: "figure.cooldown", text: "Roll your shoulders. Unclench your jaw."),
        Tip(symbol: "figure.walk", text: "Walk to another room and back."),
        Tip(symbol: "figure.arms.open", text: "Stretch your arms over your head for a few breaths."),
        Tip(symbol: "moon", text: "Close your eyes. Just for a moment."),
    ]

    /// One breath: 4 s in, 6 s out.
    private static let inhale: Double = 4
    private static let cycle: Double = 10

    /// The line under "Break": a long session gets a firmer nudge to rest.
    static func headline(after finished: FinishedSession?) -> String {
        guard let finished else { return "Time to rest. Let your eyes wander." }
        return finished.minutes >= 80 ? "That was a long one. Rest properly." : "Nice work. Let your eyes rest."
    }

    /// A new suggestion every 20 seconds.
    static func tip(at date: Date) -> Tip {
        tips[Int(date.timeIntervalSinceReferenceDate / 20) % tips.count]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let now = context.date
            ZStack {
                background
                VStack(spacing: 0) {
                    if let finished { sessionPill(finished) }
                    Text(Self.headline(after: finished))
                        .font(.system(size: 40, weight: .bold))
                        .kerning(-0.8)
                        .foregroundStyle(ink)
                        .multilineTextAlignment(.center)
                        .padding(.top, 18)
                    Text("Back at \(MomentText.time(now.addingTimeInterval(remaining(now: now)))) · blocking is off until then")
                        .font(.system(size: 15))
                        .foregroundStyle(inkSecondary)
                        .padding(.top, 8)

                    breathing(now: now)
                        .padding(.top, 24)

                    tipCard(now: now)
                        .padding(.top, 22)

                    controls
                        .padding(.top, 24)
                }
                .padding(40)
            }
        }
    }

    // MARK: - Colours

    private var isDark: Bool { colorScheme == .dark }

    private var ink: Color {
        isDark ? Color(red: 242/255, green: 239/255, blue: 247/255) : Color(red: 43/255, green: 36/255, blue: 51/255)
    }

    private var inkSecondary: Color {
        isDark ? Color(red: 242/255, green: 239/255, blue: 247/255).opacity(0.7) : Color(red: 90/255, green: 80/255, blue: 96/255)
    }

    /// The tip's icon: indigo on warm light, a lighter indigo at dusk.
    private var accent: Color {
        isDark ? Color(red: 159/255, green: 168/255, blue: 255/255) : Theme.focus
    }

    private var glass: Color { .white.opacity(isDark ? 0.08 : 0.58) }
    private var glassStroke: Color { isDark ? .white.opacity(0.12) : ink.opacity(0.08) }

    private var background: some View {
        let colors: [Color] = isDark
            ? [Color(red: 28/255, green: 26/255, blue: 43/255), Color(red: 39/255, green: 33/255, blue: 65/255), Color(red: 54/255, green: 41/255, blue: 63/255)]
            : [Color(red: 246/255, green: 231/255, blue: 214/255), Color(red: 243/255, green: 220/255, blue: 224/255), Color(red: 227/255, green: 222/255, blue: 247/255)]
        let warm = isDark ? Color(red: 190/255, green: 110/255, blue: 160/255).opacity(0.22) : Color(red: 1, green: 214/255, blue: 170/255).opacity(0.7)
        let cool = isDark ? Color(red: 109/255, green: 124/255, blue: 1).opacity(0.28) : Color(red: 190/255, green: 182/255, blue: 246/255).opacity(0.65)
        return GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: colors, startPoint: UnitPoint(x: 0.4, y: 0), endPoint: UnitPoint(x: 0.6, y: 1))
                Rectangle()
                    .fill(EllipticalGradient(colors: [warm, warm.opacity(0)], center: .center,
                                             startRadiusFraction: 0, endRadiusFraction: 0.5))
                    .frame(width: 780, height: 540)
                    .position(x: proxy.size.width * 0.1, y: proxy.size.height * 0.86)
                Rectangle()
                    .fill(EllipticalGradient(colors: [cool, cool.opacity(0)], center: .center,
                                             startRadiusFraction: 0, endRadiusFraction: 0.5))
                    .frame(width: 820, height: 620)
                    .position(x: proxy.size.width * 0.92, y: proxy.size.height * 0.2)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: - Pieces

    private func remaining(now: Date) -> TimeInterval {
        breakManager.current?.remaining(now: now) ?? 0
    }

    private func sessionPill(_ finished: FinishedSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 14))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Theme.focus)
            Text(finished.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
            Text(finished.detail).font(.system(size: 13)).foregroundStyle(inkSecondary)
        }
        .lineLimit(1)
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 5)
        .background(Capsule().fill(glass))
        .overlay(Capsule().strokeBorder(glassStroke, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    /// Breathing orb inside a thin ring that empties as the break runs out.
    private func breathing(now: Date) -> some View {
        let planned = breakManager.current?.plannedDuration ?? 1
        let left = remaining(now: now)
        let t = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.cycle)
        let inhaling = t < Self.inhale
        let phase = inhaling ? t / Self.inhale : 1 - (t - Self.inhale) / (Self.cycle - Self.inhale)
        let eased = 0.5 - cos(phase * .pi) / 2
        let scale = reduceMotion ? 0.82 : 0.64 + 0.36 * eased
        let onOrb = Color(red: isDark ? 28/255 : 43/255, green: isDark ? 26/255 : 36/255, blue: isDark ? 43/255 : 51/255)
        let orb: [Color] = isDark
            ? [Color(red: 236/255, green: 234/255, blue: 1), Color(red: 189/255, green: 182/255, blue: 244/255),
               Color(red: 126/255, green: 120/255, blue: 218/255), Color(red: 86/255, green: 80/255, blue: 180/255)]
            : [.white, Color(red: 247/255, green: 238/255, blue: 251/255),
               Color(red: 226/255, green: 220/255, blue: 250/255), Color(red: 201/255, green: 193/255, blue: 244/255)]

        return ZStack {
            Circle().stroke(ink.opacity(0.08), lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, left / planned))))
                .stroke(Theme.focus.opacity(isDark ? 0.85 : 0.7), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Circle()
                .fill(RadialGradient(colors: orb, center: UnitPoint(x: 0.4, y: 0.35), startRadius: 4, endRadius: 150))
                .shadow(color: Theme.focus.opacity(isDark ? 0.35 : 0.22), radius: isDark ? 40 : 30, y: isDark ? 0 : 20)
                .frame(width: 260, height: 260)
                .scaleEffect(scale)

            VStack(spacing: 6) {
                Text(reduceMotion ? "Breathe slowly" : (inhaling ? "Breathe in" : "Breathe out"))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(onOrb)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.6), value: inhaling)
                Text("\(MomentText.clock(left)) left")
                    .font(.system(size: 15).monospacedDigit())
                    .foregroundStyle(isDark ? Color(red: 46/255, green: 42/255, blue: 85/255) : Color(red: 90/255, green: 80/255, blue: 96/255))
            }
        }
        .frame(width: 340, height: 340)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Break, \(Int((left / 60).rounded(.up))) minutes left. Breathe in for 4 seconds, out for 6.")
    }

    private func tipCard(now: Date) -> some View {
        let tip = Self.tip(at: now)
        return HStack(spacing: 12) {
            Image(systemName: tip.symbol)
                .font(.system(size: 18))
                .foregroundStyle(accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(tip.text)
                .font(.system(size: 16))
                .foregroundStyle(ink)
                .contentTransition(.opacity)
        }
        .animation(.easeInOut(duration: 0.5), value: tip)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(glass))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(glassStroke, lineWidth: 0.5))
    }

    @ViewBuilder private var controls: some View {
        if strictMode {
            VStack(spacing: 12) {
                pill("+5 minutes") { onExtend(5) }
                Label("Strict breaks are on, so this one runs to the end.", systemImage: "lock")
                    .font(.system(size: 13))
                    .foregroundStyle(inkSecondary)
            }
        } else {
            HStack(spacing: 10) {
                pill("+5 minutes") { onExtend(5) }
                pill("End break", action: onSkip)
                Button(action: onClose) {
                    HStack(spacing: 8) {
                        Text("esc")
                            .font(.system(size: 12))
                            .foregroundStyle(ink)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(ink.opacity(0.08)))
                        Text("Hide, keep the timer in the menu bar")
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(inkSecondary)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Hide, keep the timer in the menu bar")
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
                .background(Capsule().fill(.white.opacity(isDark ? 0.12 : 0.65)))
                .overlay(Capsule().strokeBorder(isDark ? .white.opacity(0.2) : ink.opacity(0.12), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
