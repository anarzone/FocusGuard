import AppKit
import SwiftUI

// MARK: - Colours and motion

/// One colour per project, three at most, then Other. Picked with the
/// colour-blind checks in the dataviz method: the marks also have gaps
/// between them and labels beside them, so colour never works alone.
enum WeekPalette {
    /// #6155F5, #12B5C9, #B4388F; on dark #8378F0, #0E9FB2, #C03D97.
    private static let projects: [Color] = [
        (0x6155F5, 0x8378F0), (0x12B5C9, 0x0E9FB2), (0xB4388F, 0xC03D97),
    ].map(dynamic)

    /// #C4C4CF, on dark #5C5C68.
    private static let other = dynamic((0xC4C4CF, 0x5C5C68))

    static func colour(slot: Int?) -> Color {
        guard let slot, projects.indices.contains(slot) else { return other }
        return projects[slot]
    }

    private static func dynamic(_ pair: (light: Int, dark: Int)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? pair.dark : pair.light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// The page's few kinds of movement, all off when motion is reduced.
enum WeekMotion {
    /// Things sliding to a new place: the tab pill.
    static let slide = Animation.spring(response: 0.34, dampingFraction: 0.74)
    /// Bars growing in, a little past their height and back.
    static func grow(delay: Double) -> Animation { .spring(response: 0.56, dampingFraction: 0.72).delay(delay) }
    /// Small things popping in.
    static func pop(delay: Double) -> Animation { .spring(response: 0.36, dampingFraction: 0.62).delay(delay) }
    /// Thin bars and hovers.
    static func ease(delay: Double = 0) -> Animation { .easeOut(duration: 0.5).delay(delay) }
    static let hover = Animation.easeOut(duration: 0.18)
}

/// Whether the page's entrance has happened. Starts true with motion off.
private struct WeekEntrance: ViewModifier {
    @Binding var appeared: Bool
    @ReduceMotion private var reduced

    func body(content: Content) -> some View {
        content.onAppear {
            guard !appeared else { return }
            if reduced {
                appeared = true
            } else {
                withAnimation { appeared = true }
            }
        }
    }
}

// MARK: - Tabs

/// A row of choices with a pill that slides to the picked one.
struct WeekTabs<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    let label: String
    @Namespace private var pill
    @ReduceMotion private var reduced

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let picked = option.value == selection
                Button {
                    if reduced {
                        selection = option.value
                    } else {
                        withAnimation(WeekMotion.slide) { selection = option.value }
                    }
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: picked ? .semibold : .regular))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background {
                            if picked {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Theme.switchThumb)
                                    .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.switchTrack))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

// MARK: - The week's total

/// A duration that counts up as it animates.
private struct CountingDuration: View, Animatable {
    var seconds: Double
    var animatableData: Double {
        get { seconds }
        set { seconds = newValue }
    }

