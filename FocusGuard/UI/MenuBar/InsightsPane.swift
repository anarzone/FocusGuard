import SwiftUI

/// Insights beside the menu: today, or a week, each led by one plain
/// sentence about what happened.
struct InsightsPane: View {
    @Bindable var appState: AppState
    let onOpenMain: (MainTab) -> Void
    let dismiss: () -> Void
    let close: () -> Void
    /// Opens another pane next to the menu (the weekly coach).
    var openPane: (MenuPane) -> Void = { _ in }
    var entitlements: Entitlements = .shared
    var coach: WeeklyCoach = .shared

    enum Range: String, CaseIterable, Identifiable {
        case today = "Today", week = "Week"
        var id: String { rawValue }
    }

    @State private var range: Range = .today
    @State private var today: TodayInsights
    @State private var week: WeekInsights
    /// 0 is this week, -1 last week, and so on.
    @State private var weekOffset = 0
    @State private var now: Date = .now

    /// Opens on the last results, so nothing pops in or resizes while the
    /// pane slides in; fresh numbers arrive from `StatsStore` a moment later.
    init(appState: AppState, onOpenMain: @escaping (MainTab) -> Void, dismiss: @escaping () -> Void,
         close: @escaping () -> Void, openPane: @escaping (MenuPane) -> Void = { _ in }) {
        self.appState = appState
        self.onOpenMain = onOpenMain
        self.dismiss = dismiss
        self.close = close
        self.openPane = openPane
        _today = State(initialValue: appState.lastTodayInsights ?? .empty)
        _week = State(initialValue: appState.lastWeekInsights ?? .empty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaneTitle(title: "Insights", close: close) {
                PaneTabs(selection: $range, options: Range.allCases.map { ($0, $0.rawValue) })
            }

            switch range {
            case .today: todayContent
            case .week:  weekContent
            }

            Spacer(minLength: 0)
            footer
        }
        .task(id: "\(range.rawValue)\(weekOffset)") {
            while !Task.isCancelled {
                await load()
                // The week's numbers barely move; today's do.
                try? await Task.sleep(for: .seconds(range == .week ? 30 : 5))
            }
        }
    }

    /// Builds off the main thread (`StatsStore`); only the result lands here.
    private func load() async {
        let at = Date.now
        switch range {
        case .today:
            let fresh = await appState.stats.today(now: at)
            guard !Task.isCancelled else { return }
            today = fresh
            appState.lastTodayInsights = fresh
        case .week:
            let streak = appState.menuStats.streak
            if weekOffset == 0 {
                let fresh = await appState.stats.week(streak: streak, now: at)
                guard !Task.isCancelled else { return }
                week = fresh
                appState.lastWeekInsights = fresh
            } else {
                let date = Calendar.current.date(byAdding: .weekOfYear, value: weekOffset, to: at) ?? at
                let fresh = await appState.stats.week(streak: streak, containing: date, now: at)
                guard !Task.isCancelled else { return }
                week = fresh
            }
        }
        now = at
    }

    private func reload() {
        Task { await load() }
    }

    // MARK: - Content

    private var todayContent: some View {
        InsightsTodayView(
            today: today, now: now,
            onRename: { summary, name in
                if let session = appState.session(summary.modelID) { appState.sessionManager.rename(session, to: name) }
                reload()
            },
            onDelete: { summary in
                if let session = appState.session(summary.modelID) { appState.sessionManager.delete(session) }
                reload()
            },
            onCategory: { row, c in
                appState.setCategory(c, for: row)
                reload()
            }
        )
    }

    private var weekContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            InsightsWeekView(week: week, weekOffset: $weekOffset, canGoBack: canGoBack, now: now)

