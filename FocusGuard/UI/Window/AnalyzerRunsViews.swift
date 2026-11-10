import SwiftUI

/// "While your tools worked": the Analyzer's headline. A project's week of
/// tool runs as the tools timed them, how long their answers sat while the
/// user was on a distraction, and what coming back on time would be worth.
struct AnalyzerRunsSection: View {
    let runs: AnalyzerRuns
    /// A test can start: none is running.
    var canTest = false
    /// The hold on a site while a tool works, as it stands: the tool, then the site.
    var hold: (String, String) -> AnalyzerRunsHold = { _, _ in .none }
    var test: (AnalyzerFix) -> Void = { _ in }
    @State private var pickedName: String?
    @State private var pickedDay: Int?
    @State private var pickedRun: Int?
    /// Showing the week as it would be without the waiting.
    @State private var calm = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let sideWidth: CGFloat = 280

    private var timed: [AnalyzerRuns.Project] { runs.projects.filter(\.isTimed) }
    private var untimed: [AnalyzerRuns.Project] { runs.projects.filter { !$0.isTimed } }
    private var picked: AnalyzerRuns.Project? { timed.first { $0.name == pickedName } ?? timed.first }

    var body: some View {
        if let project = picked {
            let day = min(max(pickedDay ?? project.defaultDay, 0), project.days.count - 1)
            let isCalm = calm && project.late > 0
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    AnalyzerRunsHero(project: project, calm: isCalm, holdState: holdState(project), canTest: canTest,
                                     test: test, toggle: toggleCalm)
                    AnalyzerRunsProjects(timed: timed, untimed: untimed, pickedName: project.name, pick: pick)
                        .frame(width: Self.sideWidth)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 10) {
                    AnalyzerRunsWeek(project: project, firstDay: runs.firstDay, day: day, calm: isCalm) { picked in
                        pickedDay = picked
                        pickedRun = nil
                    }
                    .frame(width: Self.sideWidth)
                    AnalyzerRunsChart(project: project, dayName: Self.dayName(day, from: runs.firstDay), runs: project.days[day],
                                      pickedRun: $pickedRun, calm: isCalm)
                }
                .frame(height: 252)
                AnalyzerRunsTiles(project: project)
            }
        }
    }

    private func holdState(_ project: AnalyzerRuns.Project) -> AnalyzerRunsHold {
        guard let pair = project.pair else { return .none }
        return hold(pair.tool, pair.site)
    }

    private func pick(_ name: String) {
        guard name != picked?.name else { return }
        pickedName = name
        pickedDay = nil
        pickedRun = nil
        calm = false
    }

    private func toggleCalm() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { calm.toggle() }
    }

    /// "Tuesday", for the day at `index` of the 7.
    static func dayName(_ index: Int, from first: Date?, short: Bool = false, calendar: Calendar = .current,
                        locale: Locale = .autoupdatingCurrent) -> String {
        guard let first, let date = calendar.date(byAdding: .day, value: index, to: first) else { return "" }
        var style = Date.FormatStyle(locale: locale).weekday(short ? .abbreviated : .wide)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}

// MARK: - The finding

/// The finding in words, the three numbers under it, and what to do about it.
struct AnalyzerRunsHero: View {
    let project: AnalyzerRuns.Project
    let calm: Bool
    let holdState: AnalyzerRunsHold
    let canTest: Bool
    let test: (AnalyzerFix) -> Void
    let toggle: () -> Void

