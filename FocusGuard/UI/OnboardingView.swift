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

/// First-run window: welcome, permissions, setup. Opens on first launch and
/// from any "Set up…" button; every step can be revisited later in Settings.
/// Closing it any way counts as done, so it doesn't greet the user again.
@MainActor
final class OnboardingWindowController {
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
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 580),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setFrame(NSRect(x: 0, y: 0, width: 880, height: 580), display: false)
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

struct OnboardingView: View {
    enum Step: Int, CaseIterable { case welcome, permissions, setup }

    @Bindable var appState: AppState
    @State var step: Step
    var onFinish: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            visualPanel
                .frame(width: 340)
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    switch step {
                    case .welcome:     WelcomeStep()
                    case .permissions: PermissionsStep(permissions: appState.permissions)
                    case .setup:       SetupStep(appState: appState)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                Spacer(minLength: 12)
                footer
            }
            .padding(.horizontal, 44)
            .padding(.top, 44)
            .padding(.bottom, 26)
        }
        .frame(minWidth: 880, maxWidth: .infinity, minHeight: 540, maxHeight: .infinity)
        .background(Theme.windowBackground)
        .ignoresSafeArea()
    }

    // MARK: - Left panel

    private var visualPanel: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 46/255, green: 42/255, blue: 107/255),
                                    Color(red: 75/255, green: 62/255, blue: 143/255),
                                    Color(red: 154/255, green: 94/255, blue: 134/255)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Group {
                switch step {
                case .welcome:     WelcomeVisual()
                case .permissions: RecordedVisual()
                case .setup:       SetupVisual()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 28)
        }
        .foregroundStyle(.white)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s == step ? Theme.focusFill : Color.primary.opacity(0.15))
                        .frame(width: s == step ? 18 : 7, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(step.rawValue + 1) of 3")
            Spacer()
            if step != .welcome {
                Button("Back") { withAnimation(.snappy) { step = Step(rawValue: step.rawValue - 1) ?? .welcome } }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Capsule().fill(Theme.control))
            }
            Button {
                if let next = Step(rawValue: step.rawValue + 1) {
                    withAnimation(.snappy) { step = next }
                } else {
                    startFirstSession()
                }
            } label: {
                Text(step == .setup ? "Start my first session" : "Continue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 34)
                    .background(Capsule().fill(Theme.focusFill))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            if step == .setup {
                Button("Not now") { onFinish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func startFirstSession() {
        let minutes = UserDefaults.standard.object(forKey: SessionDefaultsKey.durationMinutes) as? Int ?? 50
        let label = UserDefaults.standard.string(forKey: SessionDefaultsKey.label) ?? ""
        appState.sessionManager.startSession(label: label.isEmpty ? nil : label, plannedDurationMinutes: minutes)
        onFinish()
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Welcome").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.focus)
            Text("Focus that keeps itself honest.")
                .font(.system(size: 30, weight: .bold)).kerning(-0.6)
                .padding(.top, 6)
            Text("FocusGuard lives in your menu bar. Start a session, and it quietly notices when you drift and helps you back.")
                .font(.system(size: 15)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: 18) {
                feature("play.fill", "Start from the shield", "Click the shield in the menu bar, turn the dial to any length and start. It fills as you go.")
                feature("exclamationmark.shield", "Gentle nudges when you drift", "Wander to a distracting site and you'll get a nudge, then a pause screen if you stay.")
                feature("lock", "Your activity stays on this Mac", PrivacyStatement.short)
            }
            .padding(.top, 26)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.focus)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.focusTint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The shield filling up, and how it looks in the menu bar.
private struct WelcomeVisual: View {
    @State private var fill: Double = 0
    @ReduceMotion private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            StatusGlyphView(state: .focusing(progress: fill), tint: .white, size: 150)
                .onAppear {
                    guard !reduceMotion else { fill = 0.62; return }
                    withAnimation(.easeInOut(duration: 1.4)) { fill = 1 }
                    withAnimation(.easeInOut(duration: 1.0).delay(1.5)) { fill = 0.62 }
                }
            HStack(spacing: 6) {
                StatusGlyphView(state: .focusing(progress: 0.62), tint: .white, size: 14)
                Text("24m").monospacedDigit()
                Text("· in your menu bar").opacity(0.6)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.14)))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The FocusGuard shield in the menu bar, filling as a session runs")
    }
}

// MARK: - Permissions

private struct PermissionsStep: View {
    @Bindable var permissions: PermissionsCoordinator

    private var ready: Int {
        [permissions.screenRecording, permissions.notifications].filter { $0 == .granted }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Permissions · \(ready) of 2 ready").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.focus)
            Text("What FocusGuard can see")
                .font(.system(size: 28, weight: .bold)).kerning(-0.5)
                .padding(.top, 6)
            Text("Only what it needs to tell focus from drift. Grant these in System Settings; this screen updates on its own.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            VStack(spacing: 10) {
                row("Screen Recording",
                    "Lets macOS share window titles, like “Project proposal — Pages”. FocusGuard never records your screen.",
                    status: permissions.screenRecording) { permissions.requestScreenRecording() }
                row("Notifications",
                    "For the nudge when you drift and the note when a session ends.",
                    status: permissions.notifications) { Task { await permissions.requestNotifications() } }
                browserRow
            }
            .padding(.top, 20)
            Text("No Accessibility access needed. You can change any of this later in Settings.")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
                .padding(.top, 14)
        }
        .task {
            // Pick up grants made in System Settings without a Refresh button.
            while !Task.isCancelled {
                await permissions.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func row(_ title: String, _ why: String, status: PermissionStatus, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(why).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if status == .granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .symbolRenderingMode(.multicolor)
            } else {
                Button("Open Settings…", action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.focusFill)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.windowCard))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
    }

    private var browserRow: some View {
        let denied = !(UserDefaults.standard.stringArray(forKey: SettingsKeys.browserAutomationDenied) ?? []).isEmpty
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Browser access").font(.system(size: 14, weight: .semibold))
                Text("Reads the site in Safari or Chrome so youtube.com isn't just “Chrome”. macOS asks once per browser.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if denied {
                Button("Open Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.focusFill)
                .controlSize(.small)
            } else {
                Text("macOS asks\non first use")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.windowCard))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
    }
}

/// What a tracked moment looks like — and what's never recorded.
private struct RecordedVisual: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Text("What gets recorded").font(.system(size: 12)).opacity(0.7)
            VStack(spacing: 10) {
                line("App", "Pages")
                line("Window", "Project proposal")
                line("Site", "—")
                HStack {
                    Text("Counted as").opacity(0.7)
                    Spacer()
                    Circle().fill(Color(red: 143/255, green: 155/255, blue: 255/255)).frame(width: 7, height: 7)
                    Text("Focus")
                }
            }
            .font(.system(size: 13))
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.12)))
            Text("Not recorded: keystrokes, screen contents, page text. Hide titles for any app in Settings → Privacy.")
                .font(.system(size: 12)).opacity(0.7)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func line(_ key: String, _ value: String) -> some View {
        HStack { Text(key).opacity(0.7); Spacer(); Text(value) }
    }
}

