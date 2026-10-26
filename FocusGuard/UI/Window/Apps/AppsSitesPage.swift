import SwiftData
import SwiftUI

/// Apps & Sites: what was used and how it counts, the rules behind it,
/// and "Sort your apps".
struct AppsSitesPage: View {
    @Bindable var appState: AppState
    @Binding var mode: AppsMode

    @State private var range: AppsRange = .week
    @State private var search = ""
    @State private var filter: Classification?
    @State private var items: [AppsItem] = []
    @State private var rules: [AppRule] = []
    @State private var selection: String?
    @State private var newRule: NewRuleDraft?

    init(appState: AppState, mode: Binding<AppsMode>) {
        self._appState = Bindable(wrappedValue: appState)
        self._mode = mode
        // Open on the apps as last loaded; the fresh copy follows.
        if let cached = appState.windowPages.apps[.week] {
            self._items = State(initialValue: cached)
            self._selection = State(initialValue: cached.first?.id)
        }
    }

    private var context: ModelContext { appState.container.mainContext }
    private var entitlements: Entitlements { .shared }
    /// Smart categories, while they're built and unlocked.
    private var smart: SmartCategories? { Self.smart(appState) }

    static func smart(_ appState: AppState) -> SmartCategories? {
        FeatureFlags.smartCategories && Entitlements.shared.isUnlocked(.smartCategories) ? appState.smartCategories : nil
    }

