import SwiftUI

/// The rich menu under the status item. One phase at a time — ready, in a
/// session (maybe drifted), just finished, or on a break — then the native
/// menu items. Laid out like a macOS menu: a 6pt inset glass panel holding
/// concentric rounded modules, circular control platters, and plain rows.
struct MenuBarView: View {
    @Bindable var permissions: PermissionsCoordinator
    @Bindable var appState: AppState
    var onOpenMain: (MainTab) -> Void = { _ in }
    var dismiss: () -> Void = {}

    @State private var showingCustomDuration = false
    @State private var customMinutes: Int = 30
    @State private var pick: SessionDurationChoice = .min50
    @State private var now: Date = .now
    /// Side pane slid out next to the session column, if any.
    @State private var openPane: MenuPane?
    @AppStorage(SessionDefaultsKey.label) private var defaultLabel = "Deep work"
    @AppStorage(SessionDefaultsKey.durationMinutes) private var defaultMinutes = 50
    /// The picker opens on the last length the user started with.
    @AppStorage("menu.lastSessionMinutes") private var lastSessionMinutes = 0

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let phase = appState.menuPhase(now: now)

        HStack(alignment: .top, spacing: 6) {
        VStack(alignment: .leading, spacing: 6) {
            header(for: phase)

            if !permissions.allGranted {
                permissionModule
            }

            switch phase {
            case .ready:
                readyContent
            case .session(let session, let drift):
                sessionContent(session, drift: drift)
            case .recap(let recap):
                recapContent(recap)
            case .onBreak(let state):
                breakContent(state)
            }

            menuItems(for: phase)
        }
        .frame(width: 308)

            if let pane = openPane {
                MenuPaneView(pane: pane, appState: appState, onOpenMain: onOpenMain, dismiss: dismiss) {
                    withAnimation(.snappy(duration: 0.22)) { openPane = nil }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(6)
        .task { await permissions.refresh() }
        .onAppear(perform: restorePick)
        .onReceive(ticker) { now = $0 }
        .sheet(isPresented: $showingCustomDuration) {
            CustomDurationSheet(minutes: $customMinutes) { minutes in
                showingCustomDuration = false
                if let minutes {
                    customMinutes = minutes
                    pick = .custom
                }
            }
        }
    }

    // MARK: - Header

    private func header(for phase: MenuPhase) -> some View {
        let (glyph, tint, title, subtitle) = headerContent(for: phase)
        return HStack(spacing: 10) {
            StatusGlyphView(state: glyph, tint: tint, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            PaneButtons(open: $openPane)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func headerContent(for phase: MenuPhase) -> (StatusGlyphState, Color, String, String) {
        switch phase {
        case .ready:
            return (.ready, Theme.focus, "FocusGuard", "Ready when you are")

        case .onBreak(let state):
            let backAt = now.addingTimeInterval(state.remaining(now: now))
            return (.onBreak, .primary, "Break", "Back at \(clock(backAt)) · blocking paused")

        case .recap(let recap):
            return (.complete, Theme.focus, "Session complete",
                    "\(recap.label) · \(clock(recap.startedAt))–\(clock(recap.endedAt))")

        case .session(let session, let drift):
            let label = session.label ?? "Focus session"
            let planned = session.plannedDurationMinutes
            let elapsed = appState.sessionManager.runningSeconds(for: session, now: now)

            if session.pausedAt != nil {
                let left = planned.map { " · \(formatMinutes(Double($0 * 60) - elapsed)) left" } ?? ""
                return (.paused, .primary, label, "Paused\(left)")
            }
            let subtitle = planned.map { "\($0)-minute session · started \(clock(session.startedAt))" }
                ?? "Open-ended · started \(clock(session.startedAt))"
            if drift != nil {
                return (.drifted, Theme.distractionInk, "\(label) · drifted", subtitle)
            }
            return (.focusing(elapsed: elapsed, planned: planned.map { Double($0 * 60) }),
                    Theme.focus, label, subtitle)
        }
    }

    // MARK: - Ready

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            todayModule

            Text("Focus for")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)

            HStack(spacing: 4) {
                ForEach(SessionDurationChoice.allCases, id: \.self) { choice in
                    durationButton(choice)
                }
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Session length")

            CapsuleButton(title: startTitle, prominent: true) { start() }
                .padding(.horizontal, 4)
                .padding(.top, 6)
                .padding(.bottom, 2)

            NowRow(snapshot: appState.tracker.currentSnapshot)
        }
    }

    private var todayModule: some View {
        let focus = appState.todayBreakdown.focus
        let progress = FocusGoal.progress(focusSecondsToday: focus)
        let streak = appState.currentStreak

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today")
                Spacer()
                if streak >= 2 { Text("\(streak)-day streak") }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatMinutes(focus))
                    .font(.system(size: 26, weight: .semibold).monospacedDigit())
                    .kerning(-0.5)
                Text("focused")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.control)
                    Capsule().fill(Theme.focus)
                        .frame(width: geo.size.width * CGFloat(min(1, progress)))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)

            Text("\(Int((progress * 100).rounded()))% of your \(FocusGoal.format(minutes: FocusGoal.dailyMinutes)) goal")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .menuModule()
    }

