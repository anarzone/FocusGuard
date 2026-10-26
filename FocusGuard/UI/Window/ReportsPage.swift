import SwiftUI

/// Reports: a week or a month at a glance, against the one before. Free
/// keeps 30 days of history; older days need Pro.
struct ReportsPage: View {
    @Bindable var appState: AppState
    var entitlements: Entitlements = .shared

    @State private var period: ReportPeriod
    @State private var offset = 0
    @State private var model: ReportsModel = .empty
    @AppStorage(SettingsKeys.Goal.weekendsCount) private var weekendsCount = false
    @Environment(\.openWindowSheet) private var openSheet

    init(appState: AppState, period: ReportPeriod = .week) {
        self._appState = Bindable(wrappedValue: appState)
        self._period = State(initialValue: period)
        // Open on the report as last loaded; the fresh copy follows.
        if let cached = appState.windowPages.reports[WindowPageCache.reportsKey(period, 0)] {
            self._model = State(initialValue: cached)
        }
    }

    private var reloadKey: String { "\(period.rawValue)-\(offset)-\(entitlements.plan.unlocksPro(at: .now))" }

    /// How far back the stepper goes: the last period the plan's history reaches.
    private var maxOffset: Int? {
        guard let start = entitlements.historyStart() else { return nil }
        var back = 0
        while back < 60, period.interval(offset: back + 1).end > start { back += 1 }
        return back
    }

    var body: some View {
        WindowScroll {
            VStack(alignment: .leading, spacing: 12) {
                header
                // The same line under the header for a week and a month, so
                // switching between them doesn't move the page.
                let words = ReportWords.goalHeadline(model.goal, period: model.period, weekendsCount: weekendsCount,
                                                     isCurrent: offset == 0)
                WindowHeadline(lead: words.lead, rest: words.rest)
                if let clipped = model.clippedAt { historyNote(clipped) }
                // Laid out for the report on screen: until a newly picked
                // period has loaded, the last one stays whole.
                switch model.period {
                case .month: month
                default: week
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 24)
            .padding(.bottom, 20)
        }
        .task(id: reloadKey) {
            await reload()
            // Only the current week or month still changes.
            while offset == 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { await reload() }
            }
        }
    }

    /// Builds the report off the main thread (a month takes about half a
    /// second); a period stepped to shows its last copy, if any, until then.
    private func reload() async {
        let key = WindowPageCache.reportsKey(period, offset)
        if let cached = appState.windowPages.reports[key], cached.data.interval != model.data.interval {
            model = cached
        }
        let fresh = await appState.stats.reports(period: period, offset: offset, now: .now,
                                                 historyStart: entitlements.historyStart(),
                                                 weekendsCount: weekendsCount)
        guard !Task.isCancelled, key == WindowPageCache.reportsKey(period, offset) else { return }
        model = fresh
        appState.windowPages.reports[key] = fresh
    }

    // MARK: - Header

    private var subtitle: String {
        let title = model.period.title(for: model.data.interval)
        if model.period == .week, let note = model.bestWeekNote { return "\(title) · \(note)" }
        return title
    }

