import SwiftData
import SwiftUI

/// Today (or an earlier day): the daily goal ring, the running session, the
/// day's timeline, sessions and top apps.
struct TodayPage: View {
    @Bindable var appState: AppState
    let onNavigate: (MainTab) -> Void

    @State private var dayOffset = 0
    @State private var data: TodayInsights = .empty
    @State private var bestZone: TimeInterval = 0
    @State private var now = Date.now

    private var isToday: Bool { dayOffset == 0 }

    private var day: Date {
        Calendar.current.date(byAdding: .day, value: -dayOffset, to: now) ?? now
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: isToday ? "Today" : day.formatted(.dateTime.weekday(.wide)),
                       subtitle: day.formatted(.dateTime.weekday(.wide).month(.wide).day())) {
                PeriodStepper(offset: $dayOffset, unit: "day")
                HeaderCapsule {
                    Button("Export") { exportDay() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 14)
                }
            }

            ScrollView {
                VStack(spacing: 14) {
                    if !appState.permissions.allGranted { permissionBanner }

                    HStack(alignment: .top, spacing: 14) {
                        goalCard
                        if isToday { nowCard.frame(maxWidth: 380) }
                    }

                    WindowCard(title: "Your day", trailing: AnyView(legend)) {
                        DayTimelineView(insights: data, now: now)
                            .frame(height: 96)
                    }

                    HStack(alignment: .top, spacing: 14) {
                        sessionsCard
                        appsCard
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
        .padding(.leading, 16)
        .padding(.trailing, 24)
        .task(id: dayOffset) {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .task { await appState.permissions.refresh() }
        // The session card's clock ticks every second; the rest reloads every 10 s.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            if isToday && appState.sessionManager.currentSession != nil { now = date }
        }
    }

    private func reload() {
        now = .now
        let context = appState.container.mainContext
        data = MenuInsightsBuilder.day(day, context: context, now: now)
        bestZone = Self.longestZone(on: day, context: context, now: now)
    }

    /// Longest unbroken focus run inside sessions on a given day.
    static func longestZone(on date: Date, context: ModelContext, now: Date) -> TimeInterval {
        let start = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let events = Persistence.fetch(context, FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= start && $0.startedAt < end }
        )).filter { $0.session != nil }
        return FocusRuns.compute(FocusRuns.spans(from: events), now: now).longest
    }

    private func exportDay() {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? now
        DataExporter.export(.csv, container: appState.container, from: start, to: min(end, now))
    }

    // MARK: - Goal