    var body: some View {
        Text(WindowFormat.hm(seconds))
            .font(.system(size: 32, weight: .bold))
            .kerning(-0.9)
            .monospacedDigit()
            .foregroundStyle(Theme.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// Focused this week, against the week before, and the daily goal day by day.
struct WeekHeroCard: View {
    let overview: WeekOverview
    let offset: Int
    @State private var shown: Double = 0
    @State private var appeared = false
    @ReduceMotion private var reduced

    var body: some View {
        WindowCard(padding: EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15), radius: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Focused this week")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                CountingDuration(seconds: shown)
                    .accessibilityLabel(WindowFormat.hm(overview.focused))
                if let change = overview.change, abs(change) >= 60 { changePill(change) }
                Spacer(minLength: 0)
                Text("Daily goal met: \(overview.goalMet) of \(overview.goalCounted)", comment: "How many days met the daily focus goal: Daily goal met: 4 of 5")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                HStack(spacing: 5) {
                    ForEach(Array(overview.goalDays.enumerated()), id: \.element.id) { index, day in
                        goalDot(day)
                            .scaleEffect(appeared ? 1 : 0.7)
                            .opacity(appeared ? 1 : 0)
                            .animation(reduced ? nil : WeekMotion.pop(delay: 0.28 + Double(index) * 0.08), value: appeared)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Daily goal met: \(overview.goalMet) of \(overview.goalCounted)", comment: "How many days met the daily focus goal: Daily goal met: 4 of 5"))
            }
        }
        .modifier(WeekEntrance(appeared: $appeared))
        .onAppear { count() }
        .onChange(of: overview.focused) { count() }
    }

    private func count() {
        if reduced {
            shown = overview.focused
        } else {
            withAnimation(.easeOut(duration: 0.9)) { shown = overview.focused }
        }
    }

    private func changePill(_ change: TimeInterval) -> some View {
        let up = change > 0
        let label = offset == 0 ? ReportPeriod.week.previousLabel : String(localized: "vs the week before")
        return Text("\(up ? "↑" : "↓") \(WindowFormat.hm(abs(change))) \(label)", comment: "Change in focus: ↑ 3h 10m vs last week")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(up ? Theme.link : Theme.bodyText)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(up ? Theme.focusTint : Theme.track))
            .scaleEffect(appeared ? 1 : 0.7)
            .opacity(appeared ? 1 : 0)
            .animation(reduced ? nil : WeekMotion.pop(delay: 0.75), value: appeared)
    }

    private func goalDot(_ day: WeekOverview.Day) -> some View {
        Text(WeekVerdict.dayLetter(day.date))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(day.metGoal ? Color.white : Theme.secondaryText)
            .frame(width: 24, height: 24)
            .background(Circle().fill(day.metGoal ? Theme.focusFill : Theme.track))
    }
}

// MARK: - By day and project

/// Stacked bars for the week, the daily goal across them. Hovering a day
/// shows what's in it; hovering a project in the list fades the others.
struct WeekChartCard: View {
    let overview: WeekOverview
    /// The project picked in the list, to fade the rest.
    let highlight: String?
    @State private var hoverDay: Date?
    @State private var appeared = false
    @ReduceMotion private var reduced

    private let labelHeight: CGFloat = 18
    private let barWidth: CGFloat = 26

    var body: some View {
        WindowCard(padding: EdgeInsets(top: 12, leading: 14, bottom: 8, trailing: 14), radius: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Focus by day and project")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                GeometryReader { geo in chart(size: geo.size) }
            }
        }
        .modifier(WeekEntrance(appeared: $appeared))
    }

    private func chart(size: CGSize) -> some View {
        let plot = max(1, size.height - labelHeight)
        let most = max((overview.days.map(\.total).max() ?? 0) * 1.04, overview.goal * 1.15, 3600)
        let scale = plot / most
        let goalY = plot - overview.goal * scale
        let count = max(1, overview.days.count)
        let column = size.width / CGFloat(count)
        return ZStack(alignment: .topLeading) {
            if overview.goal > 0 {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: goalY))
                    path.addLine(to: CGPoint(x: size.width, y: goalY))
                }
                .stroke(Theme.tertiaryText.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .accessibilityHidden(true)
                Text("\(WindowFormat.hm(overview.goal)) goal", comment: "The line across a chart: 4h goal")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: size.width, alignment: .trailing)
                    .offset(y: goalY - 14)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 0) {
                ForEach(Array(overview.days.enumerated()), id: \.element.id) { index, day in
                    bar(day, index: index, scale: scale, plot: plot)
                        .frame(width: column, height: size.height)
                }
            }
            if let day = hoverDay, let index = overview.days.firstIndex(where: { $0.date == day }) {
                tooltip(overview.days[index])
                    .offset(x: tooltipX(index: index, column: column, width: size.width), y: -2)
                    .transition(reduced ? .opacity : .opacity.combined(with: .offset(y: 5)))
                    .allowsHitTesting(false)
                    .zIndex(2)
            }
        }
        .animation(reduced ? nil : WeekMotion.hover, value: hoverDay)
    }

    private func tooltipX(index: Int, column: CGFloat, width: CGFloat) -> CGFloat {
        let wide: CGFloat = 158
        let right = column * CGFloat(index) + column / 2 + barWidth / 2 + 6
        if right + wide <= width { return right }
        return max(0, column * CGFloat(index) + column / 2 - barWidth / 2 - 6 - wide)
    }

    private func bar(_ day: WeekOverview.Day, index: Int, scale: CGFloat, plot: CGFloat) -> some View {
        let parts = overview.series.filter { (day.seconds[$0.id] ?? 0) > 0 }
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                // The first series sits on the baseline, so it's drawn last.
                ForEach(Array(parts.reversed().enumerated()), id: \.element.id) { position, series in
                    let isTop = position == 0
                    let isBottom = position == parts.count - 1
                    UnevenRoundedRectangle(topLeadingRadius: isTop ? 4 : 0, topTrailingRadius: isTop ? 4 : 0)
                        .fill(WeekPalette.colour(slot: series.slot))
                        .frame(width: barWidth, height: max(2, (day.seconds[series.id] ?? 0) * scale - (isBottom ? 0 : 2)))
                        .opacity(segmentOpacity(series, day))
                        .animation(reduced ? nil : WeekMotion.hover, value: highlight)
                        .animation(reduced ? nil : WeekMotion.hover, value: hoverDay)
                }
            }
            .scaleEffect(y: appeared ? 1 : 0, anchor: .bottom)
            .animation(reduced ? nil : WeekMotion.grow(delay: Double(index) * 0.07), value: appeared)
            Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .frame(height: labelHeight)
        }
        .contentShape(Rectangle())
        .onHover { over in
            if over {
                hoverDay = day.date
            } else if hoverDay == day.date {
                hoverDay = nil
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(day))
    }

    private func segmentOpacity(_ series: WeekOverview.Series, _ day: WeekOverview.Day) -> Double {
        if let highlight, highlight != series.id { return 0.22 }
        if let hoverDay, hoverDay != day.date { return 0.45 }
        return 1
    }

    private func spoken(_ day: WeekOverview.Day) -> String {
        let weekday = day.date.formatted(.dateTime.weekday(.wide))
        let parts = overview.series.compactMap { series in
            day.seconds[series.id].map { "\(series.title) \(WindowFormat.hm($0))" }
        }
        return ([weekday, WindowFormat.hm(day.total)] + parts).joined(separator: ", ")
    }

    private func tooltip(_ day: WeekOverview.Day) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(day.date.formatted(.dateTime.weekday(.abbreviated))) · \(WindowFormat.hm(day.total))")
                .font(.system(size: 12, weight: .bold))
            ForEach(overview.series.filter { (day.seconds[$0.id] ?? 0) > 0 }) { series in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(WeekPalette.colour(slot: series.slot))
                        .frame(width: 8, height: 8)
                    Text(series.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(WindowFormat.hm(day.seconds[series.id] ?? 0)).monospacedDigit()
                }
                .font(.system(size: 11))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 158, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(red: 0x17 / 255, green: 0x16 / 255, blue: 0x1F / 255)))
        .shadow(color: .black.opacity(0.3), radius: 11, y: 8)
    }
}

