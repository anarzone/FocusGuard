import SwiftUI

/// The side panes that slide out next to the session column, so reports,
/// rules and common settings never need the main window.
enum MenuPane: String, CaseIterable, Identifiable {
    case insights, apps, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insights: return "Insights"
        case .apps:     return "Apps & sites"
        case .settings: return "Quick settings"
        }
    }

    var systemImage: String {
        switch self {
        case .insights: return "chart.bar.fill"
        case .apps:     return "square.grid.2x2.fill"
        case .settings: return "slider.horizontal.3"
        }
    }

    static let width: CGFloat = 348

    /// How a side pane comes in. The animation rides on the transition, not
    /// on the state change: the window resizes and shifts in one step, so the
    /// column has to land in its new place at once (an animated layout would
    /// slide it while the window had already moved, and it would jump). Only
    /// the pane itself slides and fades in.
    static func slide(from edge: Edge) -> AnyTransition {
        AnyTransition.move(edge: edge).combined(with: .opacity).animation(.snappy(duration: 0.22))
    }
}

/// Three round buttons in the menu header. Tapping the open one closes it.
struct PaneButtons: View {
    @Binding var open: MenuPane?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MenuPane.allCases) { pane in
                let isOpen = open == pane
                Button {
                    open = isOpen ? nil : pane   // not animated: see MenuPane.slide
                } label: {
                    Image(systemName: pane.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isOpen ? Color.white : Color.primary.opacity(0.75))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(isOpen ? Theme.focusFill : Theme.control))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Close \(pane.title)" : pane.title)
                .accessibilityLabel(pane.title)
                .accessibilityAddTraits(isOpen ? .isSelected : [])
            }
        }
    }
}

/// The pane container: title row with a close button, then content.
struct MenuPaneView: View {
    let pane: MenuPane
    @Bindable var appState: AppState
    let onOpenMain: (MainTab) -> Void
    let dismiss: () -> Void
    let close: () -> Void

    var body: some View {
        Group {
            switch pane {
            case .insights:
                InsightsPane(appState: appState, onOpenMain: onOpenMain, dismiss: dismiss, close: close)
            case .apps:
                AppsPane(appState: appState, close: close)
            case .settings:
                QuickSettingsPane(appState: appState, onOpenMain: onOpenMain, dismiss: dismiss, close: close)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(width: MenuPane.width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.module))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
    }
}

// MARK: - Shared bits

struct PaneTitle<Trailing: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 0)
            trailing()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.control))
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close \(title)")
        }
    }
}

struct StatTile: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit()).lineLimit(1)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.cardBackground))
        .accessibilityElement(children: .combine)
    }
}

func sectionLabel(_ text: String) -> some View {
    Text(text).font(.system(size: 12, weight: .semibold))
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds)) / 60
    let h = total / 60, m = total % 60
    if h == 0 { return "\(m)m" }
    if m == 0 { return "\(h)h" }
    return "\(h)h \(m)m"
}

func kindColor(_ classification: Classification) -> Color {
    switch classification {
    case .focus:       return Theme.focus
    case .neutral:     return Theme.other
    case .distraction: return Theme.distraction
    }
}

func categoryName(_ classification: Classification) -> String {
    switch classification {
    case .focus:       return "Focus"
    case .neutral:     return "Neutral"
    case .distraction: return "Distracting"
    }
}

/// Small chip that opens a menu to change an app's or site's category.
struct CategoryMenu: View {
    let current: Classification
    let onChange: (Classification) -> Void

    var body: some View {
        Menu {
            ForEach([Classification.focus, .neutral, .distraction], id: \.self) { c in
                Button {
                    onChange(c)
                } label: {
                    if c == current { Label(categoryName(c), systemImage: "checkmark") } else { Text(categoryName(c)) }
                }
            }
        } label: {
            Text("\(categoryName(current)) ▾")
                .font(.system(size: 11))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.control))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Category: \(categoryName(current))")
    }
}

