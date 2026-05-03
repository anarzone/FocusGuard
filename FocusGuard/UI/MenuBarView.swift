import SwiftUI

// MARK: - Session duration choice

enum SessionDurationChoice: Hashable, CaseIterable {
    case min25, min50, min90, custom

    var minutes: Int? {
        switch self {
        case .min25: return 25
        case .min50: return 50
        case .min90: return 90
        case .custom: return nil
        }
    }
    var shortLabel: String {
        switch self {
        case .min25: return "25m"
        case .min50: return "50m"
        case .min90: return "90m"
        case .custom: return ""
        }
    }
}

// MARK: - MenuBarView (Glanceable variant)

struct MenuBarView: View {
    @Bindable var permissions: PermissionsCoordinator
    @Bindable var appState: AppState
    var onOpenMain: (MainTab) -> Void = { _ in }

    @State private var showingOnboarding = false
    @State private var showingCustomDuration = false
    @State private var customMinutes: Int = 30
    @State private var now: Date = .now
    @State private var selectedDuration: SessionDurationChoice = .min50
    @AppStorage(SessionDefaultsKey.label) private var defaultLabel = "Deep work"

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var snapshot: ActivitySnapshot? { appState.tracker.currentSnapshot }
    private var session: Session? { appState.sessionManager.currentSession }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !permissions.allGranted {
                permissionWarning
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
            }