/// The week's projects, each with a thin bar. Hover to fade the others on the
/// page, click to keep it that way.
struct WeekProjectsCard: View {
    let overview: WeekOverview
    @Binding var hover: String?
    @Binding var pinned: String?
    @State private var appeared = false
    @ReduceMotion private var reduced

    var body: some View {
        WindowCard(padding: EdgeInsets(top: 12, leading: 8, bottom: 8, trailing: 8), radius: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Projects")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 3)
                    .accessibilityAddTraits(.isHeader)
                if overview.series.isEmpty {
                    Text("Focus shows up here by project.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 6)
                } else {
                    let most = max(1, overview.series.map(\.seconds).max() ?? 1)
                    ForEach(Array(overview.series.enumerated()), id: \.element.id) { index, series in
                        row(series, index: index, most: most)
                    }
                }
            }
        }
        .modifier(WeekEntrance(appeared: $appeared))
    }

    private func row(_ series: WeekOverview.Series, index: Int, most: TimeInterval) -> some View {
        let focus = hover ?? pinned
        let colour = WeekPalette.colour(slot: series.slot)
        return Button {
            pinned = pinned == series.id ? nil : series.id
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(colour).frame(width: 8, height: 8)
                    Text(series.title)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(WindowFormat.hm(series.seconds))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        Capsule().fill(colour)
                            .frame(width: geo.size.width * CGFloat(series.seconds / most))
                            .scaleEffect(x: appeared ? 1 : 0, anchor: .leading)
                            .animation(reduced ? nil : WeekMotion.ease(delay: 0.2 + Double(index) * 0.08), value: appeared)
                    }
                }
                .frame(height: 4)
            }
            .padding(EdgeInsets(top: 5, leading: 6, bottom: 6, trailing: 6))
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(pinned == series.id ? Theme.focusTint : hover == series.id ? Theme.inset : .clear))
            .contentShape(Rectangle())
            .opacity(focus != nil && focus != series.id ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .onHover { over in
            if over {
                hover = series.id
            } else if hover == series.id {
                hover = nil
            }
        }
        .animation(reduced ? nil : WeekMotion.hover, value: focus)
        .accessibilityLabel("\(series.title), \(WindowFormat.hm(series.seconds))")
        .accessibilityAddTraits(pinned == series.id ? .isSelected : [])
    }
}

// MARK: - The update

/// A tick that draws itself.
private struct TickShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.54))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.76))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.minY + rect.height * 0.24))
        return path
    }
}

