import SwiftUI

/// The rich menu under the status item. One phase at a time — ready, in a
/// session (maybe drifted, paused or on a call), just finished, or on a
/// break — then the native menu items. Laid out like a macOS menu: a 6pt
/// inset glass panel holding concentric rounded modules, circular control
/// platters, and plain rows.
struct MenuBarView: View {
    @Bindable var permissions: PermissionsCoordinator
    @Bindable var appState: AppState
    var onOpenMain: (MainTab) -> Void = { _ in }
    var dismiss: () -> Void = {}

    /// The recap whose length seeded `minutes`, so it's only done once.
    @State private var seededRecap: Date?
    /// Length of the next session, set on the ruler.
    @State private var minutes: Int = 50
    @State private var now: Date = .now
    /// Side pane slid out next to the session column, if any.
    @State private var openPane: MenuPane?
    /// The music pane, slid out on the column's left.
    @State private var musicOpen = false
    /// The column's height. The music pane is held to it, so the player
    /// never makes the menu taller than the column and leaves space under it.
    @State private var columnHeight: CGFloat = 0
    /// An offer or a used-up limit folds the length picker away; this opens it.
    @State private var pickingLength = false
    @ReduceMotion private var reduceMotion
    @AppStorage(SessionDefaultsKey.label) private var defaultLabel = ""
    @AppStorage(SessionDefaultsKey.durationMinutes) private var defaultMinutes = 50
    /// The picker opens on the last length the user started with.
    @AppStorage("menu.lastSessionMinutes") private var lastSessionMinutes = 0
    /// What the next session is for (Pro AI, behind `FeatureFlags.debrief`).
    @AppStorage(SessionGoal.key) private var sessionGoal = ""
    var entitlements: Entitlements = .shared

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let phase = appState.menuPhase(now: now)

        HStack(alignment: .top, spacing: 6) {
            if musicOpen {
                MusicPane(music: appState.music, now: now, inSession: appState.sessionManager.currentSession != nil) {
                    musicOpen = false
                }
                .frame(height: columnHeight > 0 ? columnHeight : nil)
                .transition(MenuPane.slide(from: .leading, reduceMotion: reduceMotion))
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
                MenuPaneView(pane: pane, appState: appState, onOpenMain: onOpenMain, dismiss: dismiss,
                             open: { openPane = $0 }) {
                    openPane = nil
                }
                .transition(MenuPane.slide(from: .trailing, reduceMotion: reduceMotion))
            }
        }
        .padding(6)
        .preference(key: MenuLeadingExtensionKey.self, value: musicOpen ? MusicPane.width + 6 : 0)
        .task { await permissions.refresh() }
        .onAppear(perform: restoreLength)
        .onAppear { appState.refreshMenuStats(force: true) }
        .onChange(of: appState.habits.autoStartOffer) { pickingLength = false }
        .onChange(of: appState.sessionManager.currentSession?.id) { pickingLength = false }
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
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .padding(.leading, (hasMusic ? 36 : 0) + 28)
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func headerContent(for phase: MenuPhase) -> (StatusGlyphState, Color, String, String) {
        switch phase {
        case .ready:
            return (.ready, Theme.focus, "FocusGuard", readySubtitle)

        case .onBreak(let state):
            let backAt = now.addingTimeInterval(state.remaining(now: now))
            return (.onBreak, Theme.focus, "Break", "Back at \(menuClock(backAt)) · blocking paused")

        case .recap(let recap):
            return (.complete, Theme.focus, recap.label,
                    "Session complete · \(menuClock(recap.startedAt))–\(menuClock(recap.endedAt))")

        case .session(let session, let drift):
            let label = session.displayName
            let planned = session.plannedDurationMinutes
            let elapsed = appState.sessionManager.runningSeconds(for: session, now: now)
            let length = planned.map { "\($0)-minute session" } ?? "Open-ended"

            if session.pausedAt != nil {
                let left = planned.map {
                    " · \(counted(AppState.minutesRoundedUp(Double($0 * 60) - elapsed), "min", plural: "min")) left"
                } ?? ""
                return (.paused, Theme.neutral, label, "Paused\(left)")
            }
            if let drift {
                return (.drifted, Theme.distractionInk, label, "Drifted to \(drift.displayName) · \(length)")
            }
            return (.focusing(elapsed: elapsed, planned: planned.map { Double($0 * 60) }),
                    Theme.focus, label, "\(length) · started \(menuClock(session.startedAt))")
        }
    }