    private var goalCard: some View {
        WindowCard {
            HStack(spacing: 26) {
                ZStack {
                    Circle().stroke(Theme.focusTint, lineWidth: 20)
                    Circle().trim(from: 0, to: data.goalProgress)
                        .stroke(Theme.focus, style: StrokeStyle(lineWidth: 20, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 2) {
                        Text(formatDuration(data.focused))
                            .font(.system(size: 32, weight: .bold).monospacedDigit())
                            .kerning(-0.8)
                        Text("of \(FocusGoal.format(minutes: FocusGoal.dailyMinutes)) goal")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 176, height: 176)
                .padding(4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Daily goal: \(formatDuration(data.focused)) focused, \(Int((data.goalProgress * 100).rounded())) percent of \(FocusGoal.format(minutes: FocusGoal.dailyMinutes))")

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                    GridRow {
                        WindowStat(label: "Focus rate", value: "\(Int((data.focusRate * 100).rounded()))%", detail: rateDetail)
                        WindowStat(label: "Best in the zone", value: "\(Int(bestZone / 60)) min", detail: "longest run")
                    }
                    GridRow {
                        WindowStat(label: "Sessions", value: "\(data.sessions.count)", detail: sessionsDetail)
                        WindowStat(label: isToday ? "Streak" : "Goal",
                                   value: isToday ? "\(appState.currentStreak) days" : (data.goalProgress >= 1 ? "Met" : "Missed"),
                                   detail: isToday ? "goal met in a row" : "\(Int((data.goalProgress * 100).rounded()))% of goal")
                    }
                }
            }
        }
    }

    private var rateDetail: String {
        guard let avg = data.averageFocusRate, data.focused > 0 else { return " " }
        let delta = Int(((data.focusRate - avg) * 100).rounded())
        return delta == 0 ? "same as average" : "\(delta > 0 ? "+" : "−")\(abs(delta)) pts vs avg"
    }

    private var sessionsDetail: String {
        let minutes = data.sessions.reduce(0) { $0 + $1.minutes }
        return minutes > 0 ? "\(formatDuration(TimeInterval(minutes * 60))) in sessions" : "none yet"
    }

    // MARK: - Now

    @ViewBuilder
    private var nowCard: some View {
        WindowCard {
            if let session = appState.sessionManager.currentSession {
                sessionNow(session)
            } else if let state = appState.breakManager.current {
                breakNow(state)
            } else {
                startNow
            }
        }
    }

    private func sessionNow(_ session: Session) -> some View {
        let timeline = appState.liveTimeline(for: session, now: now)
        let elapsed = appState.sessionManager.runningSeconds(for: session, now: now)
        let runs = appState.focusRuns(for: session, now: now)
        let paused = session.pausedAt != nil
        let left = session.plannedDurationMinutes.map { max(0, Double($0 * 60) - elapsed) }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(Theme.focus).frame(width: 8, height: 8)
                Text("\(session.label ?? "Focus session") · \(paused ? "paused" : "now")")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let left, !paused {
                    Text("ends \(now.addingTimeInterval(left).formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 18) {
                SessionRingView(timeline: timeline,
                                progress: SessionTimeline.progress(elapsed: elapsed, timeline: timeline),
                                size: 120, lineWidth: 11,
                                secondsSweep: paused ? nil : SessionClock.sweep(elapsed: elapsed)) {
                    VStack(spacing: 0) {
                        Text(SessionClock.format(left ?? elapsed))
                            .font(.system(size: 22, weight: .semibold).monospacedDigit())
                            .contentTransition(.numericText(countsDown: left != nil))
                        Text(left == nil ? "elapsed" : "left").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    WindowStat(label: "In the zone", value: "\(Int(runs.current / 60)) min", detail: nil)
                    let best = max(appState.bestZoneToday(now: now), runs.longest)
                    if best >= 60 {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Best today \(Int(best / 60)) min").font(.system(size: 11)).foregroundStyle(.secondary)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.control)
                                    Capsule().fill(Theme.focus)
                                        .frame(width: geo.size.width * CGFloat(min(1, runs.current / best)))
                                }
                            }
                            .frame(height: 5)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                pill(paused ? "Resume" : "Pause") {
                    if paused { appState.sessionManager.resumeSession() } else { appState.sessionManager.pauseSession() }
                }
                if session.plannedDurationMinutes != nil {
                    pill("5 more min") { appState.sessionManager.extendSession(byMinutes: 5) }
                }
                pill("End") { appState.sessionManager.stopSession() }
            }
        }
    }

    private func breakNow(_ state: BreakState) -> some View {
        let remaining = state.remaining(now: now)
        return VStack(alignment: .leading, spacing: 14) {
            Label("On a break", systemImage: "cup.and.saucer").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(Theme.control, lineWidth: 10)
                    Circle().trim(from: 0, to: state.plannedDuration > 0 ? remaining / state.plannedDuration : 0)
                        .stroke(Color.primary.opacity(0.75), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int((remaining / 60).rounded(.up)))")
                        .font(.system(size: 28, weight: .semibold).monospacedDigit())
                }
                .frame(width: 100, height: 100)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Back at \(now.addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 15, weight: .semibold))
                    Text(BreakTips.tip(for: state.startedAt)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                pill("5 more min") { appState.breakManager.extend(byMinutes: 5) }
                pill("End break") { appState.breakManager.skip() }
            }
        }
    }

    @AppStorage(SessionDefaultsKey.durationMinutes) private var defaultMinutes = 50
    @AppStorage("menu.lastSessionMinutes") private var lastSessionMinutes = 0
    @AppStorage(SessionDefaultsKey.label) private var defaultLabel = "Deep work"

    private var startNow: some View {
        let chosen = lastSessionMinutes > 0 ? lastSessionMinutes : defaultMinutes
        return VStack(alignment: .leading, spacing: 14) {
            Text("Ready to focus").font(.system(size: 13, weight: .semibold))
            if let recap = appState.recap {
                Text("Last session: \(recap.timeline.focusPercent)% focused, \(Int(recap.longestZone / 60)) min in the zone.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("Pick a length and go. The menu bar shows how it's going.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach([25, 50, 90], id: \.self) { minutes in
                    let selected = chosen == minutes
                    Button { lastSessionMinutes = minutes } label: {
                        Text("\(minutes) min")
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Capsule().fill(selected ? Theme.focusFill : Theme.control))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Button {
                lastSessionMinutes = chosen
                appState.sessionManager.startSession(label: defaultLabel.isEmpty ? nil : defaultLabel,
                                                     plannedDurationMinutes: chosen)
            } label: {
                Text("Start \(chosen) minutes of focus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(Capsule().fill(Theme.focusFill))
            }
            .buttonStyle(.plain)
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(Capsule().fill(Theme.control))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Timeline, sessions, apps

    private var legend: some View {
        HStack(spacing: 12) {
            swatch(Theme.focus, "Focused")
            swatch(Theme.distraction, "Drifted")
            swatch(Theme.other, "Other")
        }
        .font(.system(size: 11))
    }

    private func swatch(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title)
        }
    }

    private var sessionsCard: some View {
        WindowCard(title: "Sessions", trailing: AnyView(Text("Hover to rename or delete").font(.system(size: 11)).foregroundStyle(.secondary))) {
            if data.sessions.isEmpty {
                Text(isToday ? "No sessions yet today." : "No sessions this day.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(data.sessions) { summary in
                        SessionRow(summary: summary, now: now,
                                   onRename: { appState.sessionManager.rename(summary.session, to: $0); reload() },
                                   onDelete: { appState.sessionManager.delete(summary.session); reload() })
                    }
                }
            }
        }
    }

    private var appsCard: some View {
        WindowCard(title: "Top apps & sites", trailing: AnyView(
            Button("Manage ›") { onNavigate(.apps) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.focus)
        )) {
            if data.topApps.isEmpty {
                Text("Nothing tracked yet.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                let maxSeconds = data.topApps.map(\.seconds).max() ?? 1
                VStack(spacing: 9) {
                    ForEach(data.topApps) { row in
                        UsageBarRow(row: row, maxSeconds: maxSeconds, onChange: { c in
                            appState.setCategory(c, for: row)
                            reload()
                        }, nameWidth: 110, barWidth: 120)
                    }
                }
            }
        }
    }

    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Permissions needed").font(.system(size: 13, weight: .semibold))
                Text("Grant Screen Recording and Notifications so FocusGuard can see what you're working on and nudge you.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Set up…") { NotificationCenter.default.post(name: .showOnboarding, object: nil) }
                .buttonStyle(.borderedProminent)
                .tint(Theme.focusFill)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.warning.opacity(0.12)))
    }
}