/// The round mark before a line: a tick for done, a dash for still going, a
/// question for a guess. Its shape says what colour alone wouldn't.
private struct WeekLineMark: View {
    let group: WeekLine.Group
    let colour: Color
    let delay: Double
    @State private var drawn = false
    @ReduceMotion private var reduced

    var body: some View {
        ZStack {
            Circle().fill(group == .check ? Theme.warning.opacity(0.22) : colour.opacity(0.16))
            switch group {
            case .done, .also:
                TickShape()
                    .trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(group == .also ? Theme.bodyText : Theme.primaryText, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .frame(width: 12, height: 12)
            case .going:
                Capsule().fill(Theme.primaryText)
                    .frame(width: drawn ? 9 : 0, height: 1.8)
            case .check:
                Text(verbatim: "?")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.distractionInk)
                    .scaleEffect(drawn ? 1 : 0.5)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
        .onAppear {
            guard !drawn else { return }
            if reduced {
                drawn = true
            } else {
                withAnimation(.easeOut(duration: 0.42).delay(delay)) { drawn = true }
            }
        }
    }
}

/// Done, still going and what to check, with the way to share it below.
struct WeekUpdateCard: View {
    let update: WeekUpdate
    let overview: WeekOverview
    let offset: Int
    /// The line whose sources show beside it.
    let selected: String?
    let highlight: String?
    let copied: Bool
    let onSelect: (WeekLine) -> Void
    let onCopy: () -> Void
    let onBringBack: () -> Void
    let onCorrect: (WorkLogEntry, GoalVerdict) -> Void
    @ReduceMotion private var reduced

    private var groups: [(title: String, lines: [WeekLine])] {
        [(GoalVerdict.done.chipText, update.done), (String(localized: "Still going"), update.going),
         (String(localized: "Check this"), update.check), (String(localized: "Also this week"), update.also)]
            .filter { !$0.lines.isEmpty }
    }

    var body: some View {
        WindowCard(padding: EdgeInsets(top: 13, leading: 16, bottom: 11, trailing: 16), radius: 16) {
            VStack(alignment: .leading, spacing: 8) {
                if update.isEmpty {
                    empty.frame(maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(groups, id: \.title) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .textCase(.uppercase)
                                    .kerning(0.4)
                                    .foregroundStyle(Theme.secondaryText)
                                    .padding(.leading, 8)
                                    .padding(.bottom, 2)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(group.lines) { line in row(line) }
                            }
                        }
                    }
                    .animation(reduced ? nil : WeekMotion.slide, value: update)
                }
                Spacer(minLength: 0)
                footer
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text").font(.system(size: 20)).foregroundStyle(Theme.focus)
                .accessibilityHidden(true)
            Text(offset == 0 ? String(localized: "No sessions yet this week.")
                 : offset == 1 ? String(localized: "No sessions last week.") : String(localized: "No sessions that week."))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            if offset == 0 {
                Text("Start one, and give it a goal.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ line: WeekLine) -> some View {
        let picked = selected == line.id
        let series = overview.series.first { $0.id == line.project }
        let colour = WeekPalette.colour(slot: series?.slot)
        let faded = highlight != nil && highlight != (series?.id ?? WeekOverview.otherID)
        let index = update.lines.firstIndex { $0.id == line.id } ?? 0
        return Button { onSelect(line) } label: {
            HStack(spacing: 9) {
                WeekLineMark(group: line.group, colour: colour, delay: 0.08 + Double(index) * 0.07)
                Text(line.text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let project = line.project {
                    Text(project)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.bodyText)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(colour, lineWidth: 1))
                        .frame(maxWidth: 130)
                        .fixedSize()
                }
                Text(WindowFormat.hm(line.seconds))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(picked ? Theme.focusTint : line.group == .check ? Theme.warning.opacity(0.09) : .clear))
            .contentShape(Rectangle())
            .opacity(faded ? 0.3 : 1)
        }
        .buttonStyle(.plain)
        .animation(reduced ? nil : WeekMotion.hover, value: highlight)
        .transition(reduced ? .opacity : .opacity.combined(with: .offset(y: 7)))
        .contextMenu { verdictMenu(line) }
        .accessibilityLabel("\(line.text), \(WindowFormat.hm(line.seconds))")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    @ViewBuilder private func verdictMenu(_ line: WeekLine) -> some View {
        if line.group == .done || line.group == .going, let entry = line.sessions.first(where: { !$0.isLive }) {
            ForEach(GoalVerdict.allCases, id: \.self) { verdict in
                Button(WeekVerdict.markTitle(verdict)) { onCorrect(entry, verdict) }
                    .disabled(entry.state == .verdict(verdict))
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !update.leftOut.isEmpty {
                Button(String(localized: "Left out: \(update.leftOut.count). Bring back", comment: "Lines the user left out of the week update, and the button to bring them back"),
                       action: onBringBack)
                    .buttonStyle(.textLink)
            }
            HStack(spacing: 8) {
                WeekReadiness(ready: update.isReady, text: update.isReady
                    ? String(localized: "Ready to share. Only on this Mac until you copy it.")
                    : String(localized: "\(update.check.count) lines to check before you share this.", comment: "Plural on count: 1 line to check before you share this."))
                Spacer(minLength: 8)
                Button(copied ? String(localized: "Copied") : String(localized: "Copy"), action: onCopy)
                    .buttonStyle(.capsule(.primary, height: 30))
                    .disabled(update.lines.isEmpty)
            }
        }
    }
}

/// "1 line to check", turning into "Ready to share" with a tick drawing itself.
struct WeekReadiness: View {
    let ready: Bool
    let text: String
    @ReduceMotion private var reduced

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(ready ? Theme.focusFill : Theme.warning)
                if ready {
                    TickShape()
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .frame(width: 10, height: 10)
                        .transition(reduced ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.bodyText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(reduced ? nil : WeekMotion.pop(delay: 0), value: ready)
    }
}

// MARK: - Where it came from

enum WeekVerdict {
    /// "M" for Monday. Some languages have no narrow name and give a number
    /// (Azerbaijani's Monday is "1"); those use the abbreviation without its dots.
    static func dayLetter(_ day: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let narrow = day.formatted(Date.FormatStyle(locale: locale).weekday(.narrow))
        guard narrow.contains(where: \.isNumber) else { return narrow }
        return day.formatted(Date.FormatStyle(locale: locale).weekday(.abbreviated)).filter { $0 != "." }
    }

    static func markTitle(_ verdict: GoalVerdict) -> String {
        switch verdict {
        case .done:   return String(localized: "Mark as done")
        case .partly: return String(localized: "Mark as partly")
        case .notYet: return String(localized: "Mark as not yet")
        }
    }

}

/// What the panel beside a tab shows.
struct WeekSource: Equatable {
    struct Item: Equatable, Identifiable {
        let symbol: String
        let text: String
        var id: String { symbol + text }
    }

    let id: String
    let title: String
    let days: Set<Date>
    let items: [Item]

    static func symbol(_ kind: WeekLine.Evidence.Kind) -> String {
        switch kind {
        case .time:    return "clock"
        case .verdict: return "checkmark"
        case .task:    return "checklist"
        case .apps:    return "macwindow"
        case .note:    return "text.quote"
        case .ask:     return "questionmark"
        }
    }

    init(id: String, title: String, days: Set<Date>, items: [Item]) {
        self.id = id
        self.title = title
        self.days = days
        self.items = items
    }

    init(line: WeekLine) {
        self.init(id: line.id, title: line.group == .check ? String(localized: "Was this \(line.text)", comment: "Asking about a guess, whose text ends in a question mark: Was this github.com?") : line.text,
                  days: line.days,
                  items: line.evidence.map { Item(symbol: Self.symbol($0.kind), text: $0.text) })
    }
}

/// "Where this came from": the days a line drew on and what it stands on,
/// with whatever's left to decide about it below.
struct WeekSourcePanel<Actions: View>: View {
    let source: WeekSource?
    let days: [Date]
    @ViewBuilder var actions: () -> Actions
    @ReduceMotion private var reduced

    var body: some View {
        WindowCard(padding: EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14), radius: 16) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Where this came from")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                if let source {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(source.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        dayChips(source.days)
                        ForEach(Array(source.items.enumerated()), id: \.element.id) { index, item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.focus)
                                    .frame(width: 14, height: 16)
                                    .accessibilityHidden(true)
                                Text(item.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.bodyText)
                                    .lineSpacing(1.5)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .modifier(WeekRise(delay: Double(index) * 0.07))
                        }
                    }
                    .id(source.id)
                } else {
                    Text("Pick a line to see what it stands on.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
                actions()
            }
        }
    }

    private func dayChips(_ active: Set<Date>) -> some View {
        HStack(spacing: 4) {
            ForEach(days, id: \.self) { day in
                let on = active.contains(day)
                Text(WeekVerdict.dayLetter(day))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(on ? Color.white : Theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Theme.focusFill : Theme.track))
            }
        }
        .animation(reduced ? nil : WeekMotion.hover, value: active)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Days this drew on: \(days.filter(active.contains).map { $0.formatted(.dateTime.weekday(.wide)) }.joined(separator: ", "))"))
    }
}

/// Fades up from a little below.
private struct WeekRise: ViewModifier {
    let delay: Double
    @State private var shown = false
    @ReduceMotion private var reduced

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 7)
            .onAppear {
                if reduced {
                    shown = true
                } else {
                    withAnimation(.easeOut(duration: 0.32).delay(delay)) { shown = true }
                }
            }
    }
}