// MARK: - Setup

private struct SetupStep: View {
    @Bindable var appState: AppState
    @AppStorage(SettingsKeys.Goal.dailyFocusMinutes) private var goalMinutes = GoalDefaults.dailyFocusMinutes
    @AppStorage(SessionDefaultsKey.durationMinutes) private var defaultMinutes = 50
    @AppStorage("menu.lastSessionMinutes") private var lastSessionMinutes = 0
    /// Nil when the escalation settings were tuned by hand: none is shown
    /// as picked, and nothing is applied unless the user picks one.
    @State private var drift: DriftResponse? = DriftResponse.current
    @State private var launchAtLogin = LoginItemController.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your setup").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.focus)
            Text("Make it yours")
                .font(.system(size: 28, weight: .bold)).kerning(-0.5)
                .padding(.top, 6)
            Text("Sensible defaults — change them anytime from the menu.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Daily focus goal").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Stepper(value: $goalMinutes, in: FocusGoal.range, step: 15) {
                        Text(FocusGoal.format(minutes: goalMinutes))
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    }
                }
                HStack {
                    Text("Usual session length").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Picker("Usual session length", selection: Binding(
                        get: { defaultMinutes },
                        set: { defaultMinutes = $0; lastSessionMinutes = $0 }
                    )) {
                        Text("25 min").tag(25)
                        Text("50 min").tag(50)
                        Text("90 min").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("When you drift").font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 8) {
                        ForEach(DriftResponse.allCases) { option in
                            Button {
                                drift = option
                                option.apply(to: appState.escalationEngine)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(option.title).font(.system(size: 13, weight: .semibold))
                                    Text(option.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.windowCard))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(drift == option ? Theme.focus : Theme.moduleStroke, lineWidth: drift == option ? 2 : 0.5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(drift == option ? .isSelected : [])
                        }
                    }
                    if drift == nil {
                        Text("You've set your own timings in Settings. Pick one to replace them.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Open at login").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Toggle("Open at login", isOn: Binding(
                        get: { launchAtLogin },
                        set: { LoginItemController.setEnabled($0); launchAtLogin = LoginItemController.isEnabled }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }
            .padding(.top, 20)
        }
    }
}

private struct SetupVisual: View {
    @AppStorage(SessionDefaultsKey.durationMinutes) private var defaultMinutes = 50

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 14)
                Circle().fill(.white).frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color(red: 143/255, green: 155/255, blue: 255/255), lineWidth: 3))
                    .offset(y: -80)
                VStack(spacing: 2) {
                    Text("\(defaultMinutes):00").font(.system(size: 34, weight: .semibold).monospacedDigit())
                    Text("your first session").font(.system(size: 12)).opacity(0.75)
                }
            }
            .frame(width: 174, height: 174)
            Text("Ready when you are. Start now, or later from the shield in your menu bar.")
                .font(.system(size: 13)).opacity(0.8)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}