    private var readySubtitle: String {
        let streak = appState.menuStats.streak
        let streakText = streak >= 2 ? "\(streak)-day streak" : nil
        if goalMet {
            return ["Goal met today", streakText].compactMap { $0 }.joined(separator: " · ")
        }
        return streakText.map { "\($0) · ready when you are" } ?? "Ready when you are"
    }

    private var goalMet: Bool {
        FocusGoal.progress(focusSecondsToday: appState.menuStats.today.focus) >= 1
    }

    // MARK: - Ready

    private var readyContent: some View {
        let limit = appState.menuLimit()
        let offer = appState.habits.autoStartOffer
        let folded = !pickingLength && (offer != nil || limit?.isUsedUp == true)

        return VStack(alignment: .leading, spacing: 6) {
            if let limit {
                LimitModule(status: limit, policy: appState.escalationEngine.policy,
                            pausesTab: appState.limitPausesTab(limit), now: now,
                            onExtraTime: { appState.limits.takeExtraTime(for: limit.id) },
                            onChange: { openPane = .settings })
                    .id(limit.id)
            }

            if let offer {
                AutoStartModule(offer: offer, minutes: offerMinutes(offer), now: now,
                                onStart: { appState.acceptAutoStartOffer(minutes: offerMinutes(offer)) },
                                onNotNow: { appState.habits.dismissAutoStartOffer() },
                                onStop: { appState.habits.stopOfferingAutoStart() })
            }

            todayModule(offer: folded ? offer : nil, preview: !folded || offer != nil)

            if folded {
                if offer != nil {
                    MenuLinkRow(title: "Pick a length and start fresh") { pickingLength = true }
                } else {
                    CapsuleButton(title: "Start a session", prominent: false) { pickingLength = true }
                        .padding(.horizontal, 4)
                }
            } else {
                if FeatureFlags.debrief {
                    if entitlements.isUnlocked(.debrief) {
                        SessionGoalField(goal: $sessionGoal)
                    } else {
                        LockedProRow(feature: .debrief, title: "Add a goal for this session",
                                     detail: "Say what the session is for. When it ends, the debrief checks whether you got there.",
                                     systemImage: "scope")
                    }
                }

                LengthModule(minutes: $minutes, now: now)

                CapsuleButton(title: "Start \(lengthText(minutes)) of focus", prominent: true) { start() }
                    .padding(.horizontal, 4)
            }

            NowRow(snapshot: appState.tracker.currentSnapshot, reachedLimit: limit?.isUsedUp == true ? limit : nil)
        }
    }

    /// An offer starts the usual length, never shorter than the time it counts.
    private func offerMinutes(_ offer: AutoStartOffer) -> Int {
        max(minutes, RulerMath.snap(Double(offer.focusMinutes(now: now) + 10)))
    }