/// Bar + time row used for top apps and top distractions.
struct UsageBarRow: View {
    let row: UsageRow
    let maxSeconds: TimeInterval
    var onChange: ((Classification) -> Void)?
    var nameWidth: CGFloat = 86
    var barWidth: CGFloat?

    var body: some View {
        HStack(spacing: 10) {
            Text(row.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: nameWidth, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.control)
                    Capsule().fill(kindColor(row.classification))
                        .frame(width: max(4, geo.size.width * CGFloat(row.seconds / max(1, maxSeconds))))
                }
            }
            .frame(width: barWidth ?? (onChange == nil ? 134 : 70), height: 6)
            .accessibilityHidden(true)
            Text(formatDuration(row.seconds))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 50, alignment: .trailing)
            Spacer(minLength: 0)
            if let onChange {
                CategoryMenu(current: row.classification, onChange: onChange)
            }
        }
    }
}

// MARK: - Insights

private enum InsightsRange: String, CaseIterable, Identifiable {
    case today = "Today", week = "Week"
    var id: String { rawValue }
}

private struct InsightsPane: View {
    @Bindable var appState: AppState
    let onOpenMain: (MainTab) -> Void
    let dismiss: () -> Void
    let close: () -> Void

    @State private var range: InsightsRange = .today
    @State private var today: TodayInsights = .empty
    @State private var week: WeekInsights = .empty
    @State private var now: Date = .now

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneTitle(title: "Insights", close: close) {
                Picker("Range", selection: $range) {
                    ForEach(InsightsRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }

            switch range {
            case .today: todayContent
            case .week:  weekContent
            }

            Spacer(minLength: 0)
            footer
        }
        .task(id: range) {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func reload() {
        now = .now
        let context = appState.container.mainContext
        switch range {
        case .today: today = MenuInsightsBuilder.today(context: context, now: now)
        case .week:  week = MenuInsightsBuilder.week(context: context, streak: appState.currentStreak, now: now)
        }
    }

    // Today

    private var todayContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                StatTile(label: "Focused", value: formatDuration(today.focused),
                         detail: "\(Int((today.goalProgress * 100).rounded()))% of goal")
                StatTile(label: "Focus rate", value: "\(Int((today.focusRate * 100).rounded()))%",
                         detail: rateDelta)
                StatTile(label: "Sessions", value: "\(today.sessions.count)",
                         detail: today.sessions.contains(where: \.isRunning) ? "1 running" : "today")
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionLabel("Your day")
                    Spacer()
                    Text("Sessions on top, activity below")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                DayTimelineView(insights: today, now: now)
                    .frame(height: 62)
            }

            if !today.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    sectionLabel("Sessions").padding(.bottom, 2)
                    ForEach(today.sessions.prefix(4)) { summary in
                        SessionRow(summary: summary, now: now,
                                   onRename: { appState.sessionManager.rename(summary.session, to: $0); reload() },
                                   onDelete: { appState.sessionManager.delete(summary.session); reload() })
                    }
                }
            }

            if !today.topApps.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    sectionLabel("Top apps & sites today")
                    let maxSeconds = today.topApps.map(\.seconds).max() ?? 1
                    ForEach(today.topApps) { row in
                        UsageBarRow(row: row, maxSeconds: maxSeconds) { c in
                            appState.setCategory(c, for: row)
                            reload()
                        }
                    }
                }
            }
        }
    }

    private var rateDelta: String {
        guard let avg = today.averageFocusRate, today.focused > 0 else { return "today" }
        let delta = Int(((today.focusRate - avg) * 100).rounded())
        return delta == 0 ? "same as avg" : "\(delta > 0 ? "+" : "−")\(abs(delta)) pts vs avg"
    }

    // Week

    private var weekContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                StatTile(label: "Focused", value: formatDuration(week.focused), detail: weekDelta)
                StatTile(label: "Focus rate", value: "\(Int((week.focusRate * 100).rounded()))%",
                         detail: week.bestDay.map { "Best day: \($0.formatted(.dateTime.weekday(.abbreviated)))" } ?? "this week")
                StatTile(label: "Streak", value: week.streak == 1 ? "1 day" : "\(week.streak) days",
                         detail: "goal met")
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    sectionLabel("Per day")
                    Spacer(minLength: 0)
                    legendSwatch(Theme.focus, "Focused")
                    legendSwatch(Theme.distraction, "Drifted")
                    legendSwatch(Theme.other, "Other")
                }
                WeekChartView(insights: week, goalMinutes: FocusGoal.dailyMinutes)
                    .frame(height: 156)
            }

            if !week.topDistractions.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    sectionLabel("Top distractions")
                    let maxSeconds = week.topDistractions.map(\.seconds).max() ?? 1
                    ForEach(week.topDistractions) { row in
                        UsageBarRow(row: row, maxSeconds: maxSeconds)
                    }
                }
            }
        }
    }

    private var weekDelta: String {
        guard week.focusedLastWeek > 60 else { return "no data last week" }
        let delta = week.focused - week.focusedLastWeek
        return "\(delta >= 0 ? "+" : "−")\(formatDuration(abs(delta))) vs last week"
    }

    private func legendSwatch(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title)
        }
        .font(.system(size: 11))
    }

    private var footer: some View {
        HStack {
            if range == .week {
                Button {
                    dismiss()
                    NSApp.activate(ignoringOtherApps: true)
                    let start = Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start
                    DataExporter.export(.csv, container: appState.container, from: start, to: .now)
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.down")
                        .font(.system(size: 12))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(Theme.control))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button("Open full report ›") {
                dismiss()
                onOpenMain(.reports)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.focus)
        }
    }
}

