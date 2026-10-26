import SwiftData
import SwiftUI

/// Today (or an earlier day): the daily goal, the running session or a
/// quick start, the day strip, the sessions and the top apps and sites.
/// On the very first day the goal card is a setup checklist instead.
struct TodayPage: View {
    @Bindable var appState: AppState
    let onNavigate: (MainTab) -> Void

    @State private var dayOffset = 0
    @State private var model: TodayModel = .empty()
    @State private var now = Date.now
    /// No session ever: the first-day page.
    @State private var isFirstDay = false
    @State private var streak = 0

    @AppStorage(WindowDefaultsKey.sessionLength) private var lengthChoice = 0
    @AppStorage(SessionDefaultsKey.durationMinutes) private var defaultMinutes = 50
    @AppStorage(SettingsKeys.Goal.weekendsCount) private var weekendsCount = false

    private var isToday: Bool { dayOffset == 0 }
    private var showFirstDay: Bool { isToday && isFirstDay && appState.sessionManager.currentSession == nil }

    private var day: Date {
        Calendar.current.date(byAdding: .day, value: -dayOffset, to: now) ?? now
    }

    /// Free keeps 30 days; the stepper stops there.
    private var maxOffset: Int? {
        guard let start = Entitlements.shared.historyStart() else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: start, to: Calendar.current.startOfDay(for: now)).day ?? 0)
    }

    var body: some View {
        WindowScroll {
            VStack(alignment: .leading, spacing: 12) {
                header
                if !appState.permissions.allGranted && !showFirstDay { permissionBanner }
                WindowHeadline(lead: headline.lead, rest: headline.rest)

                WindowSplitRow(weights: [1.62, 1]) {
                    if showFirstDay {
                        SetupCard(appState: appState, model: model, onNavigate: onNavigate)
                    } else {
                        goalCard
                    }
                    if isToday {
                        NowCard(appState: appState, model: model, now: now)
                    } else {
                        DaySummaryCard(model: model)
                    }
                }
                .frame(height: showFirstDay ? 236 : 212)

                dayCard

                WindowSplitRow(weights: [1.15, 1]) {
                    sessionsCard
                    appsCard
                }
                .frame(minHeight: 210, maxHeight: .infinity)
            }
            .padding(.leading, 16)
            .padding(.trailing, 24)
            .padding(.bottom, 20)
        }
        .task(id: dayOffset) {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .task { await appState.permissions.refresh() }
        // The session card's clock ticks every second; the rest reloads every 10 s.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            if isToday && (appState.sessionManager.currentSession != nil || appState.breakManager.current != nil) {
                now = date
            }
        }
        .onChange(of: appState.sessionManager.currentSession?.id) { reload() }
    }

    private func reload() {
        now = .now
        let context = appState.container.mainContext
        model = TodayModelBuilder.build(day: day, context: context, now: now)
        isFirstDay = Persistence.fetchCount(context, FetchDescriptor<Session>()) == 0
        streak = appState.currentStreak
    }

    // MARK: - Header

    private var header: some View {
        let date = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return PageHeader(title: isToday ? "Today" : day.formatted(.dateTime.weekday(.wide)),
                          subtitle: showFirstDay ? "\(date) · your first day" : date) {
            if !showFirstDay {
                PeriodStepper(offset: $dayOffset, unit: "day", maxOffset: maxOffset)
                Button(action: exportDay) {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.header)
                .help("Export this day's activity as CSV")
            }
        }
    }

    private var headline: (lead: String, rest: String) {
        let session = appState.sessionManager.currentSession
        let left: TimeInterval? = session.flatMap { s in
            s.plannedDurationMinutes.map { max(0, Double($0 * 60) - appState.sessionManager.runningSeconds(for: s, now: now)) }
        }
        return TodayHeadline.make(.init(
            focused: model.focused,
            goal: model.goal,
            isToday: isToday,
            isFirstDay: showFirstDay,
            sessionLeft: left,
            inSession: isToday && session != nil,
            onBreak: isToday && appState.breakManager.current != nil,
            nextLength: lengthChoice > 0 ? lengthChoice : CoachRules.sessionMinutes() ?? defaultMinutes,
            hasActivity: model.focused + model.drifted > 0 || !model.activity.isEmpty
        ))
    }

    private func exportDay() {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? now
        DataExporter.export(.csv, container: appState.container, from: start, to: min(end, now))
    }

    // MARK: - Goal

    private var goalCard: some View {
        WindowCard(padding: EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22)) {
            HStack(spacing: 24) {
                WindowGoalRing(inSession: model.inSessionProgress, total: model.goalProgress) {
                    VStack(spacing: 1) {
                        Text(WindowFormat.hm(model.focused))
                            .font(.system(size: 30, weight: .bold).monospacedDigit())
                            .kerning(-0.9)
                            .foregroundStyle(Theme.primaryText)
                        Text("of \(FocusGoal.format(minutes: Int(model.goal / 60))) goal")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .frame(width: 164, height: 164)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Daily goal: \(WindowFormat.hm(model.focused)) of \(FocusGoal.format(minutes: Int(model.goal / 60))). \(WindowFormat.hm(model.focusedInSessions)) in sessions, \(WindowFormat.hm(model.focusedBetweenSessions)) between sessions.")

                VStack(alignment: .leading, spacing: 14) {
                    VStack(spacing: 7) {
                        goalLegend(Theme.goalInSession, "In sessions", model.focusedInSessions)
                        goalLegend(Theme.goalBetweenSessions, "Between sessions", model.focusedBetweenSessions)
                    }
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    HStack(alignment: .top, spacing: 12) {
                        WindowStat(label: "Focus rate",
                                 value: model.hasRate ? "\(Int((model.focusRate * 100).rounded()))%" : "–",
                                 detail: "focus vs drift; other apps don't count")
                        WindowStat(label: "Best in the zone",
                                 value: WindowFormat.minutes(model.bestZone),
                                 detail: model.bestZoneSession ?? (model.sessions.isEmpty ? "no sessions yet" : "longest run"))
                        if isToday {
                            WindowStat(label: "Streak",
                                     value: WindowFormat.count(streak, "day"),
                                     detail: StreakWords.detail(count: streak, now: now, weekendsCount: weekendsCount))
                        } else {
                            WindowStat(label: "Goal",
                                     value: model.goalProgress >= 1 ? "Met" : "Missed",
                                     detail: "\(Int((model.goalProgress * 100).rounded()))% of \(FocusGoal.format(minutes: Int(model.goal / 60)))")
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func goalLegend(_ color: Color, _ title: String, _ seconds: TimeInterval) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(title).foregroundStyle(Theme.primaryText)
            Spacer(minLength: 8)
            Text(WindowFormat.hm(seconds)).fontWeight(.semibold).monospacedDigit().foregroundStyle(Theme.primaryText)
        }
        .font(.system(size: 13))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Your day

    private var dayCard: some View {
        WindowCard(padding: EdgeInsets(top: 12, leading: 20, bottom: 8, trailing: 20)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) {
                    Text("Your day").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                    Spacer(minLength: 8)
                    if showFirstDay {
                        Text(firstDayNote).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).lineLimit(1)
                    } else {
                        WindowLegend(color: Theme.focus, title: "Focused")
                        WindowLegend(color: Theme.distraction, title: "Drifted")
                        WindowLegend(color: Theme.other, title: "Other")
                        if isToday && previewKind != nil {
                            WindowLegend(color: Theme.focus, title: previewKind ?? "", dashed: true)
                        }
                    }
                }
                WindowDayStrip(window: model.window, sessions: model.sessions, activity: model.activity,
                             now: isToday ? now : nil, preview: isToday ? preview : nil)
            }
        }
        .frame(height: 112)
        .zIndex(1)
    }

    private var firstDayNote: String {
        guard let started = model.trackingStarted else {
            return "Nothing is recorded while your Mac is locked or idle."
        }
        return "Tracking started at \(WindowFormat.clock(started)). Nothing is recorded while your Mac is locked or idle."
    }

    /// "Rest of session" while one runs, "Next session" between them.
    private var previewKind: String? {
        if let session = appState.sessionManager.currentSession {
            return session.plannedDurationMinutes == nil ? nil : "Rest of session"
        }
        return appState.breakManager.current == nil && lengthChoice >= 0 ? "Next session" : nil
    }

    private var preview: DateInterval? {
        if let session = appState.sessionManager.currentSession {
            guard let planned = session.plannedDurationMinutes else { return nil }
            let left = max(0, Double(planned * 60) - appState.sessionManager.runningSeconds(for: session, now: now))
            return left > 0 ? DateInterval(start: now, duration: left) : nil
        }
        guard appState.breakManager.current == nil, lengthChoice >= 0 else { return nil }
        let minutes = lengthChoice > 0 ? lengthChoice : CoachRules.sessionMinutes() ?? defaultMinutes
        return DateInterval(start: now, duration: TimeInterval(minutes * 60))
    }

    // MARK: - Sessions

    private var sessionsCard: some View {
        SessionsCard(appState: appState, sessions: model.sessions, isToday: isToday, onChange: reload)
    }

    // MARK: - Apps

    private var appsCard: some View {
        WindowCard(padding: EdgeInsets(top: 14, leading: 20, bottom: 10, trailing: 20)) {
            VStack(alignment: .leading, spacing: 2) {
                WindowCardTitle(title: "Top apps & sites") {
                    Button("Manage ›") { onNavigate(.apps) }.buttonStyle(.textLink)
                }
                .padding(.bottom, 6)
                if model.topApps.isEmpty {
                    Text(isToday ? "Nothing tracked yet today." : "Nothing tracked this day.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                } else {
                    let maxSeconds = model.topApps.map(\.seconds).max() ?? 1
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(model.topApps) { row in
                                TopAppRow(row: row, maxSeconds: maxSeconds) { c in
                                    appState.setCategory(c, for: row)
                                    reload()
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
                Spacer(minLength: 0)
                if showFirstDay {
                    Text("Browsers count by site, not as a whole. Sites show up once you visit them.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            Text("FocusGuard needs Screen Recording and notifications to see what's in front and nudge you.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.bodyText)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Set up…") { NotificationCenter.default.post(name: .showOnboarding, object: nil) }
                .buttonStyle(.capsule(.primary, height: 26))
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.warning.opacity(0.12)))
    }
}

/// Keys the window keeps for itself.
enum WindowDefaultsKey {
    /// The length "Start" uses in the window: minutes, 0 for the default
    /// from Settings, -1 for an open-ended session.
    static let sessionLength = "window.sessionLength"
    /// Set once "Sort your apps" has been gone through.
    static let appsSorted = "window.appsSorted"
}

// MARK: - Top apps row

private struct TopAppRow: View {
    let row: UsageRow
    let maxSeconds: TimeInterval
    let onChange: (Classification) -> Void

    var body: some View {
        HStack(spacing: 10) {
            WindowItemIcon(name: row.name, bundleId: row.bundleId, host: row.host)
            Text(row.name)
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 86, alignment: .leading)
            WindowBar(fraction: row.seconds / max(1, maxSeconds), color: CategoryChip.dot(row.classification), height: 6)
                .frame(minWidth: 40, maxWidth: 110)
            Text(WindowFormat.hm(row.seconds))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 44, alignment: .trailing)
            Spacer(minLength: 4)
            WindowCategoryPicker(name: row.name, current: row.classification, onChange: onChange)
                .frame(width: 104, alignment: .trailing)
        }
        .frame(height: 29)
    }
}

// MARK: - Sessions card

private struct SessionsCard: View {
    @Bindable var appState: AppState
    let sessions: [TodaySession]
    let isToday: Bool
    let onChange: () -> Void

    @State private var hovered: UUID?
    @State private var renaming: UUID?
    @State private var draft = ""
    @State private var pendingDelete: TodaySession?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        WindowCard(padding: EdgeInsets(top: 14, leading: 12, bottom: 10, trailing: 12)) {
            VStack(alignment: .leading, spacing: 2) {
                WindowCardTitle("Sessions", note: sessions.isEmpty ? "" : "Named from how they went · hover to rename")
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                if sessions.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(sessions) { row($0) }
                        }
                    }
                    .scrollIndicators(.never)
                    Spacer(minLength: 0)
                    Text("Deleting a session keeps its activity in your reports.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                }
            }
        }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "this session")?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { session in
            Button("Delete Session", role: .destructive) {
                if let model = appState.session(session.modelID) { appState.sessionManager.delete(model) }
                onChange()
            }
        } message: { _ in
            Text("Its activity stays in your reports.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "shield")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
            Text(isToday ? "No sessions yet" : "No sessions this day")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
            Text("Each one is named from how it went: Locked-in, Comeback, Steady, plus how long it ran.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.lockedStroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .padding(.horizontal, 8)
    }

    private func row(_ session: TodaySession) -> some View {
        let isHovered = hovered == session.id
        return HStack(spacing: 10) {
            WindowRateRing(rate: session.rate)
            VStack(alignment: .leading, spacing: 0) {
                if renaming == session.id {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .focused($fieldFocused)
                        .onSubmit { commitRename(session) }
                        .onExitCommand { renaming = nil }
                        .onChange(of: fieldFocused) { _, focused in if !focused { commitRename(session) } }
                } else {
                    HStack(spacing: 6) {
                        Text(session.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if session.isLive {
                            Text("Now")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.proBadgeText)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.proBadge))
                        }
                    }
                    .foregroundStyle(Theme.primaryText)
                }
                Text(when(session))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !session.isLive && renaming != session.id {
                HStack(spacing: 2) {
                    iconButton("pencil", "Rename") {
                        draft = session.name
                        renaming = session.id
                        fieldFocused = true
                    }
                    iconButton("trash", "Delete") { pendingDelete = session }
                }
                .opacity(isHovered ? 1 : 0)
                .accessibilityHidden(!isHovered)
            }
            Text("\(Int((session.rate * 100).rounded()))%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.primaryText)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isHovered ? Theme.rowHover : .clear))
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? session.id : (hovered == session.id ? nil : hovered) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Rename") {
            guard !session.isLive else { return }
            draft = session.name
            renaming = session.id
        }
    }

    private func when(_ s: TodaySession) -> String {
        if s.isLive {
            let planned = s.plannedMinutes.map { " of \($0) min" } ?? " min"
            return "\(WindowFormat.clock(s.start))–now · \(s.minutes)\(planned)"
        }
        return "\(WindowFormat.clock(s.start))–\(s.end.map(WindowFormat.clock) ?? "") · \(s.minutes) min"
    }

    private func commitRename(_ session: TodaySession) {
        guard renaming == session.id else { return }
        renaming = nil
        if let model = appState.session(session.modelID) { appState.sessionManager.rename(model, to: draft) }
        onChange()
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Now card

/// Right of the goal: the running session, the break, or "Ready to focus".
private struct NowCard: View {
    @Bindable var appState: AppState
    let model: TodayModel
    let now: Date

    var body: some View {
        WindowCard(padding: EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)) {
            if let session = appState.sessionManager.currentSession {
                SessionNow(appState: appState, session: session, now: now)
            } else if let state = appState.breakManager.current {
                BreakNow(appState: appState, state: state, now: now)
            } else {
                ReadyNow(appState: appState, model: model)
            }
        }
    }
}

private struct SessionNow: View {
    @Bindable var appState: AppState
    let session: Session
    let now: Date
    @State private var confirmEnd = false

    var body: some View {
        let timeline = appState.liveTimeline(for: session, now: now)
        let elapsed = appState.sessionManager.runningSeconds(for: session, now: now)
        let progress = SessionTimeline.progress(elapsed: elapsed, timeline: timeline)
        let paused = session.pausedAt != nil
        let left = session.plannedDurationMinutes.map { max(0, Double($0 * 60) - elapsed) }
        let runs = appState.focusRuns(for: session, now: now)
        let best = max(appState.bestZoneToday(now: now), runs.longest)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(paused ? Theme.neutral : Theme.focus).frame(width: 8, height: 8)
                    .background(Circle().fill(Theme.focus.opacity(paused ? 0 : 0.18)).frame(width: 14, height: 14))
                Text(paused ? "Paused" : "Current session").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text(left.map { WindowFormat.span(session.startedAt, now.addingTimeInterval($0)) }
                     ?? "since \(WindowFormat.clock(session.startedAt))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            .foregroundStyle(Theme.primaryText)

            HStack(spacing: 16) {
                WindowSessionRing(segments: timeline.ringSegments(progress: paused ? nil : progress),
                            knob: paused ? nil : progress, lineWidth: 10) {
                    VStack(spacing: 3) {
                        Text(left.map { "\(AppState.minutesRoundedUp($0))" } ?? "\(Int(elapsed / 60))")
                            .font(.system(size: 28, weight: .semibold).monospacedDigit())
                            .kerning(-0.8)
                            .contentTransition(.numericText(countsDown: left != nil))
                        Text(left == nil ? "min in" : "min left")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    }
                    .foregroundStyle(Theme.primaryText)
                }
                .frame(width: 108, height: 108)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ringLabel(timeline: timeline, elapsed: elapsed, left: left))

                VStack(alignment: .leading, spacing: 8) {
                    Text(session.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    VStack(alignment: .leading, spacing: 5) {
                        (Text("In the zone ") + Text(WindowFormat.minutes(runs.current)).fontWeight(.semibold).foregroundColor(Theme.primaryText)
                         + Text(best >= 60 ? " · best today \(Int(best / 60))" : ""))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                        WindowBar(fraction: best > 0 ? runs.current / best : 0)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                Button(paused ? "Resume" : "Pause") {
                    if paused { appState.sessionManager.resumeSession() } else { appState.sessionManager.pauseSession() }
                }
                if session.plannedDurationMinutes != nil {
                    Button("5 more min") { appState.sessionManager.extendSession(byMinutes: 5) }
                }
                Button("End") {
                    if appState.isStrictLocked { confirmEnd = true } else { appState.sessionManager.stopSession() }
                }
            }
            .buttonStyle(.capsule(.secondary, fullWidth: true))
        }
        .confirmationDialog("End this Strict session early?", isPresented: $confirmEnd) {
            Button("End Session", role: .destructive) { appState.sessionManager.stopSession() }
        } message: {
            Text("Blocked sites unlock once it ends.")
        }
    }

    private func ringLabel(timeline: SessionTimeline, elapsed: TimeInterval, left: TimeInterval?) -> String {
        var parts = ["Session ring: \(Int(elapsed / 60)) minutes in"]
        if let planned = session.plannedDurationMinutes { parts[0] += " of \(planned)" }
        if timeline.classifiedCells > 0 { parts.append("\(timeline.focusPercent) percent focused so far") }
        if let left { parts.append("\(AppState.minutesRoundedUp(left)) minutes left") }
        return parts.joined(separator: ", ") + "."
    }
}

private struct BreakNow: View {
    @Bindable var appState: AppState
    let state: BreakState
    let now: Date

    var body: some View {
        let remaining = state.remaining(now: now)
        return VStack(alignment: .leading, spacing: 12) {
            Label("On a break", systemImage: "cup.and.saucer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            HStack(spacing: 16) {
                ZStack {
                    Circle().inset(by: 5).stroke(Theme.track, lineWidth: 10)
                    WindowArc(start: 0, end: state.plannedDuration > 0 ? min(0.9999, remaining / state.plannedDuration) : 0)
                        .inset(5)
                        .stroke(Theme.bodyText, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    VStack(spacing: 3) {
                        Text("\(AppState.minutesRoundedUp(remaining))")
                            .font(.system(size: 28, weight: .semibold).monospacedDigit())
                        Text("min left").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    }
                    .foregroundStyle(Theme.primaryText)
                }
                .frame(width: 108, height: 108)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Back at \(WindowFormat.clock(now.addingTimeInterval(remaining)))")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text("Stand up, stretch and look at something far away.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                Button("5 more min") { appState.breakManager.extend(byMinutes: 5) }
                if appState.breakManager.canEndEarly {
                    Button("End break") { appState.breakManager.skip() }
                }
            }
            .buttonStyle(.capsule(.secondary, fullWidth: true))
        }
    }
}

/// "Ready to focus": pick a length and start.
private struct ReadyNow: View {
    @Bindable var appState: AppState
    let model: TodayModel

    @AppStorage(WindowDefaultsKey.sessionLength) private var lengthChoice = 0
    @AppStorage(SessionDefaultsKey.durationMinutes) private var defaultMinutes = 50
    @AppStorage(SessionDefaultsKey.label) private var defaultLabel = ""

    private static let lengths = [25, 50, 90]

    /// Minutes, or nil for open-ended.
    private var chosen: Int? {
        if lengthChoice < 0 { return nil }
        return lengthChoice > 0 ? lengthChoice : CoachRules.sessionMinutes() ?? defaultMinutes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Ready to focus").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Text(lastLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                ForEach(Self.lengths, id: \.self) { minutes in
                    choice("\(minutes) min", picked: chosen == minutes) { lengthChoice = minutes }
                }
                choice("Open", picked: chosen == nil) { lengthChoice = -1 }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Session length")

            HStack(spacing: 8) {
                Image(systemName: "shield").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                Text(driftLine).font(.system(size: 12)).foregroundStyle(Theme.bodyText).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.inset))

            Spacer(minLength: 0)
            Button(chosen.map { "Start \($0) minutes of focus" } ?? "Start an open session") {
                appState.sessionManager.startSession(label: defaultLabel.isEmpty ? nil : defaultLabel,
                                                     plannedDurationMinutes: chosen)
            }
            .buttonStyle(.capsule(.primary, height: 36, fullWidth: true))
        }
    }

    private func choice(_ title: String, picked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: picked ? .semibold : .regular))
                .foregroundStyle(picked ? Theme.choiceText : Theme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(Capsule().fill(picked ? Theme.choiceFill : Theme.track))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private var lastLine: String {
        guard let last = model.sessions.first(where: { !$0.isLive }) else {
            return "Pick a length and go. The shield in the menu bar fills as the session runs."
        }
        var parts = ["Last one: \(last.name)", "\(Int((last.rate * 100).rounded()))% focused"]
        if last.bestRun >= 60 { parts.append("\(Int(last.bestRun / 60)) min in the zone") }
        return parts.joined(separator: ", ") + "."
    }

    private var driftLine: String {
        let engine = appState.escalationEngine
        let preset = engine.preset
        if engine.strictMode { return "When you drift: \(preset.title) · pause screen right away" }
        return "When you drift: \(preset.title) · nudge at \(Self.seconds(engine.notifyThreshold)), pause at \(Self.seconds(engine.blockThreshold))"
    }

    static func seconds(_ value: TimeInterval) -> String {
        let s = Int(value)
        if s >= 60 && s % 60 == 0 { return "\(s / 60) min" }
        return "\(s) s"
    }
}

/// On an earlier day, in place of the now card: the day in numbers.
private struct DaySummaryCard: View {
    let model: TodayModel

    var body: some View {
        WindowCard(padding: EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)) {
            VStack(alignment: .leading, spacing: 14) {
                Text("The day in numbers").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                    GridRow {
                        WindowStat(label: "Sessions", value: "\(model.sessions.count)",
                                 detail: model.sessions.isEmpty ? "none" : "\(model.sessions.reduce(0) { $0 + $1.minutes }) min in sessions")
                        WindowStat(label: "Drifted", value: WindowFormat.hm(model.drifted), detail: nil)
                    }
                    GridRow {
                        WindowStat(label: "First activity", value: model.trackingStarted.map(WindowFormat.clock) ?? "–", detail: nil)
                        WindowStat(label: "Focused", value: WindowFormat.hm(model.focused), detail: nil)
                    }
                }
            }
        }
    }
}

// MARK: - First day

/// The first day's checklist, beside an empty goal ring.
private struct SetupCard: View {
    @Bindable var appState: AppState
    let model: TodayModel
    let onNavigate: (MainTab) -> Void

    @AppStorage(WindowDefaultsKey.appsSorted) private var appsSorted = false

    var body: some View {
        WindowCard(padding: EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22)) {
            HStack(spacing: 24) {
                WindowGoalRing(inSession: 0, total: model.goalProgress) {
                    VStack(spacing: 1) {
                        Text(WindowFormat.hm(model.focused))
                            .font(.system(size: 28, weight: .bold).monospacedDigit())
                            .kerning(-0.84)
                        Text("of \(FocusGoal.format(minutes: Int(model.goal / 60))) goal")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    }
                    .foregroundStyle(Theme.primaryText)
                }
                .frame(width: 150, height: 150)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Daily goal: \(WindowFormat.hm(model.focused)) of \(FocusGoal.format(minutes: Int(model.goal / 60))).")

                VStack(alignment: .leading, spacing: 4) {
                    Text("Getting set up · \(steps.filter(\.done).count) of \(steps.count) done")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .padding(.bottom, 6)
                    ForEach(steps, id: \.title) { step in
                        TodaySetupStepRow(step: step)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var steps: [TodaySetupStep] {
        [
            TodaySetupStep(title: "Allow Screen Recording and notifications",
                      detail: "So FocusGuard can see what's in front.",
                      done: appState.permissions.allGranted,
                      action: ("Set up", { NotificationCenter.default.post(name: .showOnboarding, object: nil) })),
            TodaySetupStep(title: "Pick a daily goal: \(Self.goalWords(FocusGoal.dailyMinutes))",
                      detail: "Change it any time in Settings.",
                      done: true, action: nil),
            TodaySetupStep(title: "Sort your apps",
                      detail: "Check FocusGuard's guesses in about 2 minutes.",
                      done: appsSorted,
                      action: ("Sort now", { NotificationCenter.default.post(name: .openAppsSort, object: nil) })),
            TodaySetupStep(title: "Start your first session",
                      detail: "It gets a name from how it goes, like Steady Deep Dive.",
                      done: false, action: nil),
        ]
    }
}

extension SetupCard {
    /// "4 hours", "3 hours 30 minutes", "45 minutes".
    static func goalWords(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        var parts: [String] = []
        if h > 0 { parts.append(WindowFormat.count(h, "hour")) }
        if m > 0 { parts.append(WindowFormat.count(m, "minute")) }
        return parts.joined(separator: " ")
    }
}

private struct TodaySetupStep {
    let title: String
    let detail: String
    let done: Bool
    let action: (title: String, run: () -> Void)?
}

private struct TodaySetupStepRow: View {
    let step: TodaySetupStep

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if step.done {
                    Circle().fill(Theme.focusFill)
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                } else {
                    Circle().strokeBorder(Theme.lockedStroke, lineWidth: 1.5)
                }
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .font(.system(size: 13, weight: step.done ? .regular : .semibold))
                    .foregroundStyle(step.done ? Theme.secondaryText : Theme.primaryText)
                if !step.done {
                    Text(step.detail).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if !step.done, let action = step.action {
                Button(action.title, action: action.run)
                    .buttonStyle(WindowTintedButtonStyle())
            }
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)
        .accessibilityValue(step.done ? "Done" : "To do")
    }
}

/// Indigo text on a light indigo capsule: "Sort now".
struct WindowTintedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.link)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(Theme.focusTint))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