            if FeatureFlags.coach, weekOffset >= -1 {
                if entitlements.isUnlocked(.coach) {
                    ProRow(title: "Weekly coach", detail: CoachWords.rowDetail(coach), systemImage: "sparkles") {
                        openPane(.coach)
                    }
                    .task { await coach.refresh() }
                } else if appState.sessionManager.currentSession == nil {
                    LockedProRow(feature: .coach, title: "Weekly coach", detail: CoachWords.pitch,
                                 systemImage: "sparkles", onTrialStarted: { openPane(.coach) })
                }
            }
        }
    }

    /// Free keeps 30 days of history; earlier weeks need Pro.
    private var canGoBack: Bool {
        guard weekOffset > -52 else { return false }
        guard let start = entitlements.historyStart(),
              let previous = Calendar.current.date(byAdding: .weekOfYear, value: -1, to: week.weekStart) else { return true }
        return previous >= start
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if range == .week {
                Button("Export CSV") {
                    dismiss()
                    NSApp.activate(ignoringOtherApps: true)
                    let start = week.weekStart == .distantPast
                        ? Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start : week.weekStart
                    let end = start.flatMap { Calendar.current.date(byAdding: .day, value: 7, to: $0) }
                    DataExporter.export(.csv, container: appState.container, from: start, to: min(end ?? .now, .now))
                }
                .buttonStyle(.textLink)
            }
            Spacer()
            Button("Open full report ›") {
                dismiss()
                onOpenMain(.reports)
            }
            .buttonStyle(.textLink)
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - Today

/// Today: the lead sentence, the focus rate split in and between sessions,
/// the sessions by name, and the top apps and sites.
struct InsightsTodayView: View {
    let today: TodayInsights
    let now: Date
    var onRename: (SessionSummary, String) -> Void = { _, _ in }
    var onDelete: (SessionSummary) -> Void = { _ in }
    var onCategory: (UsageRow, Classification) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let takeaway = today.takeaway {
                Takeaway(text: takeaway)
            }

            rateCard

            if !today.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    paneHeading("Sessions", note: "named by how they went")
                    ForEach(today.sessions.prefix(4).reversed()) { summary in
                        SessionRow(summary: summary, now: now, runningDetail: "named when it ends",
                                   onRename: { onRename(summary, $0) }, onDelete: { onDelete(summary) })
                    }
                }
            }

            if !today.topApps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    paneHeading("Top apps & sites today")
                    ForEach(today.topApps) { row in
                        HStack(spacing: 8) {
                            AppGlyph(kind: row.isSite ? .generic : AppGlyph.kind(forBundleId: row.bundleId, name: row.name),
                                     bundleId: row.isSite ? nil : row.bundleId, host: row.host, size: 18)
                            Text(row.name)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(formatDuration(row.seconds))
                                .font(.system(size: 12).monospacedDigit())
                                .frame(width: 52, alignment: .trailing)
                            CategoryChipMenu(current: row.classification) { onCategory(row, $0) }
                                .frame(width: 92, alignment: .trailing)
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
        }
    }

    /// The fair focus rate, split into time in sessions and between them.
    private var rateCard: some View {
        let all = BreakdownSnapshot(focus: today.inSessions.focus + today.betweenSessions.focus,
                                    neutral: today.inSessions.neutral + today.betweenSessions.neutral,
                                    distraction: today.inSessions.distraction + today.betweenSessions.distraction)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Focus rate")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                Text(all.focus + all.distraction > 0 ? "\(Int((all.focusRate * 100).rounded()))%" : "–")
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .kerning(-0.4)
                Spacer(minLength: 4)
                Text("focused ÷ (focused + drifted)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            HStack(alignment: .top, spacing: 12) {
                SplitColumn(title: "In sessions", snapshot: today.inSessions)
                SplitColumn(title: "Between", snapshot: today.betweenSessions)
            }
            Text("Other time — chat, mail, calls — is left out of the rate.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .paneCard()
    }
}

// MARK: - Week

/// A week: which one, the lead sentence, three tiles, focus per day and the
/// top distractions.
struct InsightsWeekView: View {
    let week: WeekInsights
    @Binding var weekOffset: Int
    let canGoBack: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            weekNavigator

            if let takeaway = week.takeaway {
                Takeaway(text: takeaway)
            }

