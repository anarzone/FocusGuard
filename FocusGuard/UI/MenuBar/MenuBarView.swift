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

    /// Length of the next session, set on the dial or the ruler.
    @State private var minutes: Int = 50
    @State private var now: Date = .now
    /// Side pane slid out next to the session column, if any.
    @State private var openPane: MenuPane?
    /// The music pane, slid out on the column's left.
    @State private var musicOpen = false
    /// The column's height. The music pane is held to it, so the player
    /// never makes the menu taller than the column and leaves space under it.
    @State private var columnHeight: CGFloat = 0
    @AppStorage(SessionDefaultsKey.label) private var defaultLabel = "Deep work"
    @AppStorage(SessionDefaultsKey.durationMinutes) private var defaultMinutes = 50
    /// The picker opens on the last length the user started with.
    @AppStorage("menu.lastSessionMinutes") private var lastSessionMinutes = 0

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let phase = appState.menuPhase(now: now)

        HStack(alignment: .top, spacing: 6) {
            if musicOpen {
                MusicPane(music: appState.music, now: now, inSession: appState.sessionManager.currentSession != nil) {
                    musicOpen = false
                }
                .frame(height: columnHeight > 0 ? columnHeight : nil)
                .transition(MenuPane.slide(from: .leading))
            }

        VStack(alignment: .leading, spacing: 6) {
            header(for: phase)
                .zIndex(1)   // the music button's now-playing bubble sits over the modules below

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
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { columnHeight = $0 }

            if let pane = openPane {
                MenuPaneView(pane: pane, appState: appState, onOpenMain: onOpenMain, dismiss: dismiss) {
                    openPane = nil
                }
                .transition(MenuPane.slide(from: .trailing))
            }
        }
        .padding(6)
        .preference(key: MenuLeadingExtensionKey.self, value: musicOpen ? MusicPane.width + 6 : 0)
        .task { await permissions.refresh() }
        .onAppear(perform: restoreLength)
        .onAppear { appState.refreshMenuStats(force: true) }
        .onReceive(ticker) { tick in
            now = tick
            // Never waits: the numbers come back from StatsStore.
            appState.refreshMenuStats()
            // Follow Spotify while the music pane is open, and in a session for
            // the header's playing indicator.
            let music = appState.music
            if musicOpen {
                music.player.refresh(every: 1)
            } else if appState.sessionManager.currentSession != nil {
                music.player.refresh()
            }
            if let owner = music.sessionService, owner != music.service {
                music.player(for: owner).refresh()
            }
            if musicOpen && music.service == .spotify {
                music.refreshSpotifyContext()
            }
        }
    }

    // MARK: - Header

    /// Buttons and title on one row, the subtitle on its own row below so it
    /// never truncates. The music button sits on the left, the side its pane
    /// opens from; the other panes' buttons on the right.
    private func header(for phase: MenuPhase) -> some View {
        let (glyph, tint, title, subtitle) = headerContent(for: phase)
        let hasMusic = !appState.music.availableServices.isEmpty
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                if hasMusic {
                    MusicButton(isOpen: $musicOpen, track: appState.music.player.nowPlaying)
                }
                StatusGlyphView(state: glyph, tint: tint, size: 20)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                PaneButtons(open: $openPane)
            }
            .zIndex(1)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, (hasMusic ? 36 : 0) + 28)
        }
        .padding(.leading, hasMusic ? 4 : 10)
        .padding(.trailing, 4)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func headerContent(for phase: MenuPhase) -> (StatusGlyphState, Color, String, String) {
        switch phase {
        case .ready:
            let streak = appState.menuStats.streak
            return (.ready, Theme.focus, "FocusGuard",
                    streak >= 2 ? "\(streak)-day streak · ready when you are" : "Ready when you are")

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

            VStack(spacing: 10) {
                TwistDial(minutes: $minutes) { dialCenter }
                LengthRuler(minutes: $minutes)
            }
            .padding(.top, 4)
            .menuModule()

            CapsuleButton(title: "Start \(lengthText(minutes)) of focus", prominent: true) { start() }
                .padding(.horizontal, 4)
                .padding(.top, 4)
                .padding(.bottom, 2)

            NowRow(snapshot: appState.tracker.currentSnapshot)
        }
    }

    /// Today so far on a timeline, with where the session being set up would land.
    private var todayModule: some View {
        let focus = appState.menuStats.today.focus
        let progress = FocusGoal.progress(focusSecondsToday: focus)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatMinutes(focus))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .kerning(-0.4)
                Text("focused today")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(Int((progress * 100).rounded()))% of \(FocusGoal.format(minutes: FocusGoal.dailyMinutes))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            DayStripView(spans: appState.menuStats.spans, now: now, previewMinutes: Double(minutes))
                .animation(.spring(response: 0.32, dampingFraction: 0.88), value: minutes)
        }
        .menuModule()
    }

    /// The length in the dial's middle, with when it would end.
    private var dialCenter: some View {
        let long = minutes >= 120
        let big = long ? String(format: "%d:%02d", minutes / 60, minutes % 60) : "\(minutes)"
        return VStack(spacing: 0) {
            Text(big)
                .font(.system(size: 38, weight: .semibold).monospacedDigit())
                .kerning(-0.8)
                .contentTransition(.numericText(value: Double(minutes)))
                .animation(.snappy(duration: 0.2), value: minutes)
            Text(long ? "hours" : "min")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text("ends \(clock(now.addingTimeInterval(TimeInterval(minutes * 60))))")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
        }
        .offset(y: -3)
        .allowsHitTesting(false)
    }

    /// "50 minutes", or "2h 30m" from two hours.
    private func lengthText(_ minutes: Int) -> String {
        minutes < 120 ? "\(minutes) minutes" : FocusGoal.format(minutes: minutes)
    }

    private func restoreLength() {
        let saved = lastSessionMinutes > 0 ? lastSessionMinutes : defaultMinutes
        minutes = min(RulerMath.range.upperBound, max(RulerMath.range.lowerBound, saved))
    }

    private func start() {
        lastSessionMinutes = minutes
        appState.sessionManager.startSession(
            label: defaultLabel.isEmpty ? nil : defaultLabel,
            plannedDurationMinutes: minutes
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
                    secondsSweep: isPaused ? nil : SessionClock.sweep(elapsed: elapsed),
                    stretchDetail: { segment in
                        SessionTimeline.stretch(cells: segment.cells, kind: segment.kind, in: timeline,
                                                events: session.events, now: now)
                    }
                ) {
                    ringCenter(session: session, elapsed: elapsed, isPaused: isPaused)
                }
                RingLegend(trailing: timeline.classifiedCells > 0 ? "\(timeline.focusPercent)% focused" : nil)
            }
            .padding(.top, 4)
            .menuModule()

            ZoneModule(runs: runs, bestToday: appState.menuStats.bestZone, drifting: drift != nil)

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
                SessionRingView(timeline: timeline, progress: nil, stretchDetail: { segment in
                    SessionTimeline.stretch(cells: segment.cells, kind: segment.kind, in: timeline,
                                            events: recap.session.events)
                }) {
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
                Text("Today · \(formatMinutes(appState.menuStats.today.focus)) focused")
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
