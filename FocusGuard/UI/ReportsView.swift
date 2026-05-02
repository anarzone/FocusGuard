import SwiftUI
import SwiftData

/// Reports — Hero Numeric variant.
/// Real data backed by `ReportBuilder`. Refreshes every 5s while visible.
struct ReportsView: View {
    @Bindable var appState: AppState

    @State private var breakdown: BreakdownSnapshot = .init(focus: 0, neutral: 0, distraction: 0)
    @State private var distractions: [DistractionEntry] = []
    @State private var timeline: [TimelinePoint] = []

    private var builder: ReportBuilder { ReportBuilder(context: appState.container.mainContext) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heroBand
                Divider().background(Theme.separator)
                timelineSection
                topDistractionsSection
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .task { refresh() }
        .task(id: appState.sessionManager.currentSession?.id) { refresh() }
        .task {
            // Live update while window visible. 15s is a sane balance between
            // responsiveness and SwiftData fetch cost — bumped up from 5s
            // because each refresh triggers ~3 fetches (breakdown + timeline +
            // distractions). Session start/stop triggers an immediate refresh
            // via the .task(id:) above, so the perceived freshness stays high.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                refresh()
            }
        }
    }

    private func refresh() {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: .now)
        breakdown = builder.todayBreakdown()
        distractions = builder.topDistractions(from: dayStart, to: .now, limit: 5)
        // Use the active session window if any, else today
        if let session = appState.sessionManager.currentSession {
            timeline = builder.timeline(from: session.startedAt, to: .now)
        } else {
            timeline = builder.timeline(from: dayStart, to: .now)
        }
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
        if let session = appState.sessionManager.currentSession {
            return "\(session.label ?? "Active session") · \(formatDate(session.startedAt))"
        }
        return "Focus today · \(formatDate(.now))"
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
                Text("No activity yet today")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 32)
            Spacer()
        }
    }

    private var timelineRangeLabel: String {
        if let session = appState.sessionManager.currentSession {
            return "Active session"
        }
        return "Today"
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label).font(.system(size: 11))
                .foregroundStyle(.secondary)
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
                Text("No distractions today")
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
