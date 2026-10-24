import AppKit
import SwiftUI

extension Notification.Name {
    /// Ask the app delegate to show the onboarding window (from "Set up…").
    static let showOnboarding = Notification.Name("FocusGuard.showOnboarding")
}

enum OnboardingState {
    static let completedKey = "onboarding.completed"
    static var isCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }
}

/// First-run window: welcome, permissions, setup and the browser extension.
/// Opens on first launch and from any "Set up…" button; every step can be
/// revisited later in Settings. Closing it any way counts as done, so it
/// doesn't greet the user again.
@MainActor
final class OnboardingWindowController {
    static let size = NSSize(width: 960, height: 640)

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show(appState: AppState, startAt step: OnboardingView.Step = .welcome) {
        let view = OnboardingView(appState: appState, step: step) { [weak self] in self?.close() }
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []   // the window sets the size; content fills it, title bar included
        if let window {
            // Already open: start over at the step asked for.
            let frame = window.frame
            window.contentViewController = hosting
            window.setFrame(frame, display: true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setFrame(NSRect(origin: .zero, size: Self.size), display: false)
        window.center()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didClose() }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        let closing = window
        didClose()
        DispatchQueue.main.async { closing?.close() }
    }

    /// The window is going away, by a button or its close box.
    private func didClose() {
        OnboardingState.isCompleted = true
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window = nil
    }
}

// MARK: - Blocking level

/// What happens when the block screen comes up, picked in setup.
enum BlockingLevel: String, CaseIterable, Identifiable {
    /// Free: the site's tab switches to a calm FocusGuard page.
    case pauseTab
    /// Pro: the browser extension stops pages before they load.
    case browser
    /// Pro, later: every browser and app. Needs the paid Apple Developer
    /// Program for the network filter, so it shows as "Coming later".
    case wholeMac

    var id: String { rawValue }

    var isPro: Bool { self != .pauseTab }

    /// The Pro feature behind this level, if any.
    var feature: ProFeature? {
        switch self {
        case .pauseTab: return nil
        case .browser:  return .blockInBrowser
        case .wholeMac: return .macWideBlock
        }
    }

    var title: String {
        switch self {
        case .pauseTab: return "Pause the tab"
        case .browser:  return "Block in the browser"
        case .wholeMac: return "Block on the whole Mac"
        }
    }

    var detail: String {
        switch self {
        case .pauseTab: return "The tab switches to a calm page while you're blocked."
        case .browser:  return "Pages never load. Parts of sites too, like youtube.com/shorts."
        case .wholeMac: return "Every browser and app. Whole sites only."
        }
    }

    /// The setup step's preview: what drifting to x.com looks like.
    var previewTitle: String {
        switch self {
        case .pauseTab: return "x.com is paused while you focus"
        case .browser:  return "x.com won't load"
        case .wholeMac: return "x.com is blocked on this Mac"
        }
    }

    var previewDetail: String {
        switch self {
        case .pauseTab: return "The tab switches to a calm FocusGuard page."
        case .browser:  return "The browser extension stops it before it opens."
        case .wholeMac: return "In every browser and app, until the session ends."
        }
    }

    /// Whether it can be picked now. Whole-Mac blocking isn't built yet;
    /// browser blocking needs Pro, or a trial that hasn't been used.
    @MainActor
    func isAvailable(_ entitlements: Entitlements) -> Bool {
        switch self {
        case .pauseTab: return true
        case .browser:  return entitlements.isUnlocked(.blockInBrowser) || entitlements.canStartTrial
        case .wholeMac: return false
        }
    }

    /// The level to show as picked when setup opens.
    @MainActor
    static func initial(_ entitlements: Entitlements) -> BlockingLevel {
        entitlements.isUnlocked(.blockInBrowser) ? .browser : .pauseTab
    }

    /// Setup is done with this level picked: a Pro level starts the 14-day
    /// trial (once, no card). Pausing the tab is free and starts nothing,
    /// and so does adding the browser extension, which never calls this.
    @MainActor
    func commit(_ entitlements: Entitlements) {
        guard self == .browser, let feature else { return }
        entitlements.startTrialIfNeeded(for: feature)
    }
}

// MARK: - The window

struct OnboardingView: View {
    enum Step: Int, CaseIterable { case welcome, permissions, setup, browser }

    @Bindable var appState: AppState
    @State var step: Step
    var onFinish: () -> Void
    let entitlements: Entitlements

    /// The setup step's choices; the left panel previews them.
    @State private var level: BlockingLevel
    @State private var drift: DriftResponse? = DriftResponse.current
    @AppStorage(SettingsKeys.Session.defaultDurationMinutes) private var sessionMinutes = 50
    @ReduceMotion private var reduceMotion

    @MainActor
    init(appState: AppState, step: Step, entitlements: Entitlements = .shared, onFinish: @escaping () -> Void) {
        self.appState = appState
        _step = State(initialValue: step)
        self.entitlements = entitlements
        self.onFinish = onFinish
        _level = State(initialValue: BlockingLevel.initial(entitlements))
    }

