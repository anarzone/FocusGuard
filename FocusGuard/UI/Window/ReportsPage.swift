import SwiftUI

/// Reports: a day, week, month or year at a glance, against the period before.
struct ReportsPage: View {
    @Bindable var appState: AppState

    @State private var period: ReportPeriod = .week
    @State private var offset = 0
    @State private var data: ReportData = .empty
    @State private var trend: InsightsBuilder.Trend?
    @State private var peakHour: Int?
    @State private var regression: InsightsBuilder.HostDelta?

    private var reloadKey: String { "\(period.rawValue)-\(offset)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Reports", subtitle: period.title(for: data.interval)) {
                Picker("Period", selection: $period) {
                    ForEach(ReportPeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .onChange(of: period) { offset = 0 }

                PeriodStepper(offset: $offset, unit: period.rawValue.lowercased())

                HeaderCapsule {
                    Menu {
                        Button("Export as CSV…") { export(.csv) }
                        Button("Export as JSON…") { export(.json) }
                    } label: {
                        Text("Export").font(.system(size: 13))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .padding(.horizontal, 14)
                }
            }

            ScrollView {
                VStack(spacing: 14) {
                    kpis

                    HStack(alignment: .top, spacing: 14) {
                        WindowCard(title: "Per \(bucketUnit)", trailing: AnyView(chartLegend)) {
                            StackedBarsChart(buckets: data.buckets, goal: data.goalPerBucket, unit: bucketUnit)
                                .frame(height: 200)
                        }
                        .frame(maxWidth: .infinity)
                        .layoutPriority(1)

                        WindowCard(title: "When you focus", trailing: AnyView(heatLegend)) {
                            FocusHeatmap(heat: data.heat, hours: data.heatHours)
                                .frame(height: 200)
                        }
                        .frame(width: 360)
                    }

                    HStack(alignment: .top, spacing: 14) {
                        appsTable
                            .frame(maxWidth: .infinity)
                            .layoutPriority(1)
                        InsightPanel(
                            insights: appState.insights,
                            highlights: highlights,
                            onGenerate: generateInsights
                        )
                        .frame(width: 360)
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
        .padding(.leading, 16)
        .padding(.trailing, 24)
        .task(id: reloadKey) {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private var bucketUnit: String {
        switch period {
        case .day:   return "hour"
        case .week, .month: return "day"
        case .year:  return "month"
        }
    }

    private func reload() {
        let context = appState.container.mainContext
        data = ReportDataBuilder.build(period: period, offset: offset, context: context)
        let insights = InsightsBuilder(context: context)
        let until = min(data.interval.end, .now)
        trend = insights.focusTrend(from: data.interval.start, to: until)
        peakHour = insights.peakFocusHour()
        regression = insights.topRegression(from: data.interval.start, to: until)
    }

    private func export(_ format: DataExporter.Format) {
        DataExporter.export(format, container: appState.container,
                            from: data.interval.start, to: min(data.interval.end, .now))
    }

    private func generateInsights() {
        appState.insights.generate(
            rangeLabel: period.title(for: data.interval),
            breakdown: data.breakdown,
            distractions: data.distractions,
            currentStreak: appState.currentStreak,
            weeklyAverageFocusSeconds: appState.weeklyAverageFocusSeconds
        )
    }

    // MARK: - KPIs

    private var kpis: some View {
        HStack(spacing: 14) {
            kpi("Focused", formatDuration(data.breakdown.focus),
                change(data.breakdown.focus, data.previous.focus))
            kpi("Focus rate", "\(Int((data.breakdown.focusPercent * 100).rounded()))%",
                rateChange)
            kpi("Longest in the zone", "\(Int(data.longestZone / 60)) min",
                data.sessionCount == 1 ? "across 1 session" : "across \(data.sessionCount) sessions")
            kpi("Drifted", formatDuration(data.breakdown.distraction),
                change(data.breakdown.distraction, data.previous.distraction))
        }
    }

    private func kpi(_ label: String, _ value: String, _ detail: String) -> some View {
        WindowStat(label: label, value: value, detail: detail)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.windowCard))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
    }

    private func change(_ now: TimeInterval, _ before: TimeInterval) -> String {
        guard before >= 60 else { return now >= 60 ? "nothing to compare" : " " }
        let pct = Int(((now - before) / before * 100).rounded())
        return "\(pct >= 0 ? "+" : "−")\(abs(pct))% \(period.previousLabel)"
    }

    private var rateChange: String {
        guard data.previous.total >= 60 else { return " " }
        let pts = Int(((data.breakdown.focusPercent - data.previous.focusPercent) * 100).rounded())
        return "\(pts >= 0 ? "+" : "−")\(abs(pts)) pts \(period.previousLabel)"
    }

    // MARK: - Legends

    private var chartLegend: some View {
        HStack(spacing: 12) {
            swatch(Theme.focus, "Focused")
            swatch(Theme.distraction, "Drifted")
            swatch(Theme.other, "Other")
            if let goal = data.goalPerBucket {
                HStack(spacing: 5) {
                    Rectangle().fill(.secondary).frame(width: 12, height: 1.5)
                    Text("Goal \(FocusGoal.format(minutes: Int(goal / 60)))")
                }
            }
        }
        .font(.system(size: 11))
    }

    private var heatLegend: some View {
        HStack(spacing: 4) {
            Text("Less")
            ForEach(FocusHeatmap.steps, id: \.self) { opacity in
                RoundedRectangle(cornerRadius: 3).fill(Theme.focus.opacity(opacity)).frame(width: 10, height: 10)
            }
            Text("More")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func swatch(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title)
        }
    }

    // MARK: - Apps table

    private var appsTable: some View {
        WindowCard(title: "Apps & sites") {
            if data.apps.isEmpty {
                Text("No activity in this period.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                let total = max(1, data.breakdown.total)
                VStack(spacing: 0) {
                    HStack {
                        Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Category").frame(width: 110, alignment: .leading)
                        Text("Share").frame(width: 140, alignment: .leading)
                        Text("Time").frame(width: 60, alignment: .trailing)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                    ForEach(data.apps) { row in
                        HStack {
                            HStack(spacing: 8) {
                                AppGlyph(kind: row.isSite ? .generic : AppGlyph.kind(forBundleId: row.bundleId, name: row.name),
                                         bundleId: row.isSite ? nil : row.bundleId, host: row.host, size: 20)
                                Text(row.name).lineLimit(1).truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            CategoryMenu(current: row.classification) { c in
                                appState.setCategory(c, for: row)
                                reload()
                            }
                            .frame(width: 110, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.control)
                                    Capsule().fill(kindColor(row.classification))
                                        .frame(width: max(3, geo.size.width * CGFloat(row.seconds / total)))
                                }
                            }
                            .frame(width: 120, height: 6)
                            .frame(width: 140, alignment: .leading)
                            Text(formatDuration(row.seconds))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                        }
                        .font(.system(size: 12))
                        .frame(height: 32)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 0.5) }
                    }
                }
            }
        }
    }

    // MARK: - Highlights

    private var highlights: [String] {
        var out: [String] = []
        if let trend, let pct = trend.deltaPercent, abs(pct) >= 0.02 {
            out.append("Focus is \(pct >= 0 ? "up" : "down") \(Int((abs(pct) * 100).rounded()))% \(period.previousLabel) (\(formatDuration(trend.priorSeconds)) → \(formatDuration(trend.currentSeconds))).")
        }
        if let peakHour {
            out.append("Your strongest hour over the last two weeks starts at \(Self.hourLabel(peakHour)).")
        }
        if let regression {
            out.append("\(regression.host) is taking \(formatDuration(regression.deltaSeconds)) more than the period before.")
        }
        if let top = data.distractions.first {
            out.append("Most drift: \(top.name), \(formatDuration(top.seconds)).")
        }
        return out
    }

    private static func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Stacked bars

/// Focused / drifted / other per bucket, with a dashed goal line and a hover
/// tooltip. Future buckets are dashed outlines.
private struct StackedBarsChart: View {
    let buckets: [ReportBucket]
    let goal: TimeInterval?
    let unit: String

    @State private var hovered: Int?

    var body: some View {
        GeometryReader { geo in
            let axisWidth: CGFloat = 30
            let plotWidth = geo.size.width - axisWidth
            let plotHeight = geo.size.height - 20
            let maxValue = max((goal ?? 0) * 1.2, buckets.map(\.total).max() ?? 0, 3600)
            let step = plotWidth / CGFloat(max(1, buckets.count))
            let barWidth = max(3, min(36, step * 0.62))
            let scale = plotHeight / CGFloat(maxValue)
            let labelEvery = max(1, Int((CGFloat(buckets.count) * 28 / max(1, plotWidth)).rounded(.up)))

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    // Grid lines every hour-ish step.
                    let gridStep = Self.gridStep(maxValue)
                    var v = gridStep
                    while v < maxValue {
                        let y = plotHeight - CGFloat(v) * scale
                        guard y > 8 else { break }
                        context.fill(Path(CGRect(x: axisWidth, y: y, width: plotWidth, height: 0.5)), with: .color(.primary.opacity(0.07)))
                        context.draw(Text(Self.axisLabel(v)).font(.system(size: 10)).foregroundStyle(.secondary),
                                     at: CGPoint(x: 0, y: y), anchor: .leading)
                        v += gridStep
                    }
                    context.fill(Path(CGRect(x: axisWidth, y: plotHeight, width: plotWidth, height: 1)), with: .color(.primary.opacity(0.18)))

                    for (i, bucket) in buckets.enumerated() {
                        let x = axisWidth + CGFloat(i) * step + (step - barWidth) / 2
                        if bucket.isFuture {
                            if let goal {
                                let h = CGFloat(goal) * scale
                                context.stroke(Path(CGRect(x: x, y: plotHeight - h, width: barWidth, height: h)),
                                               with: .color(.primary.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            }
                        } else {
                            var y = plotHeight
                            let parts: [(TimeInterval, Color)] = [(bucket.focus, Theme.focus), (bucket.drift, Theme.distraction), (bucket.other, Theme.other)]
                            let top = parts.lastIndex { $0.0 * Double(scale) >= 1 }
                            for (k, part) in parts.enumerated() where part.0 * Double(scale) >= 1 {
                                let h = CGFloat(part.0) * scale
                                let isTop = k == top
                                let rect = CGRect(x: x, y: y - h, width: barWidth, height: max(0, h - (isTop ? 0 : 1.5)))
                                let path = isTop
                                    ? Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(topLeading: min(4, barWidth / 3), topTrailing: min(4, barWidth / 3)))
                                    : Path(rect)
                                context.fill(path, with: .color(part.1.opacity(hovered == nil || hovered == i ? 1 : 0.4)))
                                y -= h
                            }
                        }
                        if i % labelEvery == 0 {
                            context.draw(Text(bucket.label).font(.system(size: 10)).foregroundStyle(.secondary),
                                         at: CGPoint(x: x + barWidth / 2, y: plotHeight + 11))
                        }
                    }

                    if let goal {
                        let y = plotHeight - CGFloat(goal) * scale
                        var line = Path()
                        line.move(to: CGPoint(x: axisWidth, y: y))
                        line.addLine(to: CGPoint(x: axisWidth + plotWidth, y: y))
                        context.stroke(line, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let i = Int((p.x - axisWidth) / step)
                        hovered = buckets.indices.contains(i) && !buckets[i].isFuture ? i : nil
                    case .ended:
                        hovered = nil
                    }
                }

                if let i = hovered {
                    let bucket = buckets[i]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.tooltipTitle(bucket, unit: unit)).fontWeight(.semibold)
                        Text("\(formatDuration(bucket.focus)) focused · \(bucket.total > 0 ? Int((bucket.focus / bucket.total * 100).rounded()) : 0)%")
                        Text("\(formatDuration(bucket.drift)) drifted").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .fixedSize()
                    .offset(x: min(max(axisWidth, axisWidth + CGFloat(i) * step + step / 2 - 70), geo.size.width - 150), y: 0)
                    .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Focus per \(unit): " + buckets.filter { !$0.isFuture && $0.total > 0 }
            .map { "\($0.label) \(formatDuration($0.focus)) focused" }.joined(separator: ", "))
    }

    static func gridStep(_ maxValue: TimeInterval) -> TimeInterval {
        let hours = maxValue / 3600
        if hours <= 1.5 { return 900 }
        if hours <= 6 { return 3600 }
        if hours <= 24 { return 4 * 3600 }
        if hours <= 120 { return 24 * 3600 }
        return 50 * 3600
    }

    static func axisLabel(_ seconds: TimeInterval) -> String {
        seconds < 3600 ? "\(Int(seconds / 60))m" : "\(Int(seconds / 3600))h"
    }

    static func tooltipTitle(_ bucket: ReportBucket, unit: String) -> String {
        switch unit {
        case "hour":  return bucket.interval.start.formatted(date: .omitted, time: .shortened)
        case "month": return bucket.interval.start.formatted(.dateTime.month(.wide))
        default:      return bucket.interval.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }
}

// MARK: - Heatmap

/// Focused time by weekday and hour, in five steps of the focus colour.
private struct FocusHeatmap: View {
    let heat: [[TimeInterval]]
    let hours: ClosedRange<Int>

    static let steps: [Double] = [0.12, 0.30, 0.52, 0.76, 1.0]

    var body: some View {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols
        let names = (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
        let maxValue = heat.flatMap { $0 }.max() ?? 0

        Canvas { context, size in
            let labelWidth: CGFloat = 34
            let cols = hours.count
            let gap: CGFloat = 3
            let cellW = (size.width - labelWidth - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let cellH = (size.height - 18 - gap * 6) / 7

            for row in 0..<7 {
                let y = CGFloat(row) * (cellH + gap)
                context.draw(Text(names[row]).font(.system(size: 10)).foregroundStyle(.secondary),
                             at: CGPoint(x: 0, y: y + cellH / 2), anchor: .leading)
                for (c, hour) in hours.enumerated() {
                    let rect = CGRect(x: labelWidth + CGFloat(c) * (cellW + gap), y: y, width: cellW, height: cellH)
                    let value = heat[row][hour]
                    let path = Path(roundedRect: rect, cornerRadius: min(4, cellW / 4))
                    if value <= 0 || maxValue <= 0 {
                        context.stroke(path, with: .color(.primary.opacity(0.07)), lineWidth: 1)
                    } else {
                        let step = min(4, Int((value / maxValue) * 5))
                        context.fill(path, with: .color(Theme.focus.opacity(Self.steps[step])))
                    }
                }
            }

            let ticks = [hours.lowerBound, (hours.lowerBound + hours.upperBound) / 2, hours.upperBound]
            for (i, hour) in ticks.enumerated() {
                let c = hour - hours.lowerBound
                let x = labelWidth + CGFloat(c) * (cellW + gap) + cellW / 2
                let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
                context.draw(Text(date.formatted(.dateTime.hour())).font(.system(size: 10)).foregroundStyle(.secondary),
                             at: CGPoint(x: x, y: size.height - 6),
                             anchor: i == 0 ? .leading : (i == 2 ? .trailing : .center))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary(names: names))
    }

    private func accessibilitySummary(names: [String]) -> String {
        var best: (row: Int, hour: Int, value: TimeInterval) = (0, 0, 0)
        for row in 0..<7 { for hour in hours where heat[row][hour] > best.value { best = (row, hour, heat[row][hour]) } }
        guard best.value > 0 else { return "No focused time in this period." }
        return "Focused time by weekday and hour. Most focused: \(names[best.row]) around \(best.hour):00."
    }
}

// MARK: - Insight panel

/// Plain-language highlights, plus on-demand AI tips when a provider is set up
/// (and the app offers AI at all).
private struct InsightPanel: View {
    @ObservedObject var insights: AIInsightsViewModel
    let highlights: [String]
    let onGenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZoneGlyph(color: Theme.focus).frame(width: 16, height: 16)
                Text("Insights").font(.system(size: 13, weight: .semibold))
                Spacer()
                if insights.isConfigured {
                    Button(buttonTitle, action: onGenerate)
                        .controlSize(.small)
                        .disabled(insights.state == .loading)
                }
            }

            if highlights.isEmpty {
                Text("Highlights appear once there's some activity in this period.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(highlights, id: \.self) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(Theme.focus).frame(width: 5, height: 5).padding(.top, 6)
                            Text(line).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            aiContent
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(colors: [Theme.focus.opacity(0.16), Theme.focus.opacity(0.04)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.focus.opacity(0.3), lineWidth: 0.5))
    }

    private var buttonTitle: String {
        switch insights.state {
        case .loading:         return "Thinking…"
        case .loaded, .failed: return "Refresh tips"
        case .idle:            return "Get AI tips"
        }
    }

    @ViewBuilder
    private var aiContent: some View {
        if !AISettings.isAvailable {
            EmptyView()
        } else if !insights.isConfigured {
            Text("Add an AI provider in Settings → AI tips for personal tips. Only a summary is sent, never window titles.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            switch insights.state {
            case .idle:
                Text("Tips use your AI provider. Only a summary is sent, and only when you ask.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading this period…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .loaded(let tips):
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in
                        Text(tip).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}