/// What to do with a guess: keep it, name it, or leave it out.
struct WeekGuessActions: View {
    let line: WeekLine
    let onKeep: (String?) -> Void
    let onLeave: () -> Void
    @State private var renaming = false
    @State private var name = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FocusGuard is guessing, so it stays out of your update unless you keep it.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.bodyText)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
            if renaming {
                TextField("What was it?", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($fieldFocused)
                    .onSubmit(save)
                HStack(spacing: 6) {
                    Button("Save", action: save)
                        .buttonStyle(.capsule(.primary, height: 26))
                        .disabled(trimmed.isEmpty)
                    Button("Cancel") { renaming = false }
                        .buttonStyle(.capsule(.secondary, height: 26))
                }
            } else {
                Button("Keep it") { onKeep(nil) }
                    .buttonStyle(.capsule(.primary, height: 26, fullWidth: true))
                HStack(spacing: 6) {
                    Button("Rename") {
                        name = ""
                        renaming = true
                        fieldFocused = true
                    }
                    .buttonStyle(.capsule(.secondary, height: 26, fullWidth: true))
                    Button("Leave out", action: onLeave)
                        .buttonStyle(.capsule(.secondary, height: 26, fullWidth: true))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.warning.opacity(0.12)))
        .id(line.id)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onKeep(trimmed)
    }
}