    var body: some View {
        HStack(spacing: 0) {
            OnboardingPanel(step: step, level: level, drift: drift, sessionMinutes: sessionMinutes)
                .frame(width: 340)
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    switch step {
                    case .welcome:     WelcomeStep()
                    case .permissions: PermissionsStep(appState: appState)
                    case .setup:
                        SetupStep(entitlements: entitlements, presetLocked: appState.isStrictLocked,
                                  setPreset: { appState.setDriftResponse($0) }, level: $level, drift: $drift)
                    case .browser:     ExtensionStep(bridge: appState.extensionBridge, entitlements: entitlements, level: level)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .transition(Motion.transition(.opacity, reduced: reduceMotion))
                Spacer(minLength: 12)
                footer
            }
            .padding(.horizontal, 44)
            .padding(.top, step == .welcome ? 52 : 40)
            .padding(.bottom, 28)
        }
        .frame(minWidth: OnboardingWindowController.size.width, maxWidth: .infinity,
               minHeight: OnboardingWindowController.size.height, maxHeight: .infinity)
        .background(OnboardingPalette.window)
        .ignoresSafeArea()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s == step ? Theme.focusFill : Theme.primaryText.opacity(0.15))
                        .frame(width: s == step ? 18 : 7, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
            Spacer()
            if step != .welcome {
                Button("Back") { go(Step(rawValue: step.rawValue - 1) ?? .welcome) }
                    .buttonStyle(.capsule(.secondary, height: 36))
            }
            if step == .browser {
                Button("Not now", action: onFinish)
                    .buttonStyle(.capsule(.secondary, height: 36))
                    .help("Close without starting a session. Start one from the shield in the menu bar.")
            }
            Button(step == .browser ? "Start my first session" : "Continue") {
                if step == .setup { level.commit(entitlements) }
                if let next = Step(rawValue: step.rawValue + 1) {
                    go(next)
                } else {
                    startFirstSession()
                }
            }
            .buttonStyle(.capsule(.primary, height: 36))
            .keyboardShortcut(.defaultAction)
        }
    }

    private func go(_ next: Step) {
        withAnimation(reduceMotion ? nil : .snappy) { step = next }
    }

    private func startFirstSession() {
        let label = UserDefaults.standard.string(forKey: SettingsKeys.Session.defaultLabel) ?? ""
        appState.sessionManager.startSession(label: label.isEmpty ? nil : label, plannedDurationMinutes: sessionMinutes)
        onFinish()
    }
}

// MARK: - Look

/// Onboarding's colours: a lavender left panel, like the icon, and a near
/// white page (dusk and the window grey in dark mode).
enum OnboardingPalette {
    static let window = dynamic(
        light: Color(red: 252/255, green: 252/255, blue: 254/255),
        dark:  Color(red: 28/255, green: 28/255, blue: 33/255)          // #1C1C21
    )
    static let panelTop = dynamic(
        light: Color(red: 246/255, green: 244/255, blue: 255/255),      // #F6F4FF
        dark:  Color(red: 43/255, green: 40/255, blue: 70/255)
    )
    static let panelBottom = dynamic(
        light: Color(red: 226/255, green: 222/255, blue: 255/255),      // #E2DEFF
        dark:  Color(red: 32/255, green: 30/255, blue: 54/255)
    )
    /// Cards that sit on the lavender panel.
    static let panelCard = dynamic(light: .white.opacity(0.82), dark: .white.opacity(0.07))
    /// Rows on the page.
    static let card = dynamic(light: .white, dark: Color(red: 38/255, green: 38/255, blue: 44/255))
    static let cardStroke = dynamic(light: .black.opacity(0.1), dark: .white.opacity(0.1))
    /// Behind a row's icon when the permission is optional.
    static let quietTile = dynamic(light: .black.opacity(0.05), dark: .white.opacity(0.08))

    static func dynamic(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

/// The FocusGuard shield, as drawn on the canvases.
struct OnboardingShield: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: p(0.5, 0))
        path.addLine(to: p(1, 0.164))
        path.addLine(to: p(1, 0.454))
        path.addCurve(to: p(0.5, 1), control1: p(1, 0.695), control2: p(0.794, 0.9))
        path.addCurve(to: p(0, 0.454), control1: p(0.206, 0.9), control2: p(0, 0.695))
        path.addLine(to: p(0, 0.164))
        path.closeSubpath()
        return path
    }
}

/// A soft wave filling a shape from the bottom up to `level` (0 empty, 1 full).
struct OnboardingWave: Shape {
    var level: Double

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let top = rect.maxY - rect.height * level
        let amplitude = rect.height * 0.035
        var path = Path()
        path.move(to: CGPoint(x: rect.minX - 4, y: top))
        path.addCurve(to: CGPoint(x: rect.midX, y: top),
                      control1: CGPoint(x: rect.minX + rect.width * 0.2, y: top - amplitude),
                      control2: CGPoint(x: rect.minX + rect.width * 0.3, y: top + amplitude))
        path.addCurve(to: CGPoint(x: rect.maxX + 4, y: top),
                      control1: CGPoint(x: rect.minX + rect.width * 0.7, y: top - amplitude),
                      control2: CGPoint(x: rect.minX + rect.width * 0.8, y: top + amplitude))
        path.addLine(to: CGPoint(x: rect.maxX + 4, y: rect.maxY + 4))
        path.addLine(to: CGPoint(x: rect.minX - 4, y: rect.maxY + 4))
        path.closeSubpath()
        return path
    }
}

/// "Welcome", "Permissions · 2 of 4 ready": the small indigo line over a title.
struct OnboardingEyebrow<Badge: View>: View {
    let text: String
    @ViewBuilder var badge: () -> Badge

    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.link)
            badge()
        }
    }
}

extension OnboardingEyebrow where Badge == EmptyView {
    init(_ text: String) {
        self.init(text: text) { EmptyView() }
    }
}

/// A step's title and the line under it.
struct OnboardingHeading: View {
    let title: String
    let detail: String
    var size: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: size, weight: .bold))
                .kerning(-size * 0.02)
                .foregroundStyle(Theme.primaryText)
                .padding(.top, 6)
            Text(detail)
                .font(.system(size: size > 28 ? 15 : 14))
                .lineSpacing(3)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, size > 28 ? 10 : 8)
        }
    }
}