    var body: some View {
        AnalyzerCard(radius: 18, padding: EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20), fillsHeight: true) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    words.frame(minWidth: 280, idealWidth: 280, maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(Theme.separator).frame(width: 1)
                    AnalyzerRunsStats(project: project, calm: calm, across: false).frame(width: 140, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 14) {
                    words
                    AnalyzerRunsStats(project: project, calm: calm, across: true)
                }
            }
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(AnalyzerRunsCopy.kicker(project))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.focus).lineLimit(1)
                Spacer(minLength: 0)
                Text(String(localized: "Last 7 days")).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).fixedSize()
            }
            Text(AnalyzerRunsCopy.headline(project, calm: calm))
                .font(.system(size: 22, weight: .bold))
                .kerning(-0.44)
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(AnalyzerRunsCopy.body(project, calm: calm))
                .font(.system(size: 13))
                .foregroundStyle(Theme.bodyText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            actions.padding(.top, 6)
        }
    }

    @ViewBuilder
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { holdControl; whatIfButton }
            VStack(alignment: .leading, spacing: 8) { holdControl; whatIfButton }
        }
    }

    /// Holding the site while the tool works: on already, under test, or a test to start.
    @ViewBuilder
    private var holdControl: some View {
        if let pair = project.pair {
            switch holdState {
            case .kept(let minutes):
                status(String(localized: "Holding \(pair.site) for \(minutes) min while \(pair.tool) works",
                              comment: "Analyzer: a hold the user kept. The site, minutes, then the tool"), symbol: "checkmark.circle.fill")
            case .testing:
                status(String(localized: "Testing a hold on \(pair.site) while \(pair.tool) works",
                              comment: "Analyzer: a test that's running. The site, then the tool"), symbol: "hourglass")
            case .none:
                if canTest {
                    let minutes = AnalyzerTriggers.holdMinutes
                    Button(String(localized: "Test holding \(pair.site) for \(minutes) min while \(pair.tool) works",
                                  comment: "Analyzer button: start a test. The site, minutes, then the tool")) {
                        test(AnalyzerFix(cause: .habit, change: .holdInWait(tool: pair.tool, site: pair.site, seconds: minutes * 60),
                                         measure: .longestStretch))
                    }
                    .buttonStyle(.capsule(.primary, height: 32))
                    .fixedSize()
                }
            }
        }
    }

    @ViewBuilder
    private var whatIfButton: some View {
        if project.late > 0 {
            Button(calm ? String(localized: "Back to what happened", comment: "Analyzer button: leave the what-if view")
                        : String(localized: "Week without the waiting", comment: "Analyzer button: show the week as if the user came back when each run finished")) {
                toggle()
            }
            .buttonStyle(.capsule(.secondary, height: 32))
            .fixedSize()
        }
    }

    private func status(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.primaryText)
            .frame(minHeight: 32)
    }
}

/// How long the tools worked, in how many runs, and how long they waited.
struct AnalyzerRunsStats: View {
    let project: AnalyzerRuns.Project
    let calm: Bool
    /// Side by side, under the words, where there's no room beside them.
    let across: Bool

    var body: some View {
        if across {
            HStack(alignment: .top, spacing: 14) { stats }
        } else {
            VStack(alignment: .leading, spacing: 12) { stats }
        }
    }

    @ViewBuilder
    private var stats: some View {
        stat(AnalyzerFormat.compact(project.worked),
             String(localized: "tools worked for you", comment: "Analyzer, under a duration"), dot: Theme.focus)
        stat("\(project.runs.count)", AnalyzerRunsCopy.runsLabel(project), dot: nil)
        stat(AnalyzerFormat.compact(calm ? 0 : project.late),
             String(localized: "done, waiting for you", comment: "Analyzer, under a duration: how long finished answers sat"), dot: Theme.distraction)
    }

    private func stat(_ value: String, _ label: String, dot: Color?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.primaryText)
                .contentTransition(.numericText())
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(label).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - By project

/// Each project's tool time and waiting as one bar; picking one shows its week.
struct AnalyzerRunsProjects: View {
    let timed: [AnalyzerRuns.Project]
    let untimed: [AnalyzerRuns.Project]
    let pickedName: String
    let pick: (String) -> Void

    private var most: TimeInterval { timed.map { $0.worked + $0.late }.max() ?? 0 }