            heroSection
            sectionDivider
            nowSection
            sectionDivider
            sessionSection
            actionRow
        }
        .frame(width: 360)
        // No SwiftUI-level background. The popover's NSVisualEffectView
        // wrapper (configured in MenuBarController.configurePopover) provides
        // the backdrop edge-to-edge, including the rounded corner regions.
        .task { await permissions.refresh() }
        .onReceive(ticker) { now = $0 }
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("FocusGuard")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 5) {
                    PulsingDot(color: .accentColor, size: 6)
                    Text(statusSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 0.5)
        }
    }

    private var statusSubtitle: String {
        if session != nil {
            return "Session · \(formatHM(now.timeIntervalSince(session!.startedAt)))"
        }
        return "Tracking · \(formatHM(appState.todayTrackedSeconds))"
    }

    // MARK: - Permissions banner

    private var permissionWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Permissions needed").fontWeight(.semibold).font(.system(size: 12))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
            }
            .foregroundStyle(Theme.warning)

            HStack(spacing: 6) {
                Button("Open onboarding") { showingOnboarding = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.warning)
                Button("Recheck") { Task { await permissions.refresh() } }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Theme.warning.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(Theme.warning.opacity(0.35), lineWidth: 0.5)
        )
    }

    // MARK: - Hero

    private var heroSection: some View {
        let breakdown = appState.todayBreakdown

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("FOCUS TODAY")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                deltaPill
            }
            .padding(.bottom, 4)

            HStack(alignment: .lastTextBaseline, spacing: 0) {
                let secs = Int(breakdown.focus)
                let h = secs / 3600
                let m = (secs % 3600) / 60
                heroNumber(h, unit: "h")
                Spacer().frame(width: 6)
                heroNumber(m, unit: "m")
                Spacer()
                focusPercentPill(breakdown: breakdown)
            }

            weekStrip.padding(.top, 12)

            splitBar(breakdown: breakdown).padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func focusPercentPill(breakdown: BreakdownSnapshot) -> some View {
        let pct = Int((breakdown.focusPercent * 100).rounded())
        return Text("\(pct)% focused")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(Theme.focus)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.focusTint, in: RoundedRectangle(cornerRadius: 6))
    }

    private func splitBar(breakdown: BreakdownSnapshot) -> some View {
        let total = max(breakdown.total, 1)
        let focusFraction = CGFloat(breakdown.focus / total)
        let neutralFraction = CGFloat(breakdown.neutral / total)
        let distractionFraction = CGFloat(breakdown.distraction / total)

        return GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle().fill(Theme.focus)
                    .frame(width: geo.size.width * focusFraction)
                Rectangle().fill(Theme.neutral)
                    .frame(width: geo.size.width * neutralFraction)
                Rectangle().fill(Theme.distraction)
                    .frame(width: geo.size.width * distractionFraction)
            }
        }
        .frame(height: 6)
        .background(Theme.fill1)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func heroNumber(_ value: Int, unit: String) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .kerning(-1.2)
            Text(unit)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var deltaPill: some View {
        // Compare focus today vs average focus per day (last 6 days excluding today).
        // Matches the metric the hero number actually shows.
        let avg = appState.weeklyAverageFocusSeconds
        let delta = appState.todayBreakdown.focus - avg
        let sign = delta >= 0 ? "+" : "−"
        let color: Color = abs(delta) < 60 ? .secondary : (delta >= 0 ? Theme.focus : Theme.distraction)

        return HStack(spacing: 3) {
            Text("\(sign)\(formatHM(abs(delta)))")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
            Text("vs 7-day avg")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .help("Average focus minutes per day across the last 6 days, excluding today.")
        .opacity(avg < 60 ? 0 : 1)  // hide until we have any prior days
    }

    private var eventsPill: some View {
        Text("\(appState.todayEventCount) events")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(Theme.focus)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.focusTint, in: RoundedRectangle(cornerRadius: 6))
    }

    private var weekStrip: some View {
        let week = appState.weekTrackedSeconds
        let max = week.max() ?? 1
        let dayLetters = ["M", "T", "W", "T", "F", "S", "S"]

        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                let isToday = (i == 6)
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        Color.clear.frame(height: 28)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(isToday ? Theme.focus : Theme.fill2)
                            .frame(height: barHeight(week[i], max: max))
                    }
                    Text(dayLetters[i])
                        .font(.system(size: 9.5, weight: isToday ? .semibold : .regular))
                        .foregroundStyle(isToday ? Color.primary : Color.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func barHeight(_ value: TimeInterval, max: TimeInterval) -> CGFloat {
        guard max > 0 else { return 0 }
        let ratio = value / max
        return CGFloat(Swift.max(2, ratio * 28))
    }

    // MARK: - Now

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionCap("Now", showLive: true)
            NowCard(snapshot: snapshot)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Session controls (tight start, or running session)

    private var sessionSection: some View {
        Group {
            if let session {
                runningSessionRow(session: session)
            } else {
                tightStartRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var tightStartRow: some View {
        HStack(spacing: 8) {
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
                                    .font(.system(size: 11))
                            } else {
                                Text(dur.shortLabel)
                                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                            }
                        }
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            selectedDuration == dur ? Theme.cardBackground : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(dur == .custom ? "Custom duration…" : "")
                }
            }
            .padding(2)
            .background(Theme.fill1, in: RoundedRectangle(cornerRadius: 8))

            Button {
                appState.sessionManager.startSession(
                    label: defaultLabel.isEmpty ? nil : defaultLabel,
                    plannedDurationMinutes: selectedDuration.minutes
                )
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Start")
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func runningSessionRow(session: Session) -> some View {
        let elapsed = appState.sessionManager.runningSeconds(for: session, now: now)
        let planned = session.plannedDurationMinutes.map { TimeInterval($0 * 60) }
        let isPaused = session.pausedAt != nil

        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("SESSION")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(.secondary)
                        if isPaused {
                            Text("PAUSED")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.4)
                                .foregroundStyle(Theme.warning)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.warning.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(formatHMS(elapsed))
                            .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.primary)
                        if let planned {
                            Text("of \(formatHMS(planned))")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
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
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.space, modifiers: [])
                .help(isPaused ? "Resume session (Space)" : "Pause session (Space)")

                Button {
                    appState.sessionManager.stopSession()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Stop")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
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

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 0) {
            actionButton(systemImage: "chart.bar", title: "Reports") {
                onOpenMain(.reports)
            }
            actionDivider
            actionButton(systemImage: "gearshape", title: "Settings") {
                onOpenMain(.settings)
            }
            actionDivider
            actionButton(systemImage: "power", title: "Quit") {
                appState.tracker.flush()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.separator).frame(height: 0.5)
        }
    }

    private var actionDivider: some View {
        Rectangle().fill(Theme.separator).frame(width: 1, height: 14)
    }

    private func actionButton(systemImage: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section helpers

    private func sectionCap(_ title: String, showLive: Bool = false) -> some View {
        HStack(spacing: 6) {
            if showLive {
                PulsingDot(color: .accentColor, size: 6)
            }
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 6)
    }

    private var sectionDivider: some View {
        Rectangle().fill(Theme.separator).frame(height: 0.5)
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

// MARK: - NowCard

struct NowCard: View {
    let snapshot: ActivitySnapshot?

    var body: some View {
        HStack(spacing: 10) {
            if let snapshot {
                AppGlyph(
                    kind: AppGlyph.kind(forBundleId: snapshot.bundleIdentifier, name: snapshot.appName),
                    bundleId: snapshot.bundleIdentifier,
                    size: 36
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.appName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle(for: snapshot))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(fullDetail(for: snapshot))
                }
                Spacer()
                ClassificationBadge(classification: snapshot.classification)
            } else {
                AppGlyph(kind: .generic, size: 36)
                Text("Detecting…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill3, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    /// URL host > URL host+path > window title > bundle id.
    /// For browsers, the URL is the most informative thing; the window title
    /// is usually just "Page Title - Chrome" which duplicates the page.
    private func subtitle(for snapshot: ActivitySnapshot) -> String {
        if let urlString = snapshot.url, !urlString.isEmpty {
            if let url = URL(string: urlString), let host = url.host {
                let displayPath = url.path.count > 1 ? url.path : ""
                return host + displayPath
            }
            return urlString
        }
        if let title = snapshot.windowTitle, !title.isEmpty {
            return title
        }
        return snapshot.bundleIdentifier
    }

    /// Used as the help/tooltip — gives the full URL or title.
    private func fullDetail(for snapshot: ActivitySnapshot) -> String {
        if let url = snapshot.url, !url.isEmpty { return url }
        if let title = snapshot.windowTitle, !title.isEmpty { return title }
        return snapshot.bundleIdentifier
    }
}

// MARK: - ClassificationBadge

struct ClassificationBadge: View {
    let classification: Classification

    var body: some View {
        Text(label)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.3)
            .textCase(.uppercase)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint, in: RoundedRectangle(cornerRadius: 4))
    }

    private var label: String {
        switch classification {
        case .focus:       return "Focus"
        case .neutral:     return "Neutral"
        case .distraction: return "Distraction"
        }
    }

    private var color: Color {
        switch classification {
        case .focus:       return Theme.focus
        case .neutral:     return .secondary
        case .distraction: return Theme.distraction
        }
    }

    private var tint: Color {
        switch classification {
        case .focus:       return Theme.focusTint
        case .neutral:     return Theme.fill1
        case .distraction: return Theme.distractionTint
        }
    }
}

// MARK: - PulsingDot

struct PulsingDot: View {
    let color: Color
    let size: CGFloat
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color, lineWidth: 1.5)
                .opacity(pulse ? 0 : 0.6)
                .scaleEffect(pulse ? 1.6 : 0.8)
                .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
            Circle()
                .fill(color)
                .overlay(Circle().stroke(color.opacity(0.18), lineWidth: 2))
        }
        .frame(width: size, height: size)
        .onAppear { pulse = true }
    }
}