/// How a goal went, in one click: three choices, the current one filled.
struct WeekVerdictPicker: View {
    let current: GoalVerdict?
    let onPick: (GoalVerdict) -> Void
    @ReduceMotion private var reduced

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("How did it go?")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 4) {
                ForEach(GoalVerdict.allCases, id: \.self) { verdict in
                    let on = verdict == current
                    Button { onPick(verdict) } label: {
                        Text(verdict.chipText)
                            .font(.system(size: 12, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.white : Theme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.focusFill : Theme.track))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(WeekVerdict.markTitle(verdict))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .animation(reduced ? nil : WeekMotion.hover, value: current)
        }
    }
}

// MARK: - Sessions

/// The week as a timeline: a lane per day, a bar per session, coloured by
/// project. Clicking one shows its goal and debrief beside it.
struct WeekSessionsCard: View {
    let model: WorkLogModel
    let overview: WeekOverview
    let selected: UUID?
    let copied: Bool
    var now: Date = .now
    var calendar: Calendar = .current
    let onSelect: (WorkLogEntry) -> Void
    let onCopy: () -> Void
    @State private var appeared = false
    @State private var hovered: UUID?
    @ReduceMotion private var reduced

    /// Whole hours the lanes cover: the week's sessions, at least a working day.
    private var hours: ClosedRange<Int> {
        var first = 9, last = 18
        for entry in model.entries {
            let start = calendar.startOfDay(for: entry.start)
            first = min(first, Int(entry.start.timeIntervalSince(start) / 3600))
            last = max(last, Int(ceil(min((entry.end ?? now).timeIntervalSince(start), 24 * 3600) / 3600)))
        }
        return first...min(24, max(last, first + 1))
    }