/// A session in the Insights list. Hover shows rename and delete; the running
/// session can't be deleted from here.
struct SessionRow: View {
    let summary: SessionSummary
    let now: Date
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmingDelete = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Theme.control, lineWidth: 4)
                Circle().trim(from: 0, to: summary.focusShare)
                    .stroke(Theme.focus, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                if editing {
                    TextField("Session name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .focused($fieldFocused)
                        .onSubmit(commit)
                        .onExitCommand { editing = false }
                } else {
                    Text(summary.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                Text(confirmingDelete ? "Delete this session? Activity stays in reports." : subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(confirmingDelete ? Theme.distractionInk : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if confirmingDelete {
                Button("Cancel") { confirmingDelete = false }
                    .buttonStyle(.plain).font(.system(size: 11))
                Button("Delete", role: .destructive) { onDelete() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
            } else if hovering && !editing {
                iconButton("pencil", "Rename session") {
                    draft = summary.label
                    editing = true
                    NSApp.activate(ignoringOtherApps: true)
                    fieldFocused = true
                }
                if !summary.isRunning {
                    iconButton("trash", "Delete session", tint: .red) { confirmingDelete = true }
                }
            } else {
                Text("\(Int((summary.focusShare * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering ? Theme.control : .clear))
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
    }

    private var subtitle: String {
        let start = summary.start.formatted(date: .omitted, time: .shortened)
        if summary.isRunning {
            let planned = summary.plannedMinutes.map { " of \($0)" } ?? ""
            return "\(start) – now · \(summary.minutes)\(planned) min"
        }
        let end = (summary.end ?? now).formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end) · \(summary.minutes) min"
    }

    private func commit() {
        onRename(draft)
        editing = false
    }

    private func iconButton(_ symbol: String, _ label: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.cardBackground))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Sessions on a thin top lane, activity coloured by kind below, a line at now.
struct DayTimelineView: View {
    let insights: TodayInsights
    let now: Date

    var body: some View {
        Canvas { context, size in
            let window = insights.window
            let w = size.width
            func x(_ date: Date) -> CGFloat {
                CGFloat(date.timeIntervalSince(window.start) / window.duration) * w
            }
            func bar(_ start: Date, _ end: Date, y: CGFloat, h: CGFloat) -> Path {
                let x0 = max(0, x(start)), x1 = min(w, x(end))
                return Path(CGRect(x: x0, y: y, width: max(1, x1 - x0 - 0.5), height: h))
            }

            // Lanes scale with the frame: sessions on a thin lane, activity below, labels under.
            let activityHeight = max(18, (size.height - 26) * 0.6)
            let sessionHeight = activityHeight / 2
            let activityY = 2 + sessionHeight + 5
            let labelY = activityY + activityHeight + 12

            context.fill(Path(roundedRect: CGRect(x: 0, y: activityY, width: w, height: activityHeight), cornerRadius: 4),
                         with: .color(Theme.control))
            for span in insights.sessionSpans {
                context.fill(bar(span.start, span.end, y: 2, h: sessionHeight), with: .color(Theme.focus.opacity(0.85)))
            }
            for span in insights.activity {
                context.fill(bar(span.start, span.end, y: activityY, h: activityHeight), with: .color(SessionRingView<EmptyView>.color(span.kind)))
            }
            let nx = x(now)
            if nx >= 0, nx <= w {
                context.fill(Path(CGRect(x: nx - 0.75, y: 0, width: 1.5, height: activityY + activityHeight + 4)), with: .color(.primary))
            }

            // Hour labels every two hours.
            let calendar = Calendar.current
            var tick = calendar.nextDate(after: window.start.addingTimeInterval(-1),
                                         matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? window.start
            while tick <= window.end {
                let hour = calendar.component(.hour, from: tick)
                if hour % 2 == 0 {
                    let label = Text(tick.formatted(.dateTime.hour()))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    let px = x(tick)
                    let anchor: UnitPoint = px < 12 ? .leading : (px > w - 12 ? .trailing : .center)
                    context.draw(label, at: CGPoint(x: px, y: labelY), anchor: anchor)
                }
                tick = tick.addingTimeInterval(3600)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Day timeline: \(insights.sessions.count) sessions, \(formatDuration(insights.focused)) focused")
    }
}

/// Stacked bars per day of the week against the daily goal, with a hover tooltip.
private struct WeekChartView: View {
    let insights: WeekInsights
    let goalMinutes: Int

    @State private var hovered: Int?

    var body: some View {
        let days = insights.days
        let maxMinutes = max(Double(goalMinutes) * 1.25, days.map { $0.total / 60 }.max() ?? 0)

        GeometryReader { geo in
            let plotHeight = geo.size.height - 18
            let step = geo.size.width / CGFloat(max(1, days.count))
            let barWidth = min(28, step * 0.6)
            let scale = plotHeight / CGFloat(maxMinutes)

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    context.fill(Path(CGRect(x: 0, y: plotHeight, width: geo.size.width, height: 1)),
                                 with: .color(.primary.opacity(0.18)))
                    for (i, day) in days.enumerated() {
                        let x = CGFloat(i) * step + (step - barWidth) / 2
                        if i > insights.todayIndex {
                            let h = CGFloat(goalMinutes) * scale
                            context.stroke(Path(CGRect(x: x, y: plotHeight - h, width: barWidth, height: h)),
                                           with: .color(.primary.opacity(0.14)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            continue
                        }
                        var y = plotHeight
                        let parts: [(TimeInterval, Color)] = [(day.focus, Theme.focus), (day.distraction, Theme.distraction), (day.neutral, Theme.other)]
                        let lastIndex = parts.lastIndex { $0.0 > 0 }
                        for (k, part) in parts.enumerated() where part.0 > 0 {
                            let h = CGFloat(part.0 / 60) * scale
                            let isTop = k == lastIndex
                            let rect = CGRect(x: x, y: y - h, width: barWidth, height: max(0, h - (isTop ? 0 : 2)))
                            let path = isTop
                                ? Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(topLeading: 4, topTrailing: 4))
                                : Path(rect)
                            context.fill(path, with: .color(part.1.opacity(hovered == nil || hovered == i ? 1 : 0.45)))
                            y -= h
                        }
                    }
                    let gy = plotHeight - CGFloat(goalMinutes) * scale
                    var goal = Path()
                    goal.move(to: CGPoint(x: 0, y: gy))
                    goal.addLine(to: CGPoint(x: geo.size.width, y: gy))
                    context.stroke(goal, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

                    for (i, day) in days.enumerated() {
                        let label = Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 10, weight: i == insights.todayIndex ? .semibold : .regular))
                            .foregroundStyle(i == insights.todayIndex ? Color.primary : Color.secondary)
                        context.draw(label, at: CGPoint(x: CGFloat(i) * step + step / 2, y: plotHeight + 10))
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
                        Text("\(formatDuration(day.focus)) focused · \(day.total > 0 ? Int((day.focus / day.total * 100).rounded()) : 0)%")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.regularMaterial))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                    .fixedSize()
                    .offset(x: min(max(0, CGFloat(i) * step + step / 2 - 60), geo.size.width - 130), y: 0)
                    .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Focus per day this week: \(formatDuration(insights.focused)) so far, goal \(FocusGoal.format(minutes: goalMinutes)) a day")
    }
}

// MARK: - Apps & sites

struct AppsPane: View {
    @Bindable var appState: AppState
    /// Nil in the main window, which has its own title.
    var close: (() -> Void)?
    /// Fixed list height in the menu; nil fills the space available.
    var listHeight: CGFloat? = 300

    @State private var rows: [UsageRow] = []
    @State private var rules: [AppRule] = []
    @State private var query = ""
    @State private var filter: Classification?
    @State private var newSite = ""
    @State private var addFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let close {
                PaneTitle(title: "Apps & sites", close: close) { EmptyView() }
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps and sites", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onTapGesture { NSApp.activate(ignoringOtherApps: true) }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.cardBackground))

            HStack(spacing: 6) {
                filterChip(nil, "All")
                filterChip(.focus, "Focus \(count(.focus))")
                filterChip(.neutral, "Neutral \(count(.neutral))")
                filterChip(.distraction, "Distracting \(count(.distraction))")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !visibleRows.isEmpty {
                        Text("Used today").font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 2)
                        ForEach(visibleRows) { row in
                            AppRuleRow(
                                title: row.name,
                                subtitle: "\(row.isSite ? "Site" : "App") · \(formatDuration(row.seconds)) today",
                                bundleId: row.isSite ? nil : row.bundleId,
                                host: row.host,
                                classification: row.classification,
                                onChange: { c in appState.setCategory(c, for: row); reload() },
                                onDelete: nil
                            )
                        }
                    }
                    if !visibleRules.isEmpty {
                        Text("Your rules").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 8).padding(.bottom, 2)
                        ForEach(visibleRules, id: \.id) { rule in
                            AppRuleRow(
                                title: rule.pattern,
                                subtitle: "\(rule.matchKind.label) · your rule",
                                bundleId: rule.matchKind == .bundleId ? rule.pattern : nil,
                                host: rule.matchKind == .host ? rule.pattern : nil,
                                classification: rule.classification,
                                onChange: { c in
                                    if rule.matchKind == .host {
                                        appState.classifier.setOverride(host: rule.pattern, classification: c)
                                    } else if rule.matchKind == .bundleId {
                                        appState.classifier.setOverride(bundleId: rule.pattern, classification: c)
                                    }
                                    reload()
                                },
                                onDelete: { appState.deleteRule(rule); reload() }
                            )
                        }
                    }
                    if visibleRows.isEmpty && visibleRules.isEmpty {
                        Text(query.isEmpty ? "Nothing tracked yet today." : "No matches for “\(query)”.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 6)
            }
            .padding(.horizontal, -6)
            .frame(height: listHeight)
            .frame(maxHeight: listHeight == nil ? .infinity : nil)

            HStack(spacing: 6) {
                TextField("Add a distracting site, e.g. reddit.com", text: $newSite)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.cardBackground))
                    .onTapGesture { NSApp.activate(ignoringOtherApps: true) }
                    .onSubmit(add)
                Button(action: add) {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.focus)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Capsule().fill(Theme.focusTint))
                }
                .buttonStyle(.plain)
                .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(addFailed ? "That doesn't look like a site. Try something like example.com."
                           : "Changing a category also updates past activity in your reports.")
                .font(.system(size: 11))
                .foregroundStyle(addFailed ? Theme.distractionInk : .secondary)
        }
        .task { reload() }
    }

    private func reload() {
        let now = Date.now
        rows = MenuInsightsBuilder.usageRows(context: appState.container.mainContext,
                                             from: Calendar.current.startOfDay(for: now), to: now, limit: 40)
        rules = appState.userRules()
    }

    private func add() {
        addFailed = !appState.addSiteRule(newSite, classification: .distraction)
        if !addFailed { newSite = ""; reload() }
    }

    private func matches(_ text: String) -> Bool {
        query.isEmpty || text.localizedCaseInsensitiveContains(query)
    }

    private var visibleRows: [UsageRow] {
        rows.filter { matches($0.name) && (filter == nil || $0.classification == filter) }
    }

    /// Rules for things not already listed under "Used today".
    private var visibleRules: [AppRule] {
        let listed = Set(rows.map { $0.host ?? $0.bundleId })
        return rules.filter { !listed.contains($0.pattern) && matches($0.pattern) && (filter == nil || $0.classification == filter) }
    }

    private func count(_ c: Classification) -> Int {
        rows.filter { $0.classification == c }.count
    }

    private func filterChip(_ value: Classification?, _ title: String) -> some View {
        let selected = filter == value
        return Button { filter = value } label: {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor) : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(selected ? Color.primary : Theme.control))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct AppRuleRow: View {
    let title: String
    let subtitle: String
    let bundleId: String?
    let host: String?
    let classification: Classification
    let onChange: (Classification) -> Void
    let onDelete: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            AppGlyph(kind: bundleId.map { AppGlyph.kind(forBundleId: $0, name: title) } ?? .generic,
                     bundleId: bundleId, host: host, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            CategoryPicker(selection: classification, onChange: onChange)
                .fixedSize()
            if let onDelete, hovering {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.cardBackground))
                }
                .buttonStyle(.plain)
                .help("Delete rule")
                .accessibilityLabel("Delete rule for \(title)")
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering ? Theme.control : .clear))
        .onHover { hovering = $0 }
    }
}

/// Three-way Focus / Neutral / Distracting switch, coloured by kind.
struct CategoryPicker: View {
    let selection: Classification
    let onChange: (Classification) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(.focus, "Focus", fill: Theme.focusFill, text: .white)
            segment(.neutral, "Neutral", fill: Theme.cardBackground, text: .primary)
            segment(.distraction, "Distr.", fill: Theme.distraction, text: .black)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.control))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Category")
    }

    private func segment(_ value: Classification, _ title: String, fill: Color, text: Color) -> some View {
        let on = selection == value
        return Button { if !on { onChange(value) } } label: {
            Text(title)
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(on ? text : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? fill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(categoryName(value))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Quick settings

private struct QuickSettingsPane: View {
    @Bindable var appState: AppState
    let onOpenMain: (MainTab) -> Void
    let dismiss: () -> Void
    let close: () -> Void

    @AppStorage(SessionDefaultsKey.durationMinutes) private var defaultMinutes = 50
    @AppStorage("menu.lastSessionMinutes") private var lastSessionMinutes = 0
    @AppStorage(SettingsKeys.Goal.dailyFocusMinutes) private var goalMinutes = GoalDefaults.dailyFocusMinutes
    @AppStorage(SettingsKeys.retentionDays) private var retentionDays = 365
    /// Master switch, shared with Settings → General.
    @AppStorage(SettingsKeys.showNotifications) private var showNotifications = true
    @AppStorage(SettingsKeys.menuBarShowTime) private var menuBarShowTime = true

    @State private var drift: DriftResponse? = DriftResponse.current
    @State private var launchAtLogin = LoginItemController.isEnabled
    @State private var confirm: Confirm?

    private enum Confirm { case today, all }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PaneTitle(title: "Quick settings", close: close) { EmptyView() }
                .padding(.bottom, 6)

            caption("Sessions")
            group {
                row("Default length") {
                    Picker("Default length", selection: Binding(
                        get: { defaultMinutes },
                        set: { defaultMinutes = $0; lastSessionMinutes = $0 }
                    )) {
                        ForEach(lengthChoices, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                }
                divider
                row("Daily focus goal") {
                    Stepper(value: $goalMinutes, in: 15...720, step: 15) {
                        Text(FocusGoal.format(minutes: goalMinutes))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    }
                    .controlSize(.small)
                }
            }

            caption("When you drift")
            group {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Response", selection: Binding(
                        get: { drift },
                        set: { value in
                            drift = value
                            value?.apply(to: appState.escalationEngine)
                        }
                    )) {
                        ForEach(DriftResponse.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    .frame(maxWidth: .infinity)
                    Text(drift?.summary ?? "Custom — tuned in Settings → Escalation")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                divider
                row("Start sessions from calendar",
                    detail: appState.calendarAutostart.hasCalendarAccess ? nil : "Needs calendar access — set up in Settings") {
                    Toggle("", isOn: Binding(
                        get: { appState.calendarAutostart.enabled },
                        set: { appState.calendarAutostart.enabled = $0 }
                    ))
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                    .disabled(!appState.calendarAutostart.hasCalendarAccess)
                }
                divider
                row("Launch at login") {
                    Toggle("", isOn: Binding(
                        get: { launchAtLogin },
                        set: { LoginItemController.setEnabled($0); launchAtLogin = LoginItemController.isEnabled }
                    ))
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                }
                divider
                row("Notifications", detail: "Nudges, session updates, daily wrap-up") {
                    Toggle("", isOn: $showNotifications)
                        .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                }
                divider
                row("Show time in menu bar", detail: "Minutes left, like “24m”") {
                    Toggle("", isOn: $menuBarShowTime)
                        .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                }
            }

            caption("Permissions")
            group {
                permissionRow("Screen Recording", appState.permissions.screenRecording) { appState.permissions.requestScreenRecording() }
                divider
                permissionRow("Notifications", appState.permissions.notifications) {
                    Task { await appState.permissions.requestNotifications() }
                }
            }

            caption("Data")
            group {
                row("Keep history") {
                    Picker("Keep history", selection: $retentionDays) {
                        ForEach(RetentionPolicy.choices, id: \.days) { Text($0.label).tag($0.days) }
                    }
                    .labelsHidden().controlSize(.small).fixedSize()
                }
                divider
                destructiveRow(.today, "Delete today's activity…",
                               confirmText: "Delete everything tracked today?") {
                    DataEraser.deleteToday(appState: appState)
                }
                divider
                destructiveRow(.all, "Erase all FocusGuard data…",
                               confirmText: "Erase all history, sessions and rules?") {
                    DataEraser.eraseAll(appState: appState)
                }
            }

            Spacer(minLength: 6)
            HStack {
                Text("Changes save instantly.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("All settings ›") {
                    dismiss()
                    onOpenMain(.settings)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.focus)
            }
        }
        .task { await appState.permissions.refresh() }
    }

    private var lengthChoices: [Int] {
        [25, 50, 90].contains(defaultMinutes) ? [25, 50, 90] : [25, 50, 90, defaultMinutes].sorted()
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 4)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.cardBackground))
    }

    private var divider: some View {
        Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 12)
    }

    private func row<Control: View>(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            control()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .padding(.vertical, 2)
    }

    private func permissionRow(_ title: String, _ status: PermissionStatus, request: @escaping () -> Void) -> some View {
        row(title) {
            if status == .granted {
                Label("Allowed", systemImage: "checkmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Button("Allow…", action: request)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .tint(Theme.focusFill)
            }
        }
    }

    @ViewBuilder
    private func destructiveRow(_ kind: Confirm, _ title: String, confirmText: String, action: @escaping () -> Void) -> some View {
        if confirm == kind {
            HStack(spacing: 8) {
                Text(confirmText).font(.system(size: 12)).lineLimit(2)
                Spacer(minLength: 4)
                Button("Cancel") { confirm = nil }.controlSize(.small)
                Button("Delete", role: .destructive) {
                    action()
                    confirm = nil
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        } else {
            Button {
                confirm = kind
            } label: {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