    /// Today so far on a timeline, with where the session being set up (or
    /// offered) would land.
    private func todayModule(offer: AutoStartOffer?, preview: Bool) -> some View {
        let focus = appState.menuStats.today.focus
        let progress = FocusGoal.progress(focusSecondsToday: focus)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatMinutes(focus))
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .kerning(-0.44)
                Text("focused today")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 0)
                Text(progress >= 1 ? "goal met"
                     : "\(Int((progress * 100).rounded()))% of \(FocusGoal.format(minutes: FocusGoal.dailyMinutes))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            .accessibilityElement(children: .combine)

            DayStripView(spans: appState.menuStats.spans, now: now,
                         previewMinutes: preview ? Double(offer.map(offerMinutes) ?? minutes) : 0,
                         previewStart: offer?.since)
                .animation(.spring(response: 0.32, dampingFraction: 0.88), value: minutes)
        }
        .menuModule(padding: EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14))
    }

    /// "50 minutes", or "2h 30m" from two hours.
    private func lengthText(_ minutes: Int) -> String {
        minutes < 120 ? "\(minutes) minutes" : FocusGoal.format(minutes: minutes)
    }

    private func restoreLength() {
        let saved = CoachRules.sessionMinutes() ?? (lastSessionMinutes > 0 ? lastSessionMinutes : defaultMinutes)
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
        let call = appState.habits.currentCall

        return VStack(alignment: .leading, spacing: 6) {
            if let call {
                CallModule(call: call, paused: isPaused) { appState.pauseUntilCallEnds() }
            } else if let drift {
                DriftModule(drift: drift, now: now, policy: appState.escalationEngine.policy,
                            backTo: appState.backToAppName(),
                            onBack: {
                                appState.backToWork()
                                dismiss()
                            },
                            onForWork: { appState.allowCurrentDriftForSession() })
            }

            VStack(spacing: 12) {
                if FeatureFlags.debrief, entitlements.isUnlocked(.debrief), !sessionGoal.isEmpty {
                    GoalLine(goal: sessionGoal)
                }
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
                RingLegend(trailing: timeline.focusCells + timeline.driftCells > 0
                           ? "\(timeline.focusPercent)% focus rate" : nil)
            }
            .padding(.top, 2)
            .menuModule()

            if call == nil {
                ZoneModule(runs: runs, bestToday: appState.menuStats.bestZone, drifting: drift != nil, paused: isPaused)
            }

            HStack(spacing: 6) {
                if isPaused {
                    ControlPlatter(systemImage: "play.fill", title: "Resume", prominent: true) {
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
            .padding(.top, 2)
            .padding(.bottom, 4)

            if drift == nil && call == nil {
                NowRow(snapshot: appState.tracker.currentSnapshot,
                       note: isPaused ? "Counts outside the session" : nil)
            }
        }
    }

    /// Live clock: time left counting down (or elapsed counting up for
    /// open-ended sessions), with the end time underneath. Paused, the
    /// digits go grey and say since when.
    private func ringCenter(session: Session, elapsed: TimeInterval, isPaused: Bool) -> some View {
        let big: String
        let unit: String
        let detail: String
        if let planned = session.plannedDurationMinutes {
            let left = max(0, Double(planned * 60) - elapsed)
            big = SessionClock.format(left)
            unit = isPaused ? "paused" : "left"
            detail = isPaused ? pausedSince(session) : "ends \(menuClock(now.addingTimeInterval(left)))"
        } else {
            big = SessionClock.format(elapsed)
            unit = isPaused ? "paused" : "elapsed"
            detail = isPaused ? pausedSince(session) : "open-ended"
        }
        return VStack(spacing: 0) {
            Text(big)
                .font(.system(size: big.count > 5 ? 30 : 38, weight: .semibold).monospacedDigit())
                .kerning(-1.1)
                .foregroundStyle(isPaused ? Theme.secondaryText : Theme.primaryText)
                .contentTransition(.numericText(countsDown: session.plannedDurationMinutes != nil))
                .animation(.snappy(duration: 0.25), value: big)
            Text(unit)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 4)
            Text(detail)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }

    private func pausedSince(_ session: Session) -> String {
        session.pausedAt.map { "since \(menuClock($0))" } ?? "paused"
    }

    // MARK: - Recap

    private func recapContent(_ recap: SessionRecap) -> some View {
        let timeline = recap.timeline
        let m = timeline.minutesPerCell
        return VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 12) {
                SessionRingView(timeline: timeline, progress: nil, stretchDetail: { segment in
                    SessionTimeline.stretch(cells: segment.cells, kind: segment.kind, in: timeline,
                                            events: recap.session.events)
                }) {
                    VStack(spacing: 0) {
                        Text("\(timeline.focusPercent)%")
                            .font(.system(size: 40, weight: .semibold).monospacedDigit())
                            .kerning(-1.2)
                        Text("focus rate")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.top, 4)
                        Text("other time left out")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                }
                RingLegend(counts: (timeline.focusCells * m, timeline.driftCells * m, timeline.otherCells * m))
            }
            .menuModule(padding: EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))

            HStack(spacing: 0) {
                stat("Longest in the zone") {
                    Text("\(Int(recap.longestZone / 60)) min")
                }
                Rectangle().fill(Theme.moduleStroke).frame(width: 0.5)
                stat("Most drift") {
                    if let top = recap.topDrift {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.distraction).frame(width: 7, height: 7)
                            Text("\(top.name) · \(max(1, Int((top.seconds / 60).rounded()))) min")
                                .truncationMode(.middle)
                        }
                    } else {
                        Text("None")
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.module))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))

            if FeatureFlags.debrief {
                if entitlements.isUnlocked(.debrief) {
                    ProRow(title: "Debrief is ready", detail: "What you did, where you drifted, a tip") { openPane = .debrief }
                } else {
                    LockedProRow(feature: .debrief, title: "Debrief this session",
                                 detail: "What you did, where you drifted, and one thing to try next time.",
                                 systemImage: "sparkles")
                }
            }

            HStack {
                Text("Up next")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primaryText.opacity(0.85))
                Spacer()
                // Back to the ready screen and its ruler now, instead of
                // waiting for the recap to go stale.
                PillButton(title: "Done", height: 22) { appState.recap = nil }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.top, 4)

            VStack(spacing: 6) {
                CapsuleButton(title: "Take a \(recap.suggestedBreakMinutes)-minute break", prominent: true) {
                    appState.startBreak(durationMinutes: recap.suggestedBreakMinutes)
                }
                // Any length for the next one, on the same ruler as the ready screen.
                VStack(spacing: 4) {
                    LengthRuler(minutes: $minutes)
                    CapsuleButton(title: "Start \(lengthText(minutes))", prominent: false, height: 32, semibold: true) {
                        lastSessionMinutes = minutes
                        appState.sessionManager.startSession(label: recap.session.label, plannedDurationMinutes: minutes)
                    }
                }
                .menuModule(padding: EdgeInsets(top: 2, leading: 8, bottom: 8, trailing: 8))
            }
            .padding(.horizontal, 4)
            .onAppear { seedNextLength(from: recap) }
        }
    }

    /// The recap's ruler starts on the length of the session just finished,
    /// once per recap, so reopening the menu keeps what the user dragged to.
    private func seedNextLength(from recap: SessionRecap) {
        guard seededRecap != recap.startedAt else { return }
        seededRecap = recap.startedAt
        minutes = min(RulerMath.range.upperBound, max(RulerMath.range.lowerBound, recap.nextSessionMinutes))
    }

    private func stat<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            value()
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Break

    private func breakContent(_ state: BreakState) -> some View {
        let remaining = state.remaining(now: now)
        let fraction = state.plannedDuration > 0 ? remaining / state.plannedDuration : 0
        let backAt = now.addingTimeInterval(remaining)
        let next = CoachRules.sessionMinutes() ?? (lastSessionMinutes > 0 ? lastSessionMinutes : defaultMinutes)

        return VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Theme.focusTint, lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: CGFloat(fraction))
                        .stroke(Theme.focus, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(SessionClock.format(remaining))
                            .font(.system(size: 34, weight: .semibold).monospacedDigit())
                            .kerning(-1)
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.snappy(duration: 0.25), value: Int(remaining))
                        Text("left")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.top, 4)
                    }
                }
                .padding(5)
                .frame(width: 144, height: 144)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Break, \(formatMinutes(remaining)) left, back at \(menuClock(backAt))")

                HStack(spacing: 10) {
                    Image(systemName: "sun.max")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.focus)
                        .accessibilityHidden(true)
                    Text(BreakTips.tip(for: state.startedAt))
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardBackground))
            }
            .frame(maxWidth: .infinity)
            .menuModule(padding: EdgeInsets(top: 18, leading: 14, bottom: 16, trailing: 14))

            HStack(spacing: 6) {
                ControlPlatter(systemImage: "wind", title: "Breathe") {
                    appState.breakOverlay.present(breakManager: appState.breakManager)
                    dismiss()
                }
                ControlPlatter(systemImage: "plus", title: "5 more min") {
                    appState.breakManager.extend(byMinutes: 5)
                }
                if appState.breakManager.canEndEarly {
                    ControlPlatter(systemImage: "stop.fill", title: "End break") {
                        appState.breakManager.skip()
                    }
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 4)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("After the break")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                    Text("Another \(lengthText(next))")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if appState.breakManager.canEndEarly {
                    PillButton(title: "Start now") {
                        appState.breakManager.skip()
                        lastSessionMinutes = next
                        appState.sessionManager.startSession(label: defaultLabel.isEmpty ? nil : defaultLabel,
                                                             plannedDurationMinutes: next)
                    }
                }
            }
            .menuModule(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
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
                CapsuleButton(title: "Recheck", prominent: false, height: 28, fill: MenuPalette.onTint) {
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
                Text("Today · \(formatMinutes(appState.menuStats.today.focus)) focused\(goalMet ? " · goal met" : "")")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
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
        "Stand up and look out of a window for a minute.",
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
