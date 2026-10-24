import SwiftUI

/// Onboarding's lavender left panel, with a picture for each step.
struct OnboardingPanel: View {
    let step: OnboardingView.Step
    let level: BlockingLevel
    let drift: DriftResponse?
    let sessionMinutes: Int

    var body: some View {
        ZStack {
            LinearGradient(colors: [OnboardingPalette.panelTop, OnboardingPalette.panelBottom],
                           startPoint: .top, endPoint: .bottom)
            Group {
                switch step {
                case .welcome:     WelcomePanel()
                case .permissions: RecordedPanel()
                case .setup:       SetupPanel(level: level, drift: drift, sessionMinutes: sessionMinutes)
                case .browser:     ExtensionPanel()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 44)
            .padding(.bottom, 28)
        }
    }
}

/// A white card sitting on the panel.
private struct PanelCard<Content: View>: View {
    var radius: CGFloat = 18
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(OnboardingPalette.panelCard))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(OnboardingPalette.cardStroke.opacity(0.6), lineWidth: 0.5))
            .shadow(color: Theme.focus.opacity(0.1), radius: 15, y: 12)
    }
}

/// "● Focus", "● Distracting": a dot and a dark label.
private func categoryTag(_ color: Color, _ text: String) -> some View {
    HStack(spacing: 5) {
        Circle().fill(color).frame(width: 7, height: 7)
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.primaryText)
    }
    .fixedSize()
}

// MARK: - 1 · The shield filling up

private struct WelcomePanel: View {
    @State private var fill: Double = 0
    @ReduceMotion private var reduceMotion

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            ZStack {
                OnboardingShield().fill(.white)
                OnboardingWave(level: fill)
                    .fill(LinearGradient(colors: [Color(red: 128/255, green: 115/255, blue: 1),
                                                  Color(red: 80/255, green: 64/255, blue: 228/255)],
                                         startPoint: .top, endPoint: .bottom))
                    .clipShape(OnboardingShield())
            }
            .frame(width: 178, height: 223)
            .shadow(color: Theme.focus.opacity(0.18), radius: 22, y: 12)
            .onAppear {
                guard !reduceMotion else { fill = 0.57; return }
                withAnimation(.easeOut(duration: 2.4)) { fill = 0.57 }
            }

            HStack(spacing: 8) {
                MiniShield(fill: 0.5)
                Text("24m").font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.primaryText)
                Text("in your menu bar").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(OnboardingPalette.panelCard))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(OnboardingPalette.cardStroke.opacity(0.8), lineWidth: 0.5))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The FocusGuard shield, filling as a session runs. It shows 24 minutes in your menu bar.")
    }
}

/// The menu-bar shield, outlined and filled from the bottom.
private struct MiniShield: View {
    let fill: Double

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                Rectangle()
                    .fill(Theme.primaryText)
                    .frame(height: proxy.size.height * fill)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .clipShape(OnboardingShield())
            OnboardingShield().stroke(Theme.primaryText, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
        }
        .frame(width: 11, height: 14)
    }
}

// MARK: - 2 · What gets recorded

private struct RecordedPanel: View {
    var body: some View {
        VStack {
            Spacer()
            PanelCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("What gets recorded").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    row(AppGlyph(kind: .xcode, bundleId: "com.apple.dt.Xcode", size: 30), "Xcode", "BlockOverlayView.swift",
                        categoryTag(Theme.focus, "Focus"))
                    row(AppGlyph(kind: .twitter, size: 30), "x.com", "in Safari", categoryTag(Theme.distraction, "Distracting"))
                    Rectangle().fill(OnboardingPalette.cardStroke).frame(height: 0.5)
                    Text("Not recorded: keystrokes, screen contents, page text. Hide titles for any app in Settings.")
                        .font(.system(size: 12))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func row<Glyph: View, Tag: View>(_ glyph: Glyph, _ name: String, _ detail: String, _ tag: Tag) -> some View {
        HStack(spacing: 10) {
            glyph
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            tag
        }
    }
}

// MARK: - 3 · The first session, and what a drift does

struct SetupPanel: View {
    let level: BlockingLevel
    let drift: DriftResponse?
    let sessionMinutes: Int

    /// "Standard: a nudge at 0:30, the block screen at 1:30."
    static func presetLine(_ preset: DriftResponse?) -> String {
        guard let preset else { return "Your own timings from Settings." }
        let v = preset.values
        if v.strict { return "\(preset.title): the block screen at once. No passes; “It's for work” after 10 s." }
        func clock(_ s: Int) -> String { "\(s / 60):\(String(format: "%02d", s % 60))" }
        return "\(preset.title): a nudge at \(clock(v.notify)), the block screen at \(clock(v.block))."
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().stroke(Theme.focus.opacity(0.16), lineWidth: 13)
                    .frame(width: 144, height: 144)
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(Theme.focus, lineWidth: 3))
                    .frame(width: 18, height: 18)
                    .offset(y: -72)
                VStack(spacing: 0) {
                    Text("\(sessionMinutes):00")
                        .font(.system(size: 34, weight: .semibold).monospacedDigit())
                        .kerning(-0.7)
                        .foregroundStyle(Theme.primaryText)
                        .contentTransition(.numericText())
                    Text("your first session").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(width: 170, height: 170)
            .animation(.snappy, value: sessionMinutes)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Your first session: \(sessionMinutes) minutes")

            PanelCard(radius: 16, padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("If you drift to x.com").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    HStack(alignment: .top, spacing: 10) {
                        OnboardingShield().fill(Theme.focus).frame(width: 17, height: 21)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.previewTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                            Text(level.previewDetail).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Rectangle().fill(OnboardingPalette.cardStroke).frame(height: 0.5)
                    Text(Self.presetLine(drift)).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
        }
    }
}

// MARK: - 4 · One site, two answers

private struct ExtensionPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            HStack(spacing: 8) {
                Text("With Pro: one site, two answers").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                ProBadge()
            }
            .padding(.leading, 4)

            browser("youtube.com/watch?v=WWDC-swiftui") {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 62/255, green: 123/255, blue: 201/255),
                                                      Color(red: 122/255, green: 91/255, blue: 200/255)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 54, height: 34)
                    Text("SwiftUI layout, in depth").font(.system(size: 12)).foregroundStyle(Theme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    categoryTag(Theme.focus, "Focus")
                }
                .padding(12)
            }

            browser("youtube.com/shorts") {
                VStack(spacing: 6) {
                    OnboardingShield().fill(Theme.focus).frame(width: 18, height: 22)
                    Text("Shorts are blocked while you focus").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primaryText)
                    Text("The page never loaded.").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(LinearGradient(colors: [Theme.focus.opacity(0.04), Theme.focus.opacity(0.1)],
                                           startPoint: .top, endPoint: .bottom))
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    /// A tiny browser window: an address bar over its page.
    private func browser<Page: View>(_ address: String, @ViewBuilder page: () -> Page) -> some View {
        VStack(spacing: 0) {
            Text(address)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.fill3)
            page()
        }
        .background(OnboardingPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(OnboardingPalette.cardStroke.opacity(0.8), lineWidth: 0.5))
        .shadow(color: Theme.focus.opacity(0.1), radius: 13, y: 10)
    }
}