    private func durationButton(_ choice: SessionDurationChoice) -> some View {
        let selected = pick == choice
        let big: String
        let label: String
        switch choice {
        case .custom:
            big = pick == .custom ? "\(customMinutes)" : "…"
            label = "Custom"
        default:
            big = "\(choice.minutes ?? 0)"
            label = "\(choice.minutes ?? 0) min"
        }

        return Button {
            if choice == .custom { showingCustomDuration = true } else { pick = choice }
        } label: {
            VStack(spacing: 5) {
                Text(big)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(selected ? Theme.focusFill : Theme.control))
                Text(label)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice == .custom ? "Custom length" : "\(choice.minutes ?? 0) minutes")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var chosenMinutes: Int { pick == .custom ? customMinutes : (pick.minutes ?? 50) }

    private var startTitle: String { "Start \(chosenMinutes) minutes of focus" }

    private func restorePick() {
        let minutes = lastSessionMinutes > 0 ? lastSessionMinutes : defaultMinutes
        switch minutes {
        case 25: pick = .min25
        case 50: pick = .min50
        case 90: pick = .min90
        default:
            customMinutes = minutes
            pick = .custom
        }
    }

    private func start() {
        lastSessionMinutes = chosenMinutes
        appState.sessionManager.startSession(
            label: defaultLabel.isEmpty ? nil : defaultLabel,
            plannedDurationMinutes: chosenMinutes
        )
    }

    // MARK: - Session

    private func sessionContent(_ session: Session, drift: DriftInfo?) -> some View {
        let isPaused = session.pausedAt != nil
        let timeline = appState.liveTimeline(for: session, now: now)
        let elapsed = appState.sessionManager.runningSeconds(for: session, now: now)
        let runs = appState.focusRuns(for: session, now: now)

        return VStack(alignment: .leading, spacing: 6) {
            if let drift {
                driftModule(drift)
            }

            VStack(spacing: 14) {
                SessionRingView(
                    timeline: timeline,
                    progress: SessionTimeline.progress(elapsed: elapsed, timeline: timeline),
                    secondsSweep: isPaused ? nil : SessionClock.sweep(elapsed: elapsed)
                ) {
                    ringCenter(session: session, elapsed: elapsed, isPaused: isPaused)
                }
                RingLegend(trailing: timeline.classifiedCells > 0 ? "\(timeline.focusPercent)% focused" : nil)
            }
            .padding(.top, 4)
            .menuModule()

            ZoneModule(runs: runs, bestToday: appState.bestZoneToday(now: now), drifting: drift != nil)

            HStack(spacing: 6) {
                if isPaused {
                    ControlPlatter(systemImage: "play.fill", title: "Resume") {
                        appState.sessionManager.resumeSession()
                    }
                } else {
                    ControlPlatter(systemImage: "pause.fill", title: "Pause") {
                        appState.sessionManager.pauseSession()
                    }
                }
                if session.plannedDurationMinutes != nil {
                    ControlPlatter(systemImage: "plus", title: "5 more min") {
                        appState.sessionManager.extendSession(byMinutes: 5)
                    }
                }
                ControlPlatter(systemImage: "stop.fill", title: "End") {
                    appState.sessionManager.stopSession()
                }
            }
            .padding(.vertical, 4)

            if drift == nil {
                NowRow(snapshot: appState.tracker.currentSnapshot)
            }
        }
    }

    /// Live clock: time left counting down (or elapsed counting up for
    /// open-ended sessions), with the end time underneath.
    private func ringCenter(session: Session, elapsed: TimeInterval, isPaused: Bool) -> some View {
        let big: String
        let unit: String
        let detail: String
        if let planned = session.plannedDurationMinutes {
            let left = max(0, Double(planned * 60) - elapsed)
            big = SessionClock.format(left)
            unit = "left"
            detail = isPaused ? "paused" : "ends \(clock(now.addingTimeInterval(left)))"
        } else {
            big = SessionClock.format(elapsed)
            unit = "elapsed"
            detail = isPaused ? "paused" : "open-ended"
        }
        return VStack(spacing: 0) {
            Text(big)
                .font(.system(size: big.count > 5 ? 30 : 38, weight: .semibold).monospacedDigit())
                .kerning(-0.8)
                .contentTransition(.numericText(countsDown: session.plannedDurationMinutes != nil))
                .animation(.snappy(duration: 0.25), value: big)
            Text(unit)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
        }
    }

    private func driftModule(_ drift: DriftInfo) -> some View {
        let away = Int(now.timeIntervalSince(drift.since))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AppGlyph(
                    kind: AppGlyph.kind(forBundleId: drift.snapshot.bundleIdentifier, name: drift.snapshot.appName),
                    bundleId: drift.snapshot.bundleIdentifier,
                    size: 30
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(drift.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("You've been here \(away / 60):\(String(format: "%02d", away % 60))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(blockCaption(drift))
                    .font(.system(size: 11).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                CapsuleButton(title: "Back to work", prominent: true, height: 32) {
                    appState.backToWork()
                    dismiss()
                }
                CapsuleButton(title: "It's for work", prominent: false, height: 32) {
                    appState.allowCurrentDriftForSession()
                }
                .help("Stop nudging about \(drift.displayName) until this session ends.")
            }
        }
        .menuModule(tint: Theme.distraction)
    }

    private func blockCaption(_ drift: DriftInfo) -> String {
        guard let blocksAt = drift.blocksAt else { return "Screen\nblocked" }
        let left = Int(blocksAt.timeIntervalSince(now).rounded(.up))
        return left > 0 ? "Screen blocks\nin \(left) s" : "Screen\nblocked"
    }

    // MARK: - Recap

    private func recapContent(_ recap: SessionRecap) -> some View {
        let timeline = recap.timeline
        let m = timeline.minutesPerCell
        return VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 14) {
                SessionRingView(timeline: timeline, progress: nil) {
                    VStack(spacing: 0) {
                        Text("\(timeline.focusPercent)%")
                            .font(.system(size: 40, weight: .semibold).monospacedDigit())
                            .kerning(-1.2)
                        Text("focused")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        Text("\(timeline.focusCells * m) of \(timeline.classifiedCells * m) min")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                    }
                }
                RingLegend(counts: (timeline.focusCells * m, timeline.driftCells * m, timeline.otherCells * m))
            }
            .padding(.top, 4)
            .menuModule()

            HStack(alignment: .top, spacing: 10) {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Longest in the zone")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("\(Int(recap.longestZone / 60)) min")
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        if recap.isBestToday {
                            Text("Best today")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.focus)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                stat("Most drift", recap.topDrift.map {
                    "\($0.name) · \(max(1, Int(($0.seconds / 60).rounded()))) min"
                } ?? "None")
            }
            .menuModule()

            Text("Up next")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)

            VStack(spacing: 6) {
                CapsuleButton(title: "Take a \(recap.suggestedBreakMinutes)-minute break", prominent: true) {
                    appState.startBreak(durationMinutes: recap.suggestedBreakMinutes)
                }
                CapsuleButton(title: "Another \(recap.nextSessionMinutes) minutes", prominent: false) {
                    appState.sessionManager.startSession(label: recap.label, plannedDurationMinutes: recap.nextSessionMinutes)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Break

    private func breakContent(_ state: BreakState) -> some View {
        let remaining = state.remaining(now: now)
        let fraction = state.plannedDuration > 0 ? remaining / state.plannedDuration : 0
        let backAt = now.addingTimeInterval(remaining)

        return VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Theme.control, lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: CGFloat(fraction))
                        .stroke(Color.primary.opacity(0.78), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 1) {
                        Text("back at")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(clock(backAt))
                            .font(.system(size: 22, weight: .semibold).monospacedDigit())
                            .kerning(-0.4)
                    }
                }
                .frame(width: 120, height: 120)
                .padding(.top, 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Break, \(formatMinutes(remaining)) left, back at \(clock(backAt))")

                Text(BreakTips.tip(for: state.startedAt))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .menuModule()

            HStack(spacing: 6) {
                ControlPlatter(systemImage: "plus", title: "5 more min") {
                    appState.breakManager.extend(byMinutes: 5)
                }
                ControlPlatter(systemImage: "stop.fill", title: "End break") {
                    appState.breakManager.skip()
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Permissions

    private var permissionModule: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("FocusGuard needs a couple of permissions to see what you're working on.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .labelStyle(.titleAndIcon)
            HStack(spacing: 6) {
                CapsuleButton(title: "Set up…", prominent: true, height: 28) {
                    dismiss()
                    NotificationCenter.default.post(name: .showOnboarding, object: nil)
                }
                CapsuleButton(title: "Recheck", prominent: false, height: 28) {
                    Task { await permissions.refresh() }
                }
            }
        }
        .menuModule(tint: Theme.warning)
    }

    // MARK: - Menu items

    private func menuItems(for phase: MenuPhase) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuSeparator().padding(.top, 2)
            if case .ready = phase {} else {
                Text("Today · \(formatMinutes(appState.todayBreakdown.focus)) focused")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
            }
            MenuItemRow(title: "Open FocusGuard") {
                dismiss()
                onOpenMain(.home)
            }
            MenuItemRow(title: "Settings…", shortcut: "⌘,") {
                dismiss()
                onOpenMain(.settings)
            }
            MenuSeparator()
            MenuItemRow(title: "Quit FocusGuard", shortcut: "⌘Q") {
                appState.tracker.flush()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: - Formatting

    private func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func formatMinutes(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds)) / 60
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}

// MARK: - Break tips

enum BreakTips {
    static let all = [
        "Stand up and look 20 feet away.",
        "Refill your water.",
        "Roll your shoulders and stretch your back.",
        "Step outside for a minute of daylight.",
        "Close your eyes and take five slow breaths.",
    ]

    /// Stable for the length of one break.
    static func tip(for startedAt: Date) -> String {
        all[Int(startedAt.timeIntervalSince1970 / 60) % all.count]
    }
}