    var body: some View {
        Group {
            if mode == .sort {
                SortAppsView(appState: appState, items: AppsModelBuilder.toSort(items), range: range,
                             onDone: { mode = .used; reload() },
                             onMakeRule: { item in newRule = NewRuleDraft(item: item) })
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if mode == .used { used } else { rulesList }
                }
                .padding(.leading, 16)
                .padding(.trailing, 24)
                .padding(.bottom, 20)
            }
        }
        .task(id: range) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .activityTotalsChanged)) { _ in reload() }
        .sheet(item: $newRule) { draft in
            NewRuleSheet(appState: appState, draft: draft) { reload() }
        }
    }

    private func reload() {
        Task { await load() }
    }

    /// Reads usage off the main thread (a month of it takes a few hundred
    /// milliseconds); a range switched to shows its last copy, if any, until then.
    private func load() async {
        let range = range
        if let cached = appState.windowPages.apps[range] { show(cached) }
        let now = Date.now
        let rows = await appState.stats.usageRows(from: range.start(now: now), to: now,
                                                  limit: AppsModelBuilder.usageLimit)
        guard !Task.isCancelled, range == self.range else { return }
        let fresh = AppsModelBuilder.items(rows: rows, classifier: appState.classifier, smart: smart)
        appState.windowPages.apps[range] = fresh
        show(fresh)
    }

    private func show(_ items: [AppsItem]) {
        self.items = items
        let descriptor = FetchDescriptor<AppRule>(sortBy: [SortDescriptor(\.priority, order: .reverse)])
        rules = Persistence.fetch(context, descriptor)
        if selection == nil || !items.contains(where: { $0.id == selection }) {
            selection = items.first?.id
        }
    }

    // MARK: - Header

    private var header: some View {
        PageHeader(title: "Apps & Sites",
                   subtitle: mode == .rules
                    ? "Rules decide how new activity is sorted. Yours win over built-in ones."
                    : "Decide what counts as focus. Changes also update past reports.") {
            WindowSwitch(options: [(AppsMode.used, "Used"), (.rules, "Rules · \(rules.count)")],
                         selection: $mode, label: "View")
            Button { mode = .sort } label: {
                Label("Sort your apps", systemImage: "rectangle.stack").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.header)
            Button { newRule = NewRuleDraft() } label: {
                Label("Add rule", systemImage: "plus").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.capsule(.primary, height: 32))
        }
    }

    // MARK: - Used

    private var shown: [AppsItem] {
        items.filter { item in
            (filter == nil || item.row.classification == filter) &&
            (search.isEmpty || item.name.localizedCaseInsensitiveContains(search))
        }
    }

    private var used: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let smart, smart.isOn, let banner = smart.banner {
                SmartBannerBar(banner: banner, onReview: { mode = .sort }, onClose: smart.closeBanner)
            }
            filterBar
            WindowSplitRow(weights: [1.72, 1]) {
                table
                if let item = items.first(where: { $0.id == selection }) {
                    AppsInspector(appState: appState, item: item, range: range, onChange: reload,
                                  onPartOfSite: { newRule = NewRuleDraft(partOf: item) })
                } else {
                    WindowCard {
                        Text("Pick an app or site to see more.").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var filterBar: some View {
        let counts = AppsModelBuilder.counts(items)
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                TextField("Search apps and sites", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .frame(width: 240, height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.inset))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))

            HStack(spacing: 4) {
                filterChip(nil, "All \(items.count)")
                filterChip(.focus, "Focus \(counts[.focus] ?? 0)")
                filterChip(.neutral, "Neutral \(counts[.neutral] ?? 0)")
                filterChip(.distraction, "Distracting \(counts[.distraction] ?? 0)")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Filter")

            Spacer(minLength: 8)
            Menu {
                ForEach(AppsRange.allCases) { option in
                    Button(option.rawValue) { range = option }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(range.rawValue)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.bodyText)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func filterChip(_ value: Classification?, _ title: String) -> some View {
        let picked = filter == value
        return Button { filter = value } label: {
            HStack(spacing: 6) {
                if let value { Circle().fill(CategoryChip.dot(value)).frame(width: 7, height: 7) }
                Text(title)
            }
            .font(.system(size: 12, weight: picked ? .semibold : .regular))
            .foregroundStyle(picked ? Theme.choiceText : Theme.primaryText)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(picked ? Theme.choiceFill : Theme.switchTrack))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private var table: some View {
        WindowCard(padding: EdgeInsets(top: 6, leading: 8, bottom: 8, trailing: 8)) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Time").frame(width: 80, alignment: .leading)
                    Text("Counts as").frame(width: 204, alignment: .leading)
                    Text("Limit").frame(width: 58, alignment: .leading)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.moduleStroke).frame(height: 0.5) }

                if shown.isEmpty {
                    Text(items.isEmpty ? "Nothing tracked \(range.phrase) yet." : "Nothing matches.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let peak = max(1, items.map(\.row.seconds).max() ?? 1)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(shown) { item in
                                AppsTableRow(appState: appState, item: item, peak: peak,
                                             selected: selection == item.id,
                                             onSelect: { selection = item.id },
                                             onChange: reload)
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                }
            }
        }
    }

    // MARK: - Rules

    private var rulesList: some View {
        let list = RuleItemBuilder.items(rules: rules, limits: appState.limits.statuses)
        return WindowCard(padding: EdgeInsets(top: 6, leading: 8, bottom: 8, trailing: 8)) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("Match").frame(width: 118, alignment: .leading)
                    Text("Pattern").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Counts as").frame(width: 118, alignment: .leading)
                    Text("Daily limit").frame(width: 90, alignment: .leading)
                    Text("Made by").frame(width: 96, alignment: .leading)
                    Color.clear.frame(width: 28, height: 1)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.moduleStroke).frame(height: 0.5) }

                if list.isEmpty {
                    Text("No rules yet.").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(list) { rule in ruleRow(rule) }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func ruleRow(_ rule: RuleItem) -> some View {
        let locked = appState.isStrictLocked && rule.classification == .distraction
        return HStack(spacing: 12) {
            Text(rule.matchLabel)
                .font(.system(size: 11))
                .foregroundStyle(Theme.bodyText)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chip))
                .frame(width: 118, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Text(rule.note).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            CategoryChip(classification: rule.classification).frame(width: 118, alignment: .leading)
            Text(rule.limitMinutes.map { "\($0) min" } ?? "—")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(rule.limitMinutes == nil ? Theme.tertiaryText : Theme.primaryText)
                .frame(width: 90, alignment: .leading)
            Text(rule.source.maker)
                .font(.system(size: 12))
                .foregroundStyle(Theme.bodyText)
                .frame(width: 96, alignment: .leading)
            Group {
                if rule.source == .user || rule.source == .smart {
                    Button {
                        if let model = rules.first(where: { $0.id == rule.id }) {
                            appState.deleteRule(model)
                            reload()
                        }
                    } label: {
                        Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(locked)
                    .help(locked ? "Strict keeps blocked rules until the session ends" : "Delete rule")
                    .accessibilityLabel("Delete rule \(rule.title)")
                } else {
                    Color.clear
                }
            }
            .frame(width: 28, height: 26)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.moduleStroke.opacity(0.6)).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Table row

private struct AppsTableRow: View {
    @Bindable var appState: AppState
    let item: AppsItem
    let peak: TimeInterval
    let selected: Bool
    let onSelect: () -> Void
    let onChange: () -> Void

    @State private var hovered = false

    private var limit: LimitStatus? {
        appState.limits.statuses.first { $0.isSite == item.isSite && $0.target == item.target }
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                WindowItemIcon(name: item.name, bundleId: item.row.bundleId, host: item.row.host, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 4) {
                        if item.isSmart {
                            Image(systemName: "sparkle").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.focus)
                                .accessibilityLabel("Smart categories:")
                        }
                        Text(item.why).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    .help(item.why)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(WindowFormat.hm(item.row.seconds)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.primaryText)
                WindowBar(fraction: item.row.seconds / peak, color: CategoryChip.dot(item.row.classification), height: 3)
            }
            .frame(width: 80, alignment: .leading)
            Group {
                if item.perVideo {
                    PerVideoPill()
                } else {
                    CategoryControl(name: item.name, current: item.row.classification,
                                    lockedToDistracting: appState.isStrictLocked && item.row.classification == .distraction) { c in
                        appState.setCategory(c, for: item.row)
                        onChange()
                    }
                }
            }
            .frame(width: 204)
            Text(limit.map { "\($0.minutes) min" } ?? "—")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(limit == nil ? Theme.tertiaryText : Theme.primaryText)
                .frame(width: 58, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: 41)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(selected ? Theme.focus.opacity(0.08) : (hovered ? Theme.rowHover : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Show details", onSelect)
    }
}

// MARK: - Category control

/// Focus | Neutral | Distracting, the picked one filled in its colour.
/// Orange carries dark text; indigo and grey carry white.
struct CategoryControl: View {
    let name: String
    let current: Classification
    /// Strict keeps a blocked app blocked until the session ends.
    var lockedToDistracting = false
    var height: CGFloat = 26
    let onChange: (Classification) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment(.focus)
            segment(.neutral)
            segment(.distraction)
        }
        .padding(2)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.inset))
        .help(lockedToDistracting ? "Strict keeps it distracting until the session ends" : "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) counts as")
    }

    private func segment(_ c: Classification) -> some View {
        let picked = c == current
        return Button { if !picked { onChange(c) } } label: {
            Text(categoryName(c))
                .font(.system(size: 11, weight: picked ? .semibold : .regular))
                .foregroundStyle(picked ? Self.ink(c) : Theme.primaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(picked ? Self.fill(c) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .disabled(lockedToDistracting && !picked)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    static func fill(_ c: Classification) -> Color {
        switch c {
        case .focus:       return Theme.focusFill
        case .neutral:     return Color(red: 110/255, green: 110/255, blue: 120/255)
        case .distraction: return Theme.distraction
        }
    }

    static func ink(_ c: Classification) -> Color {
        c == .distraction ? Color(red: 29/255, green: 29/255, blue: 31/255) : .white
    }
}

// MARK: - Inspector

private struct AppsInspector: View {
    @Bindable var appState: AppState
    let item: AppsItem
    let range: AppsRange
    let onChange: () -> Void
    let onPartOfSite: () -> Void

    @State private var undoRefused = false

    var body: some View {
        WindowCard(padding: EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    WindowItemIcon(name: item.name, bundleId: item.row.bundleId, host: item.row.host, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primaryText)
                            .lineLimit(1).truncationMode(.middle)
                        Text("\(item.isSite ? "Site" : "App") · \(WindowFormat.hm(item.row.seconds)) \(range.phrase)")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("Counts as").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primaryText)
                        if item.perVideo { ProBadge() }
                    }
                    if item.perVideo {
                        PerVideoPill(height: 30)
                    } else {
                        CategoryControl(name: item.name, current: item.row.classification,
                                        lockedToDistracting: appState.isStrictLocked && item.row.classification == .distraction,
                                        height: 30) { c in
                            appState.setCategory(c, for: item.row)
                            onChange()
                        }
                    }
                    if !item.perVideo {
                        smartNote
                    }
                }

                if isYouTube {
                    YouTubePerVideoSection(appState: appState, item: item, onChange: onChange)
                }

                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                DailyLimitEditor(appState: appState, target: item.target, isSite: item.isSite, name: item.name)

                if item.isSite {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Part of the site").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primaryText)
                            Text("Sort one part on its own, like \(item.target)/shorts.")
                                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer(minLength: 8)
                        Button("Add a rule", action: onPartOfSite).buttonStyle(.capsule(.secondary, height: 26))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var isYouTube: Bool {
        FeatureFlags.smartCategories && item.row.host.map { Classifier.host($0, matches: YouTubeVideos.host) } == true
    }

    /// Where the category comes from; for smart categories, their reason
    /// with Undo, or their guess to take.
    @ViewBuilder private var smartNote: some View {
        if let suggestion = item.suggestion, item.source == .smart {
            VStack(alignment: .leading, spacing: 6) {
                SmartReasonLine(lead: "Sorted for you.", reason: suggestion.reason)
                Button("Undo") {
                    undoRefused = !appState.smartCategories.undo(suggestion)
                    onChange()
                }
                .buttonStyle(.textLink)
                if undoRefused {
                    Text("Strict keeps it blocked until the session ends.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
            }
        } else if let suggestion = item.suggestion, item.source == .none {
            VStack(alignment: .leading, spacing: 6) {
                SmartReasonLine(lead: "Looks like \(categoryName(suggestion.suggested).lowercased()).", reason: suggestion.reason)
                Button("Make it \(categoryName(suggestion.suggested))") {
                    appState.smartCategories.accept(suggestion, as: suggestion.suggested)
                    onChange()
                }
                .buttonStyle(.capsule(.secondary, height: 26))
            }
        } else {
            Text(sourceLine)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceLine: String {
        switch item.source {
        case .none:    return "No rule yet, so it counts as neutral: neither for nor against you."
        case .builtIn: return "Sorted by a built-in rule. Pick another to override it; your choice also updates past reports."
        case .smart:   return "Sorted by smart categories. Pick another to make it yours."
        case .user:    return "You sorted it. Your choice also updated past reports."
        }
    }
}