    var body: some View {
        AnalyzerCard(fillsHeight: true) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: "By project", comment: "Analyzer card: tool time for each project"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if timed.count > 1 {
                        Text(String(localized: "Pick one", comment: "Analyzer: the projects in the list can be clicked"))
                            .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    }
                }
                VStack(spacing: 2) {
                    ForEach(timed.prefix(4)) { project in row(project) }
                }
                ForEach(untimed.prefix(2)) { project in untimedRow(project) }
            }
        }
    }

    private func row(_ project: AnalyzerRuns.Project) -> some View {
        let isPicked = project.name == pickedName && timed.count > 1
        return Button { pick(project.name) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(project.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(AnalyzerRunsCopy.runCount(project.runs.count))
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText).monospacedDigit()
                }
                AnalyzerRunsBar(worked: project.worked, late: project.late, most: most)
                Text(AnalyzerRunsCopy.split(worked: project.worked, late: project.late))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText).monospacedDigit().lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isPicked ? Theme.focusTint : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    private func untimedRow(_ project: AnalyzerRuns.Project) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(project.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(String(localized: "Not timed", comment: "Analyzer badge: a project whose tool doesn't say when it works"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.chip))
            }
            Text(AnalyzerRunsCopy.untimed(project))
                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8).padding(.top, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One project's bar: the tools working, then their answers waiting, to one scale.
struct AnalyzerRunsBar: View {
    let worked: TimeInterval
    let late: TimeInterval
    let most: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            let widths = Self.widths(worked: worked, late: late, most: most, room: proxy.size.width)
            HStack(spacing: 2) {
                if widths.work > 0 {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Theme.focus).frame(width: widths.work)
                }
                if widths.late > 0 {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Theme.distraction).frame(width: widths.late)
                }
            }
        }
        .frame(height: 8)
    }

    /// The two segments' widths in `room`, with the 2pt gap between them left out.
    static func widths(worked: TimeInterval, late: TimeInterval, most: TimeInterval, room: CGFloat) -> (work: CGFloat, late: CGFloat) {
        guard most > 0, room > 0 else { return (0, 0) }
        let gap: CGFloat = worked > 0 && late > 0 ? 2 : 0
        let unit = (room - gap) / CGFloat(most)
        let work = worked > 0 ? max(3, CGFloat(worked) * unit) : 0
        let wait = late > 0 ? max(3, CGFloat(late) * unit) : 0
        return (work, wait)
    }
}

// MARK: - Day by day

/// The picked project's 7 days: a bar a day, the tools working with the
/// waiting on top. Picking a day shows its runs.
struct AnalyzerRunsWeek: View {
    let project: AnalyzerRuns.Project
    let firstDay: Date?
    let day: Int
    let calm: Bool
    let pick: (Int) -> Void

    static let barHeight: CGFloat = 104

    private var most: TimeInterval {
        project.days.map { $0.reduce(0) { $0 + $1.seconds + $1.late } }.max() ?? 0
    }

    var body: some View {
        AnalyzerCard(fillsHeight: true) {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "Day by day", comment: "Analyzer card: a project's tool time on each of the last 7 days"))
                    .font(.system(size: 13, weight: .semibold))
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(project.days.indices, id: \.self) { index in column(index) }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                VStack(alignment: .leading, spacing: 3) {
                    AnalyzerRunsLegend(color: Theme.focus, label: String(localized: "The tool was working", comment: "Analyzer chart legend"))
                    AnalyzerRunsLegend(color: Theme.distraction,
                                       label: String(localized: "It was done, waiting for you", comment: "Analyzer chart legend"))
                }
            }
        }
    }

    private func column(_ index: Int) -> some View {
        let runs = project.days[index]
        let worked = runs.reduce(0) { $0 + $1.seconds }
        let late = calm ? 0 : runs.reduce(0) { $0 + $1.late }
        let isPicked = index == day
        let label = AnalyzerRunsCopy.day(AnalyzerRunsSection.dayName(index, from: firstDay), runs: runs)
        return Button { pick(index) } label: {
            VStack(spacing: 5) {
                AnalyzerRunsStack(worked: worked, late: late, most: most, height: Self.barHeight, width: 18)
                Text(AnalyzerRunsSection.dayName(index, from: firstDay, short: true))
                    .font(.system(size: 10, weight: isPicked ? .semibold : .regular))
                    .foregroundStyle(isPicked ? Theme.primaryText : Theme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isPicked ? Theme.focusTint : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}

/// A bar from the baseline up: the tool working, and the waiting on top of
/// it, with the top end rounded.
struct AnalyzerRunsStack: View {
    let worked: TimeInterval
    let late: TimeInterval
    let most: TimeInterval
    let height: CGFloat
    let width: CGFloat

    var body: some View {
        let heights = Self.heights(worked: worked, late: late, most: most, room: height)
        VStack(spacing: 2) {
            if heights.late > 0 {
                Self.segment(isTop: true).fill(Theme.distraction).frame(height: heights.late)
            }
            if heights.work > 0 {
                Self.segment(isTop: heights.late <= 0).fill(Theme.focus).frame(height: heights.work)
            } else if heights.late <= 0 {
                Rectangle().fill(Theme.gridFuture).frame(height: 2)
            }
        }
        .frame(width: width, height: height, alignment: .bottom)
    }

    static func segment(isTop: Bool) -> UnevenRoundedRectangle {
        let radius: CGFloat = isTop ? 4 : 0
        return UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                      topTrailingRadius: radius, style: .continuous)
    }

    /// The two segments' heights in `room`, with the 2pt gap between them left out.
    static func heights(worked: TimeInterval, late: TimeInterval, most: TimeInterval, room: CGFloat) -> (work: CGFloat, late: CGFloat) {
        guard most > 0, room > 2 else { return (0, 0) }
        let unit = (room - 2) / CGFloat(most)
        let work = worked > 0 ? max(2, CGFloat(worked) * unit) : 0
        let wait = late > 0 ? max(3, CGFloat(late) * unit) : 0
        return (work, wait)
    }
}

struct AnalyzerRunsLegend: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
    }
}