    private var header: some View {
        PageHeader(title: "Reports", subtitle: subtitle) {
            // Share week comes and goes with the period, so it sits first:
            // the switch, the stepper and Export stay put under the pointer.
            if period == .week {
                Button {
                    NotificationCenter.default.post(name: .openShareComposer, object: model.data.interval.start)
                } label: {
                    Label("Share week", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.header)
                .help("Make a picture of this week to share")
            }
            WindowSwitch(options: [(ReportPeriod.week, "Week"), (.month, "Month")], selection: $period, label: "Period")
                .onChange(of: period) { offset = 0 }
            PeriodStepper(offset: $offset, unit: period.rawValue.lowercased(), maxOffset: maxOffset)
            Menu {
                Button("Export as CSV…") { export(.csv) }
                Button("Export as JSON…") { export(.json) }
            } label: {
                HStack(spacing: 6) {
                    Text("Export")
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.primaryText)
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .frame(height: 32)
                .background(HeaderCapsuleBackground())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func export(_ format: DataExporter.Format) {
        let start = model.clippedAt ?? model.data.interval.start
        DataExporter.export(format, container: appState.container, from: start, to: min(model.data.interval.end, .now))
    }

    private func historyNote(_ start: Date) -> some View {
        HStack(spacing: 10) {
            ProBadge()
            Text("Free keeps \(Plan.freeHistoryDays) days, from \(start.formatted(.dateTime.day().month(.wide))). Earlier days are part of Pro.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.bodyText)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(entitlements.canStartTrial ? "Try Pro free" : "See Pro") { openSheet(.upgrade(.fullHistory)) }
                .buttonStyle(.textLink)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.lockedFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.lockedStroke, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
    }

    // MARK: - Week

    private var week: some View {
        VStack(alignment: .leading, spacing: 12) {
            // This week's note from the weekly coach (Pro), about last week.
            if FeatureFlags.coach && offset == 0 { WindowCoachCard(entitlements: entitlements) }
            kpis(sessionsSlot: false)
            WindowSplitRow(weights: [1.55, 1]) {
                WindowCard(padding: EdgeInsets(top: 14, leading: 20, bottom: 10, trailing: 20)) {
                    VStack(alignment: .leading, spacing: 6) {
                        chartTitle("Focus and drift per day", other: true)
                        DayBarsChart(buckets: model.data.buckets, goal: FocusGoal.dailySeconds)
                    }
                }
                WindowCard(padding: EdgeInsets(top: 12, leading: 20, bottom: 10, trailing: 20)) {
                    VStack(alignment: .leading, spacing: 6) {
                        WindowCardTitle("Best hours", note: model.heatWeeks > 1 ? "last \(model.heatWeeks) weeks" : "this week")
                        HeatGrid(heat: model.heat)
                        HeatLegend()
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(height: 214)

            WindowSplitRow(weights: [1, 1, 1]) {
                WindowCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 18)) {
                    VStack(alignment: .leading, spacing: 8) {
                        WindowCardTitle("Trend", note: "focused per week")
                        if model.trend.count >= 2 {
                            TrendBars(weeks: model.trend).frame(minHeight: 90, maxHeight: 120)
                            if let line = TrendBars.caption(model.trend) { caption(line) }
                            if model.trend.count < 8 && entitlements.historyStart() != nil {
                                Text("Older weeks are part of Pro.").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                            }
                        } else {
                            empty("A trend shows once there are two weeks to compare.")
                        }
                        Spacer(minLength: 0)
                    }
                }
                distractionsCard(against: "vs last week", timeWidth: 34)
                highlightsCard
            }
            .frame(minHeight: 200, maxHeight: .infinity)
        }
    }

    // MARK: - Month

    private var month: some View {
        VStack(alignment: .leading, spacing: 12) {
            kpis(sessionsSlot: true)
            WindowSplitRow(weights: [1, 1.42]) {
                WindowCard(padding: EdgeInsets(top: 12, leading: 18, bottom: 10, trailing: 18)) {
                    VStack(alignment: .leading, spacing: 6) {
                        WindowCardTitle("Daily goal", note: "a full ring is \(FocusGoal.format(minutes: FocusGoal.dailyMinutes))")
                        MonthCalendarGrid(weeks: model.calendar, goal: FocusGoal.dailySeconds)
                        Spacer(minLength: 0)
                    }
                }
                WindowCard(padding: EdgeInsets(top: 12, leading: 18, bottom: 10, trailing: 18)) {
                    VStack(alignment: .leading, spacing: 6) {
                        chartTitle("Focus and drift over time", other: false)
                        DayBarsChart(buckets: model.data.buckets, goal: FocusGoal.dailySeconds,
                                     showOther: false, weekLabels: false)
                    }
                }
            }
            .frame(height: 236)

            WindowSplitRow(weights: [1, 1, 1]) {
                WindowCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 18)) {
                    VStack(alignment: .leading, spacing: 8) {
                        WindowCardTitle("Best hours", note: "average focus per hour")
                        if let line = HourBars.caption(model.hourAverages) {
                            HourBars(averages: model.hourAverages).frame(minHeight: 90, maxHeight: 128)
                            caption(line)
                        } else {
                            empty("Your strongest hours show once there's some focus this month.")
                        }
                        Spacer(minLength: 0)
                    }
                }
                WindowCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 18)) {
                    VStack(alignment: .leading, spacing: 6) {
                        WindowCardTitle("How sessions went", note: WindowFormat.count(model.totalSessions, "session"))
                            .padding(.bottom, 2)
                        if model.patterns.isEmpty {
                            empty("Each session is named from how it went. Their names add up here.")
                        } else {
                            PatternBars(patterns: model.patterns)
                            if let note = model.patternNote {
                                Text(note).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).padding(.top, 4)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                distractionsCard(against: "vs \(previousMonthName)", timeWidth: 46)
            }
            .frame(minHeight: 200, maxHeight: .infinity)
        }
    }

    private var previousMonthName: String {
        let previous = ReportPeriod.month.interval(offset: offset + 1)
        return previous.start.formatted(.dateTime.month(.wide))
    }

    // MARK: - Shared cards

    private func kpis(sessionsSlot: Bool) -> some View {
        let data = model.data
        let against = model.period == .week ? "last week" : previousMonthName
        let focusedChange = WindowFormat.percentChange(data.breakdown.focus, data.previous.focus)
            .map { model.period == .week ? "\($0) vs last week" : "\($0) vs the same days in \(previousMonthName)" }
            ?? "nothing to compare yet"
        let prevRateCounts = data.previous.focus + data.previous.distraction >= 60
        let rateDetail = prevRateCounts
            ? "\(WindowFormat.pointsChange(data.breakdown.focusRate, data.previous.focusRate)) · other apps don't count"
            : "other apps don't count"
        let rate = data.breakdown.focus + data.breakdown.distraction >= 60
            ? "\(Int((data.breakdown.focusRate * 100).rounded()))%" : "–"

        return WindowSplitRow(weights: [1, 1, 1, 1]) {
            WindowKPICard(label: "Focused", value: WindowFormat.hm(data.breakdown.focus), detail: focusedChange)
            WindowKPICard(label: "Focus rate", value: rate, detail: rateDetail)
            if sessionsSlot {
                WindowKPICard(label: "Sessions", value: "\(data.sessionCount)",
                        detail: data.longestZone >= 60 ? "longest in the zone \(WindowFormat.minutes(data.longestZone))" : "none long enough to count")
            } else {
                WindowKPICard(label: "Longest in the zone", value: WindowFormat.minutes(data.longestZone), detail: zoneDetail)
            }
            WindowKPICard(label: "Drifted", value: WindowFormat.hm(data.breakdown.distraction),
                    detail: ReportWords.driftChange(data.breakdown.distraction, data.previous.distraction, against: against))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var zoneDetail: String {
        let sessions = "across \(WindowFormat.count(model.data.sessionCount, "session"))"
        guard let day = model.longestZoneDay, model.data.longestZone >= 60 else { return sessions }
        return "\(day.formatted(.dateTime.weekday(.wide))) · \(sessions)"
    }

    private func chartTitle(_ title: String, other: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
            Spacer(minLength: 8)
            WindowLegend(color: Theme.focus, title: "Focused")
            WindowLegend(color: Theme.distraction, title: "Drifted")
            if other { WindowLegend(color: Theme.other, title: "Other") }
        }
    }

    private func distractionsCard(against: String, timeWidth: CGFloat) -> some View {
        WindowCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 18)) {
            VStack(alignment: .leading, spacing: 2) {
                WindowCardTitle("Top distractions", note: (model.distractions.first?.comparable ?? true) ? against : "")
                    .padding(.bottom, 6)
                if model.distractions.isEmpty {
                    empty("Nothing distracting in this \(model.period == .week ? "week" : "month"). Nice.")
                } else {
                    let peak = max(1, model.distractions.map(\.seconds).max() ?? 1)
                    ForEach(model.distractions) { item in
                        WindowDistractionRow(item: item, fraction: item.seconds / peak, timeWidth: timeWidth)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var highlightsCard: some View {
        WindowCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 18)) {
            VStack(alignment: .leading, spacing: 10) {
                WindowCardTitle("Highlights")
                if model.highlights.isEmpty {
                    empty("Highlights show up once there's a little more to go on.")
                } else {
                    ForEach(model.highlights, id: \.text) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(item.kind == .other ? Theme.neutral : windowKindColor(item.kind))
                                .frame(width: 6, height: 6)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                            Text(item.text)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.primaryText)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.bodyText)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