    var body: some View {
        WindowCard(padding: EdgeInsets(top: 13, leading: 16, bottom: 11, trailing: 16), radius: 16) {
            VStack(alignment: .leading, spacing: 5) {
                axis
                ForEach(Array(overview.days.enumerated()), id: \.element.id) { index, day in
                    lane(day.date, index: index)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Text("\(model.entries.count) sessions, coloured by project", comment: "Plural on count: 1 session, coloured by project")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.bodyText)
                    Spacer(minLength: 8)
                    Button(copied ? String(localized: "Copied") : String(localized: "Copy"), action: onCopy)
                        .buttonStyle(.capsule(.primary, height: 30))
                        .disabled(model.days.isEmpty)
                }
            }
        }
        .modifier(WeekEntrance(appeared: $appeared))
    }

    private var axis: some View {
        let range = hours
        return GeometryReader { geo in
            let span = CGFloat(range.upperBound - range.lowerBound)
            ForEach(Array(stride(from: range.lowerBound, to: range.upperBound, by: 2)), id: \.self) { hour in
                Text(calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)?.formatted(date: .omitted, time: .shortened) ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                    .offset(x: geo.size.width * CGFloat(hour - range.lowerBound) / span)
            }
        }
        .frame(height: 14)
        .padding(.leading, 34)
        .accessibilityHidden(true)
    }

    private func lane(_ date: Date, index: Int) -> some View {
        let range = hours
        let entries = model.entries.filter { calendar.isDate($0.start, inSameDayAs: date) }
        return HStack(spacing: 6) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)))
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .frame(width: 28, alignment: .leading)
            GeometryReader { geo in
                let perHour = geo.size.width / CGFloat(range.upperBound - range.lowerBound)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.inset)
                    ForEach(Array(entries.enumerated()), id: \.element.id) { position, entry in
                        sessionBar(entry, day: date, perHour: perHour, range: range, delay: Double(index) * 0.06 + Double(position) * 0.05)
                    }
                }
            }
            .frame(height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func sessionBar(_ entry: WorkLogEntry, day: Date, perHour: CGFloat, range: ClosedRange<Int>, delay: Double) -> some View {
        let start = entry.start.timeIntervalSince(calendar.startOfDay(for: day)) / 3600 - Double(range.lowerBound)
        let hoursLong = (entry.end ?? now).timeIntervalSince(entry.start) / 3600
        let series = overview.series.first { $0.id == entry.project }
        let picked = selected == entry.id
        return Button { onSelect(entry) } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(WeekPalette.colour(slot: series?.slot))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Theme.primaryText, lineWidth: picked ? 1.5 : 0))
                .brightness(hovered == entry.id ? 0.06 : 0)
                .frame(width: max(4, CGFloat(hoursLong) * perHour))
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { over in
            if over {
                hovered = entry.id
            } else if hovered == entry.id {
                hovered = nil
            }
        }
        .help(helpText(entry))
        .accessibilityLabel(helpText(entry))
        .accessibilityAddTraits(picked ? .isSelected : [])
        .scaleEffect(x: appeared ? 1 : 0, anchor: .leading)
        .opacity(appeared ? 1 : 0)
        .animation(reduced ? nil : WeekMotion.ease(delay: delay), value: appeared)
        .offset(x: CGFloat(start) * perHour)
    }

    private func helpText(_ entry: WorkLogEntry) -> String {
        "\(entry.title), \(WeekSessionText.time(entry))"
    }
}

enum WeekSessionText {
    /// "14:05–15:30", or "14:05–now" while it runs.
    static func time(_ entry: WorkLogEntry) -> String {
        entry.end.map { WindowFormat.span(entry.start, $0) }
            ?? String(localized: "\(WindowFormat.clock(entry.start))–now", comment: "A session still running: 14:05–now")
    }

    static func source(_ entry: WorkLogEntry, calendar: Calendar = .current) -> WeekSource {
        var items = [WeekSource.Item(symbol: "clock", text: "\(time(entry)) · \(WindowFormat.hm(entry.focused))")]
        if entry.hasRate {
            let rate = Int((entry.focusRate * 100).rounded())
            items.append(.init(symbol: "scope", text: entry.isLive ? String(localized: "\(rate)% so far") : String(localized: "\(rate)% focus rate")))
        }
        if !entry.apps.isEmpty { items.append(.init(symbol: "macwindow", text: entry.apps)) }
        if let note = entry.note { items.append(.init(symbol: "text.quote", text: note)) }
        return WeekSource(id: entry.id.uuidString, title: entry.title,
                          days: [calendar.startOfDay(for: entry.start)], items: items)
    }
}

// MARK: - Standup

/// Three columns: the last day worked, what's on today, and what's blocking.
struct WeekStandupCard: View {
    let standup: WeekStandup
    let blockers: [String]
    let copied: Bool
    let onAddBlocker: (String) -> Void
    let onRemoveBlocker: (String) -> Void
    let onCopy: () -> Void
    @State private var adding = false
    @State private var blocker = ""
    @FocusState private var fieldFocused: Bool
    @ReduceMotion private var reduced

