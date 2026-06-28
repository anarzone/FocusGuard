import SwiftUI
import SwiftData

/// Reports — Hero Numeric variant.
/// Real data backed by `ReportBuilder`. Refreshes every 5s while visible.
struct ReportsView: View {
    @Bindable var appState: AppState

    @State private var range: ReportRange = .today
    @State private var customFrom: Date = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    @State private var customTo: Date = .now
    @State private var showingCustomSheet = false

    @State private var breakdown: BreakdownSnapshot = .init(focus: 0, neutral: 0, distraction: 0)
    @State private var distractions: [DistractionEntry] = []
    @State private var topApps: [AppUsageEntry] = []
    @State private var timeline: [TimelinePoint] = []
    @State private var dailyTotals: [DailyTotal] = []
    @State private var expandedAppIds: Set<UUID> = []
    @State private var trend: InsightsBuilder.Trend?
    @State private var peakHour: Int?
    @State private var topRegression: InsightsBuilder.HostDelta?

    private var builder: ReportBuilder { ReportBuilder(context: appState.container.mainContext) }

    private var resolvedRange: (from: Date, to: Date) {
        if case .custom = range {
            return (customFrom, customTo)
        }
        return range.dateRange()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                rangePicker
                heroBand
                highlightsRow
                Divider().background(Theme.separator)
                timelineSection
                topAppsSection
                topDistractionsSection
                aiInsightsSection
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .task { refresh() }
        .task(id: appState.sessionManager.currentSession?.id) { refresh() }
        .task(id: rangeKey) { refresh() }
        .task {
            // Live update while window visible. 15s is a sane balance between
            // responsiveness and SwiftData fetch cost.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                refresh()
            }
        }
        .sheet(isPresented: $showingCustomSheet) {
            CustomRangeSheet(from: $customFrom, to: $customTo) {
                showingCustomSheet = false
                range = .custom(from: customFrom, to: customTo)
            }
        }
    }

    /// Stable identity for `task(id:)` so it re-fires on range changes.
    private var rangeKey: String {
        switch range {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .last7Days: return "7d"
        case .last30Days: return "30d"
        case .thisWeek: return "thisWeek"
        case .thisMonth: return "thisMonth"
        case .custom(let from, let to):
            return "custom-\(from.timeIntervalSince1970)-\(to.timeIntervalSince1970)"
        }
    }

    // MARK: - Range picker

    private var rangePicker: some View {
        HStack(spacing: 8) {
            ForEach(ReportRange.presets, id: \.self) { preset in
                Button {
                    range = preset
                } label: {
                    Text(preset.label)
                        .font(.system(size: 12, weight: range == preset ? .semibold : .regular))
                        .foregroundStyle(range == preset ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            range == preset ? Theme.cardBackground : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
            }

            Button {
                showingCustomSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    Text(customLabel)
                        .font(.system(size: 12, weight: isCustomActive ? .semibold : .regular))
                }
                .foregroundStyle(isCustomActive ? .primary : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isCustomActive ? Theme.cardBackground : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                let (from, to) = resolvedRange
                DataExporter.export(.csv, container: appState.container, from: from, to: to)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export CSV")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .help("Export the current range to a CSV file.")
        }
        .padding(4)
        .background(Theme.fill1, in: RoundedRectangle(cornerRadius: 8))
    }

    private var isCustomActive: Bool {
        if case .custom = range { return true }
        return false
    }

    private var customLabel: String {
        if case .custom(let from, let to) = range {
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            return "\(f.string(from: from)) – \(f.string(from: to))"
        }
        return "Custom…"
    }

    private func refresh() {
        let (from, to) = resolvedRange
        breakdown = builder.breakdown(from: from, to: to)
        distractions = builder.topDistractions(from: from, to: to, limit: 5)
        topApps = builder.topApps(from: from, to: to, limit: 10)
        timeline = builder.timeline(from: from, to: to)
        dailyTotals = builder.dailyTotals(from: from, to: to)

        let insights = InsightsBuilder(context: appState.container.mainContext)
        trend = insights.focusTrend(from: from, to: to)
        peakHour = insights.peakFocusHour()
        topRegression = insights.topRegression(from: from, to: to)
    }

    // MARK: - AI insights

    private var rangeLabelText: String {
        if case .custom = range { return customLabel }
        return range.label
    }

    private var aiInsightsSection: some View {
        AIInsightsCard(
            insights: appState.insights,
            isConfigured: appState.insights.isConfigured,
            onGenerate: {
                appState.insights.generate(
                    rangeLabel: rangeLabelText,
                    breakdown: breakdown,
                    distractions: distractions,
                    currentStreak: appState.currentStreak,
                    weeklyAverageFocusSeconds: appState.weeklyAverageFocusSeconds
                )
            }
        )
    }

    // MARK: - Highlights row

    @ViewBuilder
    private var highlightsRow: some View {
        let cards: [AnyView] = [
            trendCard.map { AnyView($0) },
            peakHourCard.map { AnyView($0) },
            regressionCard.map { AnyView($0) }
        ].compactMap { $0 }

        if !cards.isEmpty {
            HStack(spacing: 12) {
                ForEach(0..<cards.count, id: \.self) { i in cards[i] }
            }
        }
    }

    @ViewBuilder
    private var trendCard: HighlightCard? {
        if let trend, let pct = trend.deltaPercent {
            let absPct = abs(pct)
            let sign = pct >= 0 ? "+" : "−"
            HighlightCard(
                icon: "chart.line.uptrend.xyaxis",
                title: "Focus trend",
                value: "\(sign)\(Int((absPct * 100).rounded()))%",
                caption: "vs the previous \(prettyRangeLabel) (\(formatHM(trend.priorSeconds)) \u{2192} \(formatHM(trend.currentSeconds)))",
                direction: pct >= 0.02 ? .up : (pct <= -0.02 ? .down : .neutral)
            )
        }
    }

    @ViewBuilder
    private var peakHourCard: HighlightCard? {
        if let h = peakHour {
            HighlightCard(
                icon: "sun.max",
                title: "Peak focus hour",
                value: hourLabel(h),
                caption: "Across the last 14 days, you focus most around \(hourLabel(h)).",
                direction: .neutral
            )
        }
    }

    @ViewBuilder
    private var regressionCard: HighlightCard? {
        if let r = topRegression {
            HighlightCard(
                icon: "exclamationmark.triangle",
                title: "Top regression",
                value: r.host,
                caption: "+\(formatHM(r.deltaSeconds)) vs the previous \(prettyRangeLabel).",
                direction: .down
            )
        }
    }

    private var prettyRangeLabel: String {
        switch range {
        case .today:       return "day"
        case .yesterday:   return "day"
        case .last7Days:   return "week"
        case .last30Days:  return "month"
        case .thisWeek:    return "week"
        case .thisMonth:   return "month"
        case .custom:      return "period"
        }
    }

    private func hourLabel(_ h: Int) -> String {
        // 9 → "9–10am", 14 → "2–3pm"
        func ampm(_ x: Int) -> String {
            let h12 = x % 12 == 0 ? 12 : x % 12
            let suffix = x < 12 ? "am" : "pm"
            return "\(h12)\(suffix)"
        }
        return "\(ampm(h))–\(ampm((h + 1) % 24))"
    }

    // MARK: - Hero band

    private var heroBand: some View {
        HStack(alignment: .bottom, spacing: 32) {
            heroLeft
            heroRight
        }
    }

    private var heroLeft: some View {
        let secs = Int(breakdown.focus)
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let pct = Int((breakdown.focusPercent * 100).rounded())

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text(heroLabel.uppercased())
                    .font(.system(size: 11.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                streakBadge
                Spacer()
            }
            .padding(.bottom, 8)

            HStack(alignment: .lastTextBaseline, spacing: 12) {
                heroNumber(h, unit: "h", color: Theme.focus)
                Text("·")
                    .font(.system(size: 64, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.2))
                heroNumber(m, unit: "m", color: Theme.focus)
                Text("\(pct)%")
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    .padding(.leading, 12)
                Spacer()
            }

            Text(heroSubtitle)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heroNumber(_ value: Int, unit: String, color: Color) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text("\(value)")
                .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .kerning(-2.0)
            Text(unit)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var heroLabel: String {
        "\(range.label) · \(range.headingDateString())"
    }

    @ViewBuilder
    private var streakBadge: some View {
        let streak = appState.currentStreak
        if streak >= 2 {
            Text("🔥 \(streak)-day streak")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.focus)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Theme.focusTint, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var heroSubtitle: String {
        let total = formatHM(breakdown.total)
        let neutral = formatHM(breakdown.neutral)
        let distract = formatHM(breakdown.distraction)
        return "Tracked \(total) · \(neutral) neutral · \(distract) distraction"
    }

    // MARK: - Hero right (week chart)

    private var heroRight: some View {
        // Single-day ranges would render as a single bar — useless. Skip the
        // sparkline entirely in that case.
        let multiDay = dailyTotals.count >= 2
        return VStack(alignment: .leading, spacing: 8) {
            if multiDay {
                Text("TRACKED PER DAY")
                    .font(.system(size: 11.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                WeekChart(daily: dailyTotals)
                    .frame(width: 280, height: 80)
            }
        }
    }

    // MARK: - Timeline

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TIMELINE")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(timelineRangeLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 12) {
                let chart = FocusTimelineChart(series: timeline)
                HStack(spacing: 14) {
                    legendItem(color: Theme.focus, label: "Focus")
                    legendItem(color: Theme.neutral, label: "Neutral")
                    legendItem(color: Theme.distraction, label: "Distraction")
                    Spacer()
                    if !timeline.isEmpty {
                        Text(chart.bucketLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                if timeline.isEmpty {
                    emptyTimeline
                } else {
                    chart.frame(height: 180)
                }
            }
            .padding(16)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .stroke(Theme.separator, lineWidth: 0.5)
            )
        }
    }

    private var emptyTimeline: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("No activity in this range")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 32)
            Spacer()
        }
    }

    private var timelineRangeLabel: String { range.label }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label).font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Top apps (all classifications)

    private var topAppsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("APPS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)

            if topApps.isEmpty {
                emptyAppsCard
            } else {
                appsListCard
            }
        }
    }

    private var emptyAppsCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No activity in this range")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Reports populate as you use your Mac. Start a focus session to see how it shapes up.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button {
                appState.sessionManager.startSession(
                    label: UserDefaults.standard.string(forKey: SessionDefaultsKey.label) ?? "Deep work",
                    plannedDurationMinutes: max(5, UserDefaults.standard.integer(forKey: SessionDefaultsKey.durationMinutes))
                )
            } label: {
                Text("Start a focus session")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.focus)
            .disabled(appState.sessionManager.currentSession != nil)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.separator, lineWidth: 0.5)
        )
    }

    private var appsListCard: some View {
        let maxSeconds = topApps.map(\.seconds).max() ?? 1
        return VStack(spacing: 0) {
            ForEach(topApps) { entry in
                appRow(entry, maxSeconds: maxSeconds)
                if expandedAppIds.contains(entry.id) {
                    ForEach(entry.tabs) { tab in
                        tabRow(tab, maxSeconds: maxSeconds)
                    }
                }
                if entry.id != topApps.last?.id {
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                }
            }
        }
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.separator, lineWidth: 0.5)
        )
    }

    private func appRow(_ entry: AppUsageEntry, maxSeconds: TimeInterval) -> some View {
        let canExpand = !entry.tabs.isEmpty
        let isExpanded = expandedAppIds.contains(entry.id)
        return HStack(spacing: 10) {
            // Disclosure chevron — only renders if there are child tabs.
            // Reserved-width slot keeps non-browser rows aligned with browsers.
            ZStack {
                if canExpand {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .frame(width: 12)

            AppGlyph(kind: entry.kind, bundleId: entry.bundleId, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: 13))
                Text(canExpand ? "\(entry.tabs.count) site\(entry.tabs.count == 1 ? "" : "s")" : entry.bundleId)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            classificationChip(entry.classification)
            ProgressView(value: entry.seconds / maxSeconds)
                .progressViewStyle(.linear)
                .tint(color(for: entry.classification))
                .frame(width: 80)
            Text(entry.timeLabel)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            reclassifyMenu(current: entry.classification) { newClass in
                appState.classifier.setOverride(bundleId: entry.bundleId, classification: newClass)
                refresh()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            guard canExpand else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                if isExpanded { expandedAppIds.remove(entry.id) }
                else          { expandedAppIds.insert(entry.id) }
            }
        }
    }

    private func tabRow(_ tab: TabUsage, maxSeconds: TimeInterval) -> some View {
        HStack(spacing: 10) {
            // Empty chevron slot + indent under the parent's app glyph.
            Color.clear.frame(width: 12)
            Color.clear.frame(width: 28)
            Text(tab.host)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            classificationChip(tab.classification)
            ProgressView(value: tab.seconds / maxSeconds)
                .progressViewStyle(.linear)
                .tint(color(for: tab.classification))
                .frame(width: 80)
            Text(tab.timeLabel)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            reclassifyMenu(current: tab.classification) { newClass in
                appState.classifier.setOverride(host: tab.host, classification: newClass)
                refresh()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .background(Theme.cardBackground.opacity(0.5))
    }

    /// Compact menu surfaced as a `•••` button on each row. Calls back with
    /// the chosen classification; the row wires it to either bundleId or host.
    @ViewBuilder
    private func reclassifyMenu(current: Classification, onPick: @escaping (Classification) -> Void) -> some View {
        Menu {
            Button { onPick(.focus) } label: {
                Label("Mark as Focus", systemImage: current == .focus ? "checkmark" : "")
            }
            Button { onPick(.neutral) } label: {
                Label("Mark as Neutral", systemImage: current == .neutral ? "checkmark" : "")
            }
            Button { onPick(.distraction) } label: {
                Label("Mark as Distraction", systemImage: current == .distraction ? "checkmark" : "")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
    }

    private func classificationChip(_ c: Classification) -> some View {
        Text(label(for: c))
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.3)
            .textCase(.uppercase)
            .foregroundStyle(color(for: c))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint(for: c), in: RoundedRectangle(cornerRadius: 4))
    }

    private func label(for c: Classification) -> String {
        switch c {
        case .focus: return "Focus"
        case .neutral: return "Neutral"
        case .distraction: return "Distraction"
        }
    }

    private func color(for c: Classification) -> Color {
        switch c {
        case .focus: return Theme.focus
        case .neutral: return Theme.neutral
        case .distraction: return Theme.distraction
        }
    }

    private func tint(for c: Classification) -> Color {
        switch c {
        case .focus: return Theme.focusTint
        case .neutral: return Theme.fill1
        case .distraction: return Theme.distractionTint
        }
    }

    // MARK: - Top distractions

    private var topDistractionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TOP DISTRACTIONS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)

            if distractions.isEmpty {
                emptyDistractions
            } else {
                VStack(spacing: 0) {
                    ForEach(distractions) { d in
                        distractionRow(d)
                        if d.id != distractions.last?.id {
                            Rectangle().fill(Theme.separator).frame(height: 0.5)
                        }
                    }
                }
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .stroke(Theme.separator, lineWidth: 0.5)
                )
            }
        }
    }

    private var emptyDistractions: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.focus)
                Text("No distractions in this range")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 32)
            Spacer()
        }
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.separator, lineWidth: 0.5)
        )
    }

    private func distractionRow(_ d: DistractionEntry) -> some View {
        HStack(spacing: 10) {
            // Favicon takes priority over bundleId for host-grouped rows so
            // 'youtube.com' shows the YouTube icon, not Chrome.
            AppGlyph(kind: d.kind, bundleId: d.host == nil ? d.bundleId : nil, host: d.host, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.name).font(.system(size: 13))
                Text(d.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView(value: d.fractionOfTotal)
                .progressViewStyle(.linear)
                .tint(Theme.distraction)
                .frame(width: 80)
            Text(d.timeLabel)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            reclassifyMenu(current: .distraction) { newClass in
                if let host = d.host {
                    appState.classifier.setOverride(host: host, classification: newClass)
                } else {
                    appState.classifier.setOverride(bundleId: d.bundleId, classification: newClass)
                }
                refresh()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date)
    }
}

// MARK: - AI insights card

/// On-demand AI coaching card. Observes the shared `AIInsightsViewModel`; the
/// network call only fires when the user taps Generate.
private struct AIInsightsCard: View {
    @ObservedObject var insights: AIInsightsViewModel
    let isConfigured: Bool
    let onGenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI insights", systemImage: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if isConfigured {
                    Button(action: onGenerate) {
                        Text(buttonTitle)
                    }
                    .disabled(insights.state == .loading)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.separator, lineWidth: 0.5))
    }

    private var buttonTitle: String {
        switch insights.state {
        case .loading:            return "Generating…"
        case .loaded, .failed:    return "Regenerate"
        case .idle:               return "Generate insights"
        }
    }

    @ViewBuilder
    private var content: some View {
        if !isConfigured {
            Text("Turn on AI Insights in Settings → AI to get personalized focus tips generated from this report.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            switch insights.state {
            case .idle:
                Text("Generate 2–3 tips based on the data above. A summary is sent to your AI provider only when you click.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Analyzing your focus data…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .loaded(let tips):
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 11)).foregroundStyle(Theme.focus)
                                .padding(.top, 2)
                            Text(tip)
                                .font(.system(size: 12.5)).foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            case .failed(let message):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(Theme.distraction)
                        .padding(.top, 2)
                    Text(message)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