            HStack(spacing: 6) {
                StatTile(label: "Focused", value: formatDuration(week.focused), detail: weekDelta)
                StatTile(label: "Focus rate", value: "\(Int((week.focusRate * 100).rounded()))%", detail: bestDayText)
                if weekOffset == 0 {
                    StatTile(label: "Streak", value: counted(week.streak, "day"), detail: "goal met")
                } else {
                    StatTile(label: "Goal met", value: counted(goalDays, "day"), detail: "of 7")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Per day")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.primaryText.opacity(0.85))
                    Spacer()
                    HStack(spacing: 4) {
                        Rectangle()
                            .stroke(Theme.focus, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                            .frame(width: 12, height: 0.5)
                        Text("\(FocusGoal.format(minutes: FocusGoal.dailyMinutes)) goal")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
                }
                WeekBars(insights: week, goalMinutes: FocusGoal.dailyMinutes)
                    .frame(height: 128)
            }
            .paneCard(padding: EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12))

            if !week.topDistractions.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    paneHeading("Top distractions")
                    let maxSeconds = week.topDistractions.map(\.seconds).max() ?? 1
                    ForEach(week.topDistractions) { row in
                        HStack(spacing: 10) {
                            Text(row.name)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            LimitBar(fraction: row.seconds / max(1, maxSeconds))
                                .frame(width: 96)
                            Text(formatDuration(row.seconds))
                                .font(.system(size: 12).monospacedDigit())
                                .frame(width: 48, alignment: .trailing)
                        }
                        .padding(.horizontal, 2)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var weekNavigator: some View {
        HStack(spacing: 6) {
            RoundIconButton(systemImage: "chevron.left", label: "Previous week") { weekOffset -= 1 }
                .disabled(!canGoBack)
            Text(weekTitle)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
            RoundIconButton(systemImage: "chevron.right", label: "Next week") { weekOffset += 1 }
                .disabled(weekOffset >= 0)
        }
    }

    /// "This week · 19–25 Oct", "Last week · …", or just the dates.
    private var weekTitle: String {
        let start = week.weekStart == .distantPast ? (Calendar.current.dateInterval(of: .weekOfYear, for: now)?.start ?? now) : week.weekStart
        let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start
        let range = (start..<end.addingTimeInterval(1)).formatted(.interval.day().month(.abbreviated))
        switch weekOffset {
        case 0:  return "This week · \(range)"
        case -1: return "Last week · \(range)"
        default: return range
        }
    }

    private var weekDelta: String {
        guard week.focusedLastWeek > 60 else { return "no data the week before" }
        let delta = week.focused - week.focusedLastWeek
        return "\(delta >= 0 ? "+" : "−")\(formatDuration(abs(delta))) vs last"
    }

    private var bestDayText: String {
        guard let day = week.bestDay else { return weekOffset == 0 ? "this week" : "that week" }
        let rate = week.bestDayRate.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
        return "best \(day.formatted(.dateTime.weekday(.abbreviated)))\(rate)"
    }

    private var goalDays: Int {
        week.days.filter { $0.focus >= FocusGoal.dailySeconds }.count
    }
}

// MARK: - Pieces

/// The pane's lead sentence.
struct Takeaway: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }
}

/// Today in sessions, or between them: the rate, a bar of what the time
/// was, and how long.
private struct SplitColumn: View {
    let title: String
    let snapshot: BreakdownSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 2)
                Text(snapshot.focus + snapshot.distraction > 0
                     ? "\(FocusRate.percent(focused: snapshot.focus, drifted: snapshot.distraction))%" : "–")
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .semibold))

            GeometryReader { geo in
                let parts: [(TimeInterval, Color)] = [(snapshot.focus, Theme.focus),
                                                      (snapshot.distraction, Theme.distraction),
                                                      (snapshot.neutral, Theme.other)].filter { $0.0 > 0 }
                let gaps = CGFloat(max(0, parts.count - 1))
                HStack(spacing: 1) {
                    if parts.isEmpty {
                        Rectangle().fill(Theme.control)
                    }
                    ForEach(parts.indices, id: \.self) { i in
                        Rectangle().fill(parts[i].1)
                            .frame(width: max(1, (geo.size.width - gaps) * CGFloat(parts[i].0 / max(1, snapshot.total))))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            .accessibilityHidden(true)

            Text("\(formatDuration(snapshot.total)) · \(formatDuration(snapshot.distraction)) drift")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(formatDuration(snapshot.focus)) focused, "
                            + "\(formatDuration(snapshot.distraction)) drifted, \(formatDuration(snapshot.neutral)) other")
    }
}

/// Focus per day of the week, stacked with drift and other time, against
/// the daily goal. Days still to come are dashed outlines.
struct WeekBars: View {
    let insights: WeekInsights
    let goalMinutes: Int

    @State private var hovered: Int?

