import SwiftUI

/// Home tab — same content shape as the menu bar popover (hero focus minutes,
/// week strip, now card, session controls), laid out for the standalone
/// window. Lets users who can't easily reach the menu bar (notch / packed bar
/// / no Bartender) drive the whole app from a regular window instead.
struct HomeView: View {
    @Bindable var appState: AppState

    @State private var now: Date = .now
    @State private var selectedDuration: SessionDurationChoice = .min50
    @State private var showingCustomDuration = false
    @State private var customMinutes = 30
    @State private var showingOnboarding = false

    @AppStorage(SessionDefaultsKey.label) private var defaultLabel = "Deep work"

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var snapshot: ActivitySnapshot? { appState.tracker.currentSnapshot }
    private var session: Session? { appState.sessionManager.currentSession }
    private var permissions: PermissionsCoordinator { appState.permissions }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !permissions.allGranted {
                    permissionWarning
                }
                hero
                Divider().background(Theme.separator)
                nowSection
                sessionSection
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onReceive(ticker) { now = $0 }
        .task { await permissions.refresh() }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView(permissions: permissions) {
                showingOnboarding = false
            }
        }
        .sheet(isPresented: $showingCustomDuration) {
            CustomDurationSheet(minutes: $customMinutes) { minutes in
                showingCustomDuration = false
                if let minutes {
                    selectedDuration = .custom
                    appState.sessionManager.startSession(
                        label: defaultLabel.isEmpty ? nil : defaultLabel,
                        plannedDurationMinutes: minutes
                    )
                }
            }
        }
    }

    // MARK: - Permission warning

    private var permissionWarning: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text("Permissions needed")
                    .font(.system(size: 14, weight: .semibold))
                Text("Grant Accessibility, Screen Recording, and Apple Events to enable full tracking.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Onboarding") { showingOnboarding = true }
                .buttonStyle(.borderedProminent)
                .tint(Theme.warning)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Theme.warning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(Theme.warning.opacity(0.35), lineWidth: 0.5)
        )
    }

    // MARK: - Hero

    private var hero: some View {
        let breakdown = appState.todayBreakdown
        let secs = Int(breakdown.focus)
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let pct = Int((breakdown.focusPercent * 100).rounded())

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("FOCUS TODAY")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                deltaPill
            }

            HStack(alignment: .lastTextBaseline, spacing: 12) {
                heroNumber(h, unit: "h")
                Text("·")
                    .font(.system(size: 56, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.18))
                heroNumber(m, unit: "m")
                Spacer().frame(width: 12)
                Text("\(pct)%")
                    .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.top, 4)

            goalProgress(breakdown: breakdown).padding(.top, 10)
            splitBar(breakdown: breakdown).padding(.top, 12)
            weekStrip.padding(.top, 16)
        }
    }

    /// Daily focus goal progress bar — same idea as the popover, larger.
    private func goalProgress(breakdown: BreakdownSnapshot) -> some View {
        let goalMin = FocusGoal.dailyMinutes
        let focusMin = Int(breakdown.focus / 60)
        let progress = FocusGoal.progress(focusSecondsToday: breakdown.focus)
        let pct = Int((progress * 100).rounded())
        let hit = focusMin >= goalMin
        let tint: Color = hit ? Theme.focus : Theme.focus.opacity(0.7)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("\(FocusGoal.format(minutes: focusMin)) of \(FocusGoal.format(minutes: goalMin)) goal")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(hit ? "✓ goal hit" : "\(pct)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(hit ? Theme.focus : .secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.fill1)
                    Rectangle().fill(tint)
                        .frame(width: geo.size.width * CGFloat(progress))
                }
            }
            .frame(height: 5)
            .clipShape(RoundedRectangle(cornerRadius: 2.5))
        }
    }

    private func heroNumber(_ value: Int, unit: String) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text("\(value)")
                .font(.system(size: 56, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.focus)
                .kerning(-1.6)
            Text(unit)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var deltaPill: some View {
        let avg = appState.weeklyAverageFocusSeconds
        let delta = appState.todayBreakdown.focus - avg
        let sign = delta >= 0 ? "+" : "−"
        let color: Color = abs(delta) < 60 ? .secondary : (delta >= 0 ? Theme.focus : Theme.distraction)
        return HStack(spacing: 4) {
            Text("\(sign)\(formatHM(abs(delta)))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
            Text("vs 7-day avg")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .opacity(avg < 60 ? 0 : 1)
    }

    private func splitBar(breakdown: BreakdownSnapshot) -> some View {
        let total = max(breakdown.total, 1)
        return GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle().fill(Theme.focus)
                    .frame(width: geo.size.width * CGFloat(breakdown.focus / total))
                Rectangle().fill(Theme.neutral)
                    .frame(width: geo.size.width * CGFloat(breakdown.neutral / total))
                Rectangle().fill(Theme.distraction)
                    .frame(width: geo.size.width * CGFloat(breakdown.distraction / total))
            }
        }
        .frame(height: 8)
        .background(Theme.fill1)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var weekStrip: some View {
        let week = appState.weekTrackedSeconds
        let max = week.max() ?? 1
        let dayLetters = ["M", "T", "W", "T", "F", "S", "S"]
        return VStack(alignment: .leading, spacing: 8) {
            Text("THIS WEEK")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(0..<7, id: \.self) { i in
                    let isToday = (i == 6)
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottom) {
                            Color.clear.frame(height: 56)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isToday ? Theme.focus : Theme.fill2)
                                .frame(height: barHeight(week[i], max: max))
                        }
                        Text(dayLetters[i])
                            .font(.system(size: 11, weight: isToday ? .semibold : .regular))
                            .foregroundStyle(isToday ? Color.primary : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func barHeight(_ value: TimeInterval, max: TimeInterval) -> CGFloat {
        guard max > 0 else { return 0 }
        return CGFloat(Swift.max(2, value / max * 56))
    }

    // MARK: - Now

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                PulsingDot(color: .accentColor, size: 8)
                Text("NOW")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
            }
            NowCard(snapshot: snapshot)
        }
    }

    // MARK: - Session controls

    @ViewBuilder
    private var sessionSection: some View {
        if let session {
            runningSessionRow(session: session)
        } else {
            startSessionRow
        }
    }

    private var startSessionRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("START A FOCUS SESSION")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                HStack(spacing: 0) {
                    ForEach([SessionDurationChoice.min25, .min50, .min90, .custom], id: \.self) { dur in
                        Button {
                            if dur == .custom {
                                showingCustomDuration = true
                            } else {
                                selectedDuration = dur
                            }
                        } label: {
                            Group {
                                if dur == .custom {
                                    Image(systemName: "clock")
                                        .font(.system(size: 14))
                                } else {
                                    Text(dur.shortLabel)
                                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                                }
                            }
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                selectedDuration == dur ? Theme.cardBackground : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Theme.fill1, in: RoundedRectangle(cornerRadius: 9))

                Button {
                    appState.sessionManager.startSession(
                        label: defaultLabel.isEmpty ? nil : defaultLabel,
                        plannedDurationMinutes: selectedDuration.minutes
                    )
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Start")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func runningSessionRow(session: Session) -> some View {
        let elapsed = appState.sessionManager.runningSeconds(for: session, now: now)
        let planned = session.plannedDurationMinutes.map { TimeInterval($0 * 60) }
        let isPaused = session.pausedAt != nil
        let label = session.label

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("SESSION")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                if isPaused {
                    Text("PAUSED")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(Theme.warning)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.warning.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                }
                if let label, !label.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(label)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(formatHMS(elapsed))
                    .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                if let planned {
                    Text("of \(formatHMS(planned))")
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Button {
                    if isPaused {
                        appState.sessionManager.resumeSession()
                    } else {
                        appState.sessionManager.pauseSession()
                    }
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    appState.sessionManager.stopSession()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                        Text("Stop")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.distraction)
            }

            if let planned {
                ProgressView(value: min(1, elapsed / planned))
                    .progressViewStyle(.linear)
                    .tint(isPaused ? Theme.warning : .accentColor)
            }
        }
    }

    // MARK: - Formatting

    private func formatHM(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    private func formatHMS(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
