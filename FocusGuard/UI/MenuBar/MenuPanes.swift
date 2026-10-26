import SwiftUI

/// The side panes that slide out next to the session column, so reports,
/// rules and common settings never need the main window. The Pro panes
/// (debrief, coach) open from rows, not from the header.
enum MenuPane: String, CaseIterable, Identifiable {
    case insights, apps, settings, debrief, coach

    var id: String { rawValue }

    /// The three with a button in the header.
    static let header: [MenuPane] = [.insights, .apps, .settings]

    var title: String {
        switch self {
        case .insights: return "Insights"
        case .apps:     return "Apps & sites"
        case .settings: return "Quick settings"
        case .debrief:  return "Debrief"
        case .coach:    return "Weekly coach"
        }
    }

    var systemImage: String {
        switch self {
        case .insights: return "chart.bar.fill"
        case .apps:     return "square.grid.2x2.fill"
        case .settings: return "slider.horizontal.3"
        case .debrief, .coach: return "sparkles"
        }
    }

    static let width: CGFloat = 348

    /// How a side pane comes in. The animation rides on the transition, not
    /// on the state change: the window resizes and shifts in one step, so the
    /// column has to land in its new place at once (an animated layout would
    /// slide it while the window had already moved, and it would jump). Only
    /// the pane itself slides and fades in (or only fades, with reduced motion).
    static func slide(from edge: Edge, reduceMotion: Bool = false) -> AnyTransition {
        Motion.transition(.move(edge: edge).combined(with: .opacity), reduced: reduceMotion)
            .animation(.snappy(duration: 0.22))
    }
}

/// Three round buttons in the menu header. Tapping the open one closes it.
struct PaneButtons: View {
    @Binding var open: MenuPane?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MenuPane.header) { pane in
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

/// The pane container: title row with a close button, then content, on a
/// surface a step lighter than the column's modules.
struct MenuPaneView: View {
    let pane: MenuPane
    @Bindable var appState: AppState
    let onOpenMain: (MainTab) -> Void
    let dismiss: () -> Void
    /// Switches to another pane (Insights › Weekly coach).
    var open: (MenuPane) -> Void = { _ in }
    let close: () -> Void

    var body: some View {
        Group {
            switch pane {
            case .insights:
                InsightsPane(appState: appState, onOpenMain: onOpenMain, dismiss: dismiss, close: close, openPane: open)
            case .apps:
                MenuAppsPane(appState: appState, close: close)
            case .settings:
                QuickSettingsPane(appState: appState, onOpenMain: onOpenMain, dismiss: dismiss, close: close)
            case .debrief:
                // Filled in by Pro AI later; only reachable with FeatureFlags.debrief on.
                DebriefPane(debrief: nil, close: close)
            case .coach:
                WeeklyCoachPane(close: close, seeWeek: { open(.insights) })
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(width: MenuPane.width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(MenuPalette.pane))
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
            RoundIconButton(systemImage: "xmark", label: "Close \(title)", action: close)
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

/// "1 day", "3 days": a count with its noun in the right number.
func counted(_ count: Int, _ noun: String, plural: String? = nil) -> String {
    "\(count) \(count == 1 ? noun : plural ?? noun + "s")"
}

func kindColor(_ classification: Classification) -> Color {
    switch classification {
    case .focus:       return Theme.focus
    case .neutral:     return Theme.other
    case .distraction: return Theme.distraction
    }
}

/// The one name for each category, wherever it's shown. (Time spent in
/// distracting apps is "Drifted" in charts.)
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

// MARK: - Sessions

/// A session in the Insights list. Hover shows rename and delete; the running
/// session can't be deleted from here.
struct SessionRow: View {
    let summary: SessionSummary
    let now: Date
    /// Replaces the running session's minutes ("named when it ends").
    var runningDetail: String?
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
            if let runningDetail { return "\(start)–now · \(runningDetail)" }
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
        .accessibilityLabel("Day timeline: \(counted(insights.sessions.count, "session")), \(formatDuration(insights.focused)) focused")
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
    @State private var loadedRows = false
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
                filterChip(.focus, "\(categoryName(.focus)) \(count(.focus))")
                filterChip(.neutral, "\(categoryName(.neutral)) \(count(.neutral))")
                filterChip(.distraction, "\(categoryName(.distraction)) \(count(.distraction))")
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

    /// Apps by time build off the main thread; until they arrive the pane
    /// shows the last ones.
    private func reload() {
        rules = appState.userRules()
        if !loadedRows, let cached = appState.lastUsageRows { rows = cached }
        let now = Date.now
        Task {
            let fresh = await appState.stats.usageRows(from: Calendar.current.startOfDay(for: now), to: now, limit: 40)
            rows = fresh
            loadedRows = true
            appState.lastUsageRows = fresh
        }
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
            segment(.focus, fill: Theme.focusFill, text: .white)
            segment(.neutral, fill: Theme.cardBackground, text: .primary)
            segment(.distraction, fill: Theme.distraction, text: .black)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.control))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Category")
    }

    private func segment(_ value: Classification, fill: Color, text: Color) -> some View {
        let on = selection == value
        return Button { if !on { onChange(value) } } label: {
            Text(categoryName(value))
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(on ? text : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? fill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(categoryName(value))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
