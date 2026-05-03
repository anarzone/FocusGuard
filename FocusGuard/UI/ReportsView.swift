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
                Divider().background(Theme.separator)
                timelineSection
                topAppsSection
                topDistractionsSection
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
            Text(heroLabel.uppercased())
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
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

    private var heroSubtitle: String {
        let total = formatHM(breakdown.total)
        let neutral = formatHM(breakdown.neutral)
        let distract = formatHM(breakdown.distraction)
        return "Tracked \(total) · \(neutral) neutral · \(distract) distraction"
    }

    // MARK: - Hero right (week chart)

    private var heroRight: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("THIS WEEK")
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            WeekChart(values: appState.weekTrackedSeconds)
                .frame(width: 280, height: 80)
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
                HStack(spacing: 14) {
                    legendItem(color: Theme.focus, label: "Focus")
                    legendItem(color: Theme.neutral, label: "Neutral")
                    legendItem(color: Theme.distraction, label: "Distraction")
                    Spacer()
                    Text("1-minute resolution")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                if timeline.isEmpty {
                    emptyTimeline
                } else {
                    FocusTimelineChart(series: timeline)
                        .frame(height: 160)
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
        HStack {
            Spacer()
            Text("No activity yet today.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 24)
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
        HStack(spacing: 10) {
            AppGlyph(kind: entry.kind, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: 13))
                Text(entry.bundleId)
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
            AppGlyph(kind: d.kind, size: 28)
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