// MARK: - Run by run

/// The picked day, run by run: how long each took, and how long it sat
/// finished. Picking a run says what happened.
struct AnalyzerRunsChart: View {
    let project: AnalyzerRuns.Project
    let dayName: String
    let runs: [AnalyzerRuns.Run]
    @Binding var pickedRun: Int?
    let calm: Bool

    /// One scale for the whole week, so the days compare.
    private var most: TimeInterval { project.runs.map { $0.seconds + $0.late }.max() ?? 0 }
    private var picked: AnalyzerRuns.Run? { runs.first { $0.id == pickedRun } }

    var body: some View {
        AnalyzerCard(fillsHeight: true) {
            VStack(alignment: .leading, spacing: 8) {
                header
                if runs.isEmpty {
                    Text(AnalyzerRunsCopy.emptyDay(project))
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    AnalyzerRunsPlot(runs: runs, most: most, pickedRun: $pickedRun, calm: calm)
                        .frame(maxHeight: .infinity)
                    Text(story)
                        .font(.system(size: 12))
                        .foregroundStyle(picked == nil ? Theme.secondaryText : Theme.primaryText)
                        .lineLimit(3, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var story: String {
        guard let picked else { return AnalyzerRunsCopy.hint(project) }
        return AnalyzerRunsCopy.story(picked, clock: WindowFormat.clock(picked.start))
    }

    /// Title and legend on one row when they fit; on a narrow window the
    /// legend drops under the title so neither gets cut.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                title.fixedSize()
                Spacer(minLength: 0)
                legend
            }
            VStack(alignment: .leading, spacing: 4) {
                title
                HStack(spacing: 12) { legend }
            }
        }
    }

    private var title: some View {
        Text(dayName + " · " + AnalyzerRunsCopy.runCount(runs.count))
            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
    }

    @ViewBuilder private var legend: some View {
        if project.drifts > 0 {
            mark(Circle().fill(Theme.distraction).frame(width: 6, height: 6),
                 String(localized: "You left for a distraction", comment: "Analyzer chart legend: the dot under a run"))
        }
        if project.asked > 0 {
            mark(Text(verbatim: "?").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.primaryText),
                 String(localized: "It stopped to ask you", comment: "Analyzer tile and legend: a tool needed the user's answer"))
        }
    }

    private func mark(_ symbol: some View, _ label: String) -> some View {
        HStack(spacing: 4) {
            symbol
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .fixedSize()
    }
}

/// The bars: one run each, oldest first, to one scale in minutes.
struct AnalyzerRunsPlot: View {
    let runs: [AnalyzerRuns.Run]
    let most: TimeInterval
    @Binding var pickedRun: Int?
    let calm: Bool

    /// Room for the minute labels, left of the bars.
    static let gutter: CGFloat = 44
    /// Room over the tallest bar, for the "?" on a run that asked.
    static let head: CGFloat = 16
    /// Room under the baseline, for the dot and the time of day.
    static let foot: CGFloat = 26

    var body: some View {
        GeometryReader { proxy in
            let plot = max(24, proxy.size.height - Self.head - Self.foot)
            let room = max(40, proxy.size.width - Self.gutter)
            let column = Self.columnWidth(room: room, count: runs.count)
            ZStack(alignment: .topLeading) {
                grid(plot: plot)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                            AnalyzerRunsColumn(run: run, most: most, plot: plot, width: column, calm: calm,
                                               isPicked: pickedRun == run.id,
                                               showsTime: index % Self.timeStride(column: column) == 0) {
                                pickedRun = pickedRun == run.id ? nil : run.id
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .padding(.leading, Self.gutter)
            }
        }
    }

    /// As wide as fits, between a hit target's width and a comfortable one.
    static func columnWidth(room: CGFloat, count: Int) -> CGFloat {
        min(64, max(14, room / CGFloat(max(1, count))))
    }

    /// Every how many columns the time of day fits under.
    static func timeStride(column: CGFloat) -> Int {
        max(1, Int((36 / max(1, column)).rounded(.up)))
    }

    /// The minute marks and the baseline, behind the bars.
    private func grid(plot: CGFloat) -> some View {
        let marks = AnalyzerRuns.gridMinutes(most: most)
        return ZStack(alignment: .topLeading) {
            ForEach(marks, id: \.self) { minutes in
                let y = Self.head + plot - plot * CGFloat(Double(minutes) * 60 / max(1, most))
                Text(WindowFormat.minutes(TimeInterval(minutes * 60)))
                    .font(.system(size: 9)).foregroundStyle(Theme.secondaryText).monospacedDigit()
                    .frame(width: Self.gutter - 6, alignment: .trailing)
                    .offset(y: y - 6)
                Rectangle().fill(Theme.separator).frame(height: 0.5)
                    .padding(.leading, Self.gutter)
                    .offset(y: y)
            }
            Rectangle().fill(Theme.secondaryText.opacity(0.35)).frame(height: 1)
                .padding(.leading, Self.gutter)
                .offset(y: Self.head + plot)
        }
        .accessibilityHidden(true)
    }
}

/// One run: its bar, a "?" over it when it stopped to ask, a dot under it
/// when the user left for a distraction, and the time of day.
struct AnalyzerRunsColumn: View {
    let run: AnalyzerRuns.Run
    let most: TimeInterval
    let plot: CGFloat
    let width: CGFloat
    let calm: Bool
    let isPicked: Bool
    let showsTime: Bool
    let pick: () -> Void

    var body: some View {
        let story = AnalyzerRunsCopy.story(run, clock: WindowFormat.clock(run.start))
        Button(action: pick) {
            VStack(spacing: 0) {
                bar
                Circle().fill(run.drifted ? Theme.distraction : Color.clear).frame(width: 5, height: 5).padding(.top, 4)
                Text(showsTime ? WindowFormat.clock(run.start) : " ")
                    .font(.system(size: 9)).foregroundStyle(Theme.secondaryText).monospacedDigit()
                    .fixedSize()
                    .frame(width: width)
                    .padding(.top, 3)
            }
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isPicked ? Theme.focusTint : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(story)
        .accessibilityLabel(story)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    private var bar: some View {
        let heights = AnalyzerRunsStack.heights(worked: run.seconds, late: calm ? 0 : run.late, most: most, room: plot)
        return VStack(spacing: 2) {
            if run.asked, width >= 12 {
                Text(verbatim: "?").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.primaryText)
            }
            if heights.late > 0 {
                AnalyzerRunsStack.segment(isTop: true).fill(Theme.distraction).frame(height: heights.late)
            }
            AnalyzerRunsStack.segment(isTop: heights.late <= 0).fill(Theme.focus).frame(height: max(2, heights.work))
        }
        .frame(width: min(24, max(4, width - 6)), height: plot + AnalyzerRunsPlot.head, alignment: .bottom)
    }
}

// MARK: - Tiles

/// What the week's runs add up to: how leaving goes, how often it asked, what's next.
struct AnalyzerRunsTiles: View {
    let project: AnalyzerRuns.Project

    var body: some View {
        let tiles = AnalyzerRunsCopy.tiles(project)
        if !tiles.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                ForEach(tiles) { tile in
                    AnalyzerCard(fillsHeight: true) { content(tile) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func content(_ tile: AnalyzerRunsCopy.Tile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tile.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            Text(tile.value)
                .font(.system(size: tile.isText ? 14 : 18, weight: tile.isText ? .semibold : .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.primaryText)
                .lineLimit(2)
            Text(tile.note).font(.system(size: 12)).foregroundStyle(Theme.bodyText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