    var body: some View {
        WindowCard(padding: EdgeInsets(top: 13, leading: 16, bottom: 11, trailing: 16), radius: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    column(standup.lastTitle, index: 0) {
                        ForEach(standup.last) { item($0) }
                        if standup.last.isEmpty { note(String(localized: "Nothing to look back on yet.")) }
                    }
                    column(standup.nextTitle, index: 1) {
                        ForEach(standup.next) { item($0) }
                        if standup.next.isEmpty { note(String(localized: "Nothing open. Set a goal when you start.")) }
                    }
                    column(String(localized: "Blocked", comment: "A standup's column for what's in the way"), index: 2) {
                        ForEach(blockers, id: \.self) { blockerRow($0) }
                        addBlocker
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                HStack(spacing: 8) {
                    WeekReadiness(ready: true, text: String(localized: "Ready to share. Only on this Mac until you copy it."))
                    Spacer(minLength: 8)
                    Button(copied ? String(localized: "Copied") : String(localized: "Copy for Slack"), action: onCopy)
                        .buttonStyle(.capsule(.primary, height: 30))
                        .disabled(standup.isEmpty && blockers.isEmpty)
                }
            }
        }
    }

    private func column<Content: View>(_ title: String, index: Int, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            content()
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.inset))
        .modifier(WeekRise(delay: Double(index) * 0.09))
    }

    private func item(_ item: WeekStandup.Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(item.from)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.windowCard))
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func blockerRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { onRemoveBlocker(text) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.track))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Remove \(text)", comment: "Taking a blocker off a standup"))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.windowCard))
        .transition(reduced ? .opacity : .opacity.combined(with: .offset(y: 6)))
    }

    @ViewBuilder private var addBlocker: some View {
        if adding {
            TextField("What's in the way?", text: $blocker)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($fieldFocused)
                .onSubmit(saveBlocker)
                .onExitCommand { adding = false }
        } else {
            Button {
                blocker = ""
                adding = true
                fieldFocused = true
            } label: {
                Label("Add a blocker", systemImage: "plus")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.link)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func saveBlocker() {
        withAnimation(reduced ? nil : WeekMotion.slide) { onAddBlocker(blocker) }
        adding = false
    }
}

// MARK: - Timesheet

/// Hours per project and day as a grid, each cell shaded by how many hours are
/// in it: one hue, light to dark, with the number on it.
struct WeekTimesheetCard: View {
    let sheet: Timesheet
    let onExport: () -> Void

    private var most: TimeInterval { max(1, sheet.rows.flatMap(\.seconds).max() ?? 1) }

    var body: some View {
        WindowCard(padding: EdgeInsets(top: 13, leading: 16, bottom: 11, trailing: 16), radius: 16) {
            VStack(alignment: .leading, spacing: 8) {
                if sheet.rows.isEmpty {
                    Text("Focused hours per project and day show here.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    grid
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    WeekReadiness(ready: true, text: String(localized: "Ready to share. Only on this Mac until you copy it."))
                    Spacer(minLength: 8)
                    Button("Export CSV", action: onExport)
                        .buttonStyle(.capsule(.primary, height: 30))
                        .disabled(sheet.rows.isEmpty)
                }
            }
        }
    }

    private var grid: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                Text("Project")
                    .gridColumnAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(sheet.days, id: \.self) { Text($0.formatted(.dateTime.weekday(.abbreviated))).frame(maxWidth: .infinity) }
                Text("Total").frame(maxWidth: .infinity)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            ForEach(Array(sheet.rows.enumerated()), id: \.element.title) { index, row in
                GridRow {
                    Text(row.title)
                        .foregroundStyle(row.project == nil ? Theme.secondaryText : Theme.primaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    ForEach(Array(row.seconds.enumerated()), id: \.offset) { column, seconds in
                        cell(seconds, day: sheet.days[column], project: row.title)
                    }
                    Text(Timesheet.hours(row.total))
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .modifier(WeekRise(delay: Double(index) * 0.05))
            }
            GridRow {
                Text("Total")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                ForEach(Array(sheet.dayTotals.enumerated()), id: \.offset) { _, seconds in
                    Text(Timesheet.hours(seconds)).fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                Text(Timesheet.hours(sheet.total)).fontWeight(.bold).frame(maxWidth: .infinity)
            }
            .modifier(WeekRise(delay: Double(sheet.rows.count) * 0.05))
        }
        .font(.system(size: 13).monospacedDigit())
        .foregroundStyle(Theme.primaryText)
    }

    private func cell(_ seconds: TimeInterval, day: Date, project: String) -> some View {
        Text(Timesheet.hours(seconds))
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(seconds < 1 ? AnyShapeStyle(Theme.inset) : AnyShapeStyle(Theme.focus.opacity(0.1 + seconds / most * 0.55))))
            .accessibilityLabel("\(project), \(day.formatted(.dateTime.weekday(.wide))), \(WindowFormat.hm(seconds))")
    }
}