    var body: some View {
        let days = insights.days
        let maxMinutes = max(Double(goalMinutes) * 1.6, days.map { $0.total / 60 }.max() ?? 0)

        GeometryReader { geo in
            let plotHeight = geo.size.height - 16
            let step = geo.size.width / CGFloat(max(1, days.count))
            let barWidth = max(4, step - 8)
            let scale = plotHeight / CGFloat(max(1, maxMinutes))

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for (i, day) in days.enumerated() {
                        let x = CGFloat(i) * step + (step - barWidth) / 2
                        if i > insights.todayIndex {
                            let h = CGFloat(goalMinutes) * scale
                            context.stroke(Path(roundedRect: CGRect(x: x, y: plotHeight - h, width: barWidth, height: h), cornerRadius: 3),
                                           with: .color(Theme.gridFuture), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            continue
                        }
                        var y = plotHeight
                        let parts: [(TimeInterval, Color)] = [(day.focus, Theme.focus), (day.distraction, Theme.distraction),
                                                              (day.neutral, Theme.gridFuture)]
                        let drawn = parts.filter { $0.0 > 0 }
                        for (k, part) in drawn.enumerated() {
                            let h = CGFloat(part.0 / 60) * scale
                            let rect = CGRect(x: x, y: y - h, width: barWidth, height: max(0, h - (k == drawn.count - 1 ? 0 : 1)))
                            let radii = RectangleCornerRadii(topLeading: k == drawn.count - 1 ? 3 : 0,
                                                             bottomLeading: k == 0 ? 3 : 0,
                                                             bottomTrailing: k == 0 ? 3 : 0,
                                                             topTrailing: k == drawn.count - 1 ? 3 : 0)
                            context.fill(Path(roundedRect: rect, cornerRadii: radii),
                                         with: .color(part.1.opacity(hovered == nil || hovered == i ? 1 : 0.45)))
                            y -= h
                        }
                    }
                    let gy = plotHeight - CGFloat(goalMinutes) * scale
                    var goal = Path()
                    goal.move(to: CGPoint(x: 0, y: gy))
                    goal.addLine(to: CGPoint(x: size.width, y: gy))
                    context.stroke(goal, with: .color(Theme.focus.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

                    for (i, day) in days.enumerated() {
                        let isToday = Calendar.current.isDateInToday(day.date)
                        let label = Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 10, weight: isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? Theme.primaryText : Theme.secondaryText)
                        context.draw(label, at: CGPoint(x: CGFloat(i) * step + step / 2, y: plotHeight + 9))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let i = Int(p.x / step)
                        hovered = (0...insights.todayIndex).contains(i) ? i : nil
                    case .ended:
                        hovered = nil
                    }
                }

                if let i = hovered, i < days.count {
                    let day = days[i]
                    VStack(alignment: .leading, spacing: 1) {
                        Text(day.date.formatted(.dateTime.weekday(.wide))).fontWeight(.semibold)
                        Text("\(formatDuration(day.focus)) focused · \(FocusRate.percent(focused: day.focus, drifted: day.distraction))% focus rate")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.regularMaterial))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                    .fixedSize()
                    .offset(x: min(max(0, CGFloat(i) * step + step / 2 - 70), geo.size.width - 170), y: 0)
                    .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Focus per day: " + days.prefix(insights.todayIndex + 1).map {
            "\($0.date.formatted(.dateTime.weekday(.wide))) \(formatDuration($0.focus))"
        }.joined(separator: ", "))
    }
}

/// Today / Week, as a small segmented switch with a raised white segment.
struct PaneTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                let on = value == selection
                Button { selection = value } label: {
                    Text(title)
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.primaryText : Theme.primaryText.opacity(0.8))
                        .padding(.horizontal, 12)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(on ? Theme.segment : .clear)
                            .shadow(color: .black.opacity(on ? 0.15 : 0), radius: 1, y: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.control))
        .fixedSize()
    }
}

/// A 22-pt round button with a symbol: week arrows, close.
struct RoundIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.control.opacity(isEnabled ? 1 : 0.5)))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A category as a tinted chip ("● Focus") that opens a menu to change it.
struct CategoryChipMenu: View {
    let current: Classification
    let onChange: (Classification) -> Void

    var body: some View {
        Menu {
            ForEach([Classification.focus, .neutral, .distraction], id: \.self) { c in
                Button {
                    if c != current { onChange(c) }
                } label: {
                    if c == current { Label(categoryName(c), systemImage: "checkmark") } else { Text(categoryName(c)) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(CategoryChip.dot(current)).frame(width: 6, height: 6)
                Text(categoryName(current))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.6)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(fill))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Category: \(categoryName(current))")
    }

    private var fill: Color {
        switch current {
        case .focus:       return Theme.focusTint
        case .neutral:     return Theme.chip
        case .distraction: return Theme.distractionTint
        }
    }

    /// Indigo text on the indigo chip; dark text on orange (orange never carries text).
    private var ink: Color {
        current == .focus ? Theme.link : Theme.primaryText
    }
}

func paneHeading(_ title: String, note: String? = nil) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.primaryText.opacity(0.85))
        Spacer(minLength: 4)
        if let note {
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        }
    }
    .padding(.horizontal, 2)
    .padding(.bottom, 2)
}

extension View {
    /// A card inside a side pane: brighter than the pane, radius 11.
    func paneCard(padding: EdgeInsets = EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12)) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
    }
}
