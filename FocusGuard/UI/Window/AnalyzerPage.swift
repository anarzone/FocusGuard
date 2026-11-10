import SwiftUI

/// The Analyzer, a Pro feature: why focus gets lost, one thing to try, and a
/// fair test of it on your own days. Everything comes from fixed rules over
/// tracked data. Locked, it's a faded preview with a card about it.
struct AnalyzerPage: View {
    @Bindable var appState: AppState
    var entitlements: Entitlements = .shared

    var body: some View {
        if AnalyzerAccess.isOpen(shipped: FeatureFlags.analyzer, unlocked: entitlements.isUnlocked(.analyzer)) {
            AnalyzerView(appState: appState)
        } else {
            AnalyzerLocked(entitlements: entitlements)
        }
    }
}

/// Whether the Analyzer is open, and so whether the sidebar shows PRO next to it.
enum AnalyzerAccess {
    static func isOpen(shipped: Bool, unlocked: Bool) -> Bool { shipped && unlocked }
}

/// Which sheet is up.
enum AnalyzerSheet: Identifiable, Equatable {
    case cause(AnalyzerCause)
    case setup(AnalyzerFix)
    case result
    case correct(AnalyzerCause)

    var id: String {
        switch self {
        case .cause(let cause):   return "cause-\(cause.rawValue)"
        case .setup(let fix):     return "setup-\(fix.cause.rawValue)"
        case .result:             return "result"
        case .correct(let cause): return "correct-\(cause.rawValue)"
        }
    }
}

/// Opens on the last report at once, and swaps in the fresh one when it comes.
private struct AnalyzerView: View {
    @Bindable var appState: AppState
    var analyzer: FocusAnalyzer = .shared
    @State private var report: AnalyzerReport?
    @State private var waits = AnalyzerWaitsSummary()
    @State private var runs = AnalyzerRuns()
    @State private var sheet: AnalyzerSheet?
    @AppStorage(SettingsKeys.Goal.weekendsCount) private var weekendsCount = false

    init(appState: AppState) {
        self._appState = Bindable(wrappedValue: appState)
        self._report = State(initialValue: appState.windowPages.analyzer)
    }

    var body: some View {
        AnalyzerContent(report: report, analyzer: analyzer, waits: waits, runs: runs, openSheet: { sheet = $0 },
                        undoCorrection: { cause in
                            analyzer.restore(cause)
                            Task { await reload() }
                        },
                        ruleOut: { moment in
                            AnalyzerRuledOut.toggle(moment)
                            DecisionLog.shared.record(.analyzer, moment.isRuledOut ? "restored" : "ruledOut")
                            Task { await reload() }
                        })
            .task(id: analyzer.muted) { await reload() }
            .task { await analyzer.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .activityTotalsChanged)) { _ in
                Task { await reload() }
            }
            .sheet(item: $sheet) { item in
                sheetView(item)
            }
            // "See the result" on the finished experiment's card or banner.
            .onChange(of: analyzer.wantsResultShown, initial: true) { _, wanted in
                guard wanted else { return }
                analyzer.wantsResultShown = false
                if analyzer.state.finished != nil { sheet = .result }
            }
    }

    private func reload() async {
        let week = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: .now)) ?? .now
        var summary = AnalyzerWaitsSummary.make(WaitLog.shared.records(from: week, to: .now))
        for index in summary.projects.indices {
            summary.projects[index].next = appState.waits.nextTask(summary.projects[index].name)?.title
        }
        waits = summary
        var timed = AnalyzerRuns.make(runs: WaitLog.shared.runs(from: week, to: .now),
                                      waits: WaitLog.shared.records(from: week, to: .now))
        for index in timed.projects.indices {
            timed.projects[index].next = appState.waits.nextTask(timed.projects[index].name)?.title
        }
        runs = timed
        let fresh = await appState.analyzerReport(weekendsCount: weekendsCount)
        appState.windowPages.analyzer = fresh
        report = fresh
    }

    @ViewBuilder
    private func sheetView(_ item: AnalyzerSheet) -> some View {
        switch item {
        case .cause(let cause):
            if let detail = report?.details[cause], let report {
                AnalyzerCauseSheet(cause: cause, detail: detail, workingDays: report.workingDays, analyzer: analyzer,
                                   optedOut: appState.optOutCache.bundleIdentifiers,
                                   context: analyzer.applier?.context() ?? AnalyzerFixes.Context()) { next in
                    sheet = next
                } close: {
                    sheet = nil
                }
            }
        case .setup(let fix):
            AnalyzerSetupSheet(fix: fix, analyzer: analyzer) { sheet = nil }
        case .result:
            if let finished = analyzer.state.finished {
                AnalyzerResultSheet(finished: finished, analyzer: analyzer) { sheet = nil }
            }
        case .correct(let cause):
            AnalyzerCorrectionSheet(cause: cause, analyzer: analyzer) { sheet = nil }
        }
    }
}

/// The page's body, from plain values, so it renders without the app.
struct AnalyzerContent: View {
    let report: AnalyzerReport?
    let analyzer: FocusAnalyzer
    var waits = AnalyzerWaitsSummary()
    var runs = AnalyzerRuns()
    var now: Date = .now
    var openSheet: (AnalyzerSheet) -> Void = { _ in }
    var undoCorrection: (AnalyzerCause) -> Void = { _ in }
    var ruleOut: (AnalyzerTrigger.Moment) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 12) {
            PageHeader(title: String(localized: "Analyzer", comment: "The name of the Analyzer page: why focus gets lost"), subtitle: subtitle) { EmptyView() }
                .padding(.leading, 16)
                .padding(.trailing, 24)
            ScrollView {
                Group {
                    if let report {
                        // What the tools did while the user was away leads,
                        // once they've said enough: it's the one finding with
                        // real times behind it.
                        if runs.isWorthShowing {
                            AnalyzerRunsSection(runs: runs, canTest: analyzer.state.experiment == nil,
                                                hold: { analyzer.state.hold(tool: $0, site: $1) },
                                                test: { openSheet(.setup($0)) })
                                .padding(.bottom, 10)
                        }
                        // What set it off and what the waits turned into come
                        // next: they say what to do differently.
                        if !report.triggers.isEmpty {
                            AnalyzerTriggersCard(triggers: report.triggers, workingDays: report.workingDays, ruleOut: ruleOut,
                                                 canTest: analyzer.state.experiment == nil) { openSheet(.setup($0)) }
                                .padding(.bottom, 10)
                        }
                        if !runs.isWorthShowing, waits.waits > 0 {
                            AnalyzerWaitsCard(summary: waits).padding(.bottom, 10)
                        }
                        AnalyzerPatternCards(patterns: report.patterns).padding(.bottom, 10)
                        if case .learning(let left) = report.finding {
                            AnalyzerEarlyBody(report: report, daysLeft: left)
                        } else {
                            fullBody(report)
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 24)
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var subtitle: String {
        guard let report else { return String(localized: "Worked out on this Mac") }
        let days = report.workingDays
        if case .learning = report.finding {
            return days == 1 ? String(localized: "1 working day so far · worked out on this Mac")
                : String(localized: "\(days) working days so far · worked out on this Mac")
        }
        return String(localized: "Last 4 weeks · \(days) working days · worked out on this Mac")
    }

    private func fullBody(_ report: AnalyzerReport) -> some View {
        VStack(spacing: 10) {
            // "No clear reason yet" says nothing next to triggers that are clear.
            if report.finding != .nothingClear || report.triggers.isEmpty {
                AnalyzerFindingCard(report: report, openSheet: openSheet)
            }
            AnalyzerMeasureGrid(measures: report.measures, previous: report.previous, early: false)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    AnalyzerCausesCard(report: report, analyzer: analyzer, openSheet: openSheet, undoCorrection: undoCorrection)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .layoutPriority(3)
                    AnalyzerExperimentCard(analyzer: analyzer, now: now, openSheet: openSheet)
                        .frame(minWidth: 280, maxWidth: 400)
                        .layoutPriority(2)
                }
                VStack(spacing: 10) {
                    AnalyzerCausesCard(report: report, analyzer: analyzer, openSheet: openSheet, undoCorrection: undoCorrection)
                    AnalyzerExperimentCard(analyzer: analyzer, now: now, openSheet: openSheet)
                }
            }
        }
    }
}

// MARK: - Cards

/// A white card as on the design.
struct AnalyzerCard<Content: View>: View {
    var radius: CGFloat = 16
    var padding = EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
    /// As tall as the row it's in, so cards side by side end together.
    var fillsHeight = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
            .background(shape.fill(Theme.windowCard))
            .overlay(shape.strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
    }
}

/// "What seems to cost you most": the rule's finding, in its own words.
private struct AnalyzerFindingCard: View {
    let report: AnalyzerReport
    let openSheet: (AnalyzerSheet) -> Void

    var body: some View {
        AnalyzerCard(radius: 18, padding: EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20)) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.focus)
                    Text(headline)
                        .font(.system(size: 22, weight: .bold))
                        .kerning(-0.44)
                        .foregroundStyle(Theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(bodyText)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.bodyText)
                        .lineSpacing(2)
                        .frame(maxWidth: 600, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if case .named(let cause) = report.finding {
                    Button("See why") { openSheet(.cause(cause)) }
                        .buttonStyle(.capsule(.primary, height: 44))
                        .fixedSize()
                }
            }
        }
    }

    private var label: String {
        switch report.finding {
        case .named:    return String(localized: "What seems to cost you most", comment: "Analyzer: over the top explanation. Not a claim of certainty")
        case .tooClose: return String(localized: "Too close to name one")
        default:        return String(localized: "Nothing stands out")
        }
    }

    private var headline: String {
        switch report.finding {
        case .named(let cause):
            let time = WindowFormat.hm(report.details[cause]?.row.perDay ?? 0)
            return String(localized: "\(cause.title), about \(time) a day", comment: "Analyzer: a reason focus gets lost, then a compact duration")
        case let .tooClose(first, second):
            return String(localized: "\(first.title) and \(second.title)", comment: "Analyzer: two reasons focus gets lost, about even")
        default:
            return String(localized: "No clear reason yet")
        }
    }

    private var bodyText: String {
        switch report.finding {
        case .named(let cause):
            return cause.explanation
        case .tooClose:
            return String(localized: "These two take about the same time, so FocusGuard won't pick one. Open either below to see the times it happened.")
        default:
            return String(localized: "No reason is big enough or steady enough to name. A week of calls or days off can do that, so it won't guess.")
        }
    }
}

/// The four measures.
struct AnalyzerMeasureGrid: View {
    let measures: AnalyzerMeasures
    let previous: AnalyzerMeasures?
    /// The first week says "so far".
    let early: Bool

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 10, alignment: .top), count: 4), spacing: 10) {
            tile("Longest unbroken stretch", value(measures.longest),
                 note(early ? String(localized: "so far", comment: "Analyzer: a measure in the first week") : String(localized: "a typical day", comment: "Analyzer: a measure's note"),
                      previous?.longest.map(AnalyzerFormat.duration)))
            tile("Deep blocks", measures.deepBlocks.map { String(localized: "\($0.formatted(.number.precision(.fractionLength(0...1)))) a day", comment: "Analyzer: deep blocks in a typical day") } ?? "–",
                 note(String(localized: "25 min or more, unbroken"),
                      previous?.deepBlocks.map { $0.formatted(.number.precision(.fractionLength(0...1))) }))
            tile("Coming back", value(measures.comingBack),
                 measures.comingBack == nil ? String(localized: "needs a few more returns")
                    : note(early ? String(localized: "so far", comment: "Analyzer: a measure in the first week") : String(localized: "after losing focus, typically"),
                           previous?.comingBack.map(AnalyzerFormat.duration)))
            tile("Getting started", value(measures.gettingStarted),
                 measures.gettingStarted == nil ? String(localized: "needs a few more mornings")
                    : note(early ? String(localized: "so far", comment: "Analyzer: a measure in the first week") : String(localized: "sitting down to first focus"),
                           previous?.gettingStarted.map(AnalyzerFormat.duration)))
        }
    }

    private func value(_ seconds: TimeInterval?) -> String { seconds.map(AnalyzerFormat.duration) ?? "–" }

    private func note(_ base: String, _ before: String?) -> String {
        guard let before else { return base }
        return String(localized: "\(base) · \(before) a month ago", comment: "Analyzer: a measure's note, then its value 4 weeks earlier")
    }

    private func tile(_ title: LocalizedStringKey, _ value: String, _ note: String) -> some View {
        AnalyzerCard(padding: EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(value)
                    .font(.system(size: 24, weight: .bold).monospacedDigit())
                    .kerning(-0.48)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

enum AnalyzerFormat {
    /// "34 min", "1h 10m".
    static func duration(_ seconds: TimeInterval) -> String {
        seconds >= 3600 ? WindowFormat.hm(seconds) : WindowFormat.minutes(seconds)
    }

    /// A total, at a glance: "45s", "47m", "3h 12m".
    static func compact(_ seconds: TimeInterval) -> String {
        seconds > 0 && seconds < 60 ? String(localized: "\(Int(seconds))s", comment: "Compact duration") : WindowFormat.hm(seconds)
    }

    /// A time in a sentence: "45s", "6 min", "1h 10m".
    static func short(_ seconds: TimeInterval) -> String {
        seconds < 60 ? String(localized: "\(Int(max(0, seconds)))s", comment: "Compact duration") : duration(seconds)
    }

    /// One run's time, to the second while it's short: "45s", "4m 10s", "12 min".
    static func exact(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds).rounded())
        if whole < 60 || whole >= 600 { return short(TimeInterval(whole)) }
        let m = whole / 60, s = whole % 60
        return s == 0 ? WindowFormat.minutes(TimeInterval(whole)) : String(localized: "\(m)m \(s)s", comment: "Compact duration")
    }

    /// "Tue 10:12–10:48".
    static func when(_ loss: AnalyzerLoss) -> String {
        let weekday = loss.start.formatted(.dateTime.weekday(.abbreviated))
        return "\(weekday) \(WindowFormat.clock(loss.start))–\(WindowFormat.clock(loss.end))"
    }

    /// "Tuesday 10 November".
    static func longDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// "Why focus gets lost, a typical day", and what the person told it.
private struct AnalyzerCausesCard: View {
    let report: AnalyzerReport
    let analyzer: FocusAnalyzer
    let openSheet: (AnalyzerSheet) -> Void
    let undoCorrection: (AnalyzerCause) -> Void

    var body: some View {
        let top = report.rows.map(\.perDay).max() ?? 0
        AnalyzerCard(padding: EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18)) {
            VStack(alignment: .leading, spacing: 11) {
                Text("Why focus gets lost, a typical day")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.rows) { row in
                        if row.cause != nil || row.seconds > 0 { line(row, top: top) }
                    }
                }
                footer
            }
        }
    }

    private func line(_ row: AnalyzerCauseRow, top: TimeInterval) -> some View {
        let leading = row.cause != nil && row.cause.map { report.finding == .named($0) } == true
        let content = HStack(spacing: 10) {
            Text(row.cause?.name ?? String(localized: "Couldn't tell", comment: "Analyzer: lost focus no rule explains"))
                .font(.system(size: 13))
                .foregroundStyle(row.isMuted || row.cause == nil ? Theme.secondaryText : Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 128, alignment: .leading)
            GeometryReader { proxy in
                Capsule().fill(Theme.track)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(leading ? Theme.focus : (row.isMuted || row.cause == nil ? Theme.secondaryText.opacity(0.35) : Theme.focusSoft))
                            .frame(width: top > 0 ? max(row.perDay > 0 ? 4 : 0, proxy.size.width * row.perDay / top) : 0)
                    }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            Text(WindowFormat.hm(row.perDay))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .frame(minWidth: 84, alignment: .trailing)
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        return Group {
            if let cause = row.cause {
                Button { openSheet(.cause(cause)) } label: { content }
                    .buttonStyle(.plain)
            } else {
                content.accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(analyzer.state.corrections) { correction in
                HStack(spacing: 6) {
                    Text(correctionText(correction))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Put it back") { undoCorrection(correction.cause) }
                        .buttonStyle(.textLink)
                        .font(.system(size: 12))
                }
            }
            if case .named(let cause) = report.finding {
                HStack(spacing: 4) {
                    Text("Looks wrong?")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                    Button("Tell it what really happened") { openSheet(.correct(cause)) }
                        .buttonStyle(.textLink)
                        .font(.system(size: 12))
                }
            }
        }
    }

    private func correctionText(_ correction: AnalyzerCorrection) -> String {
        if let actual = correction.actual {
            return String(localized: "You said it's not \(correction.cause.name), more like \(actual.name).", comment: "Analyzer: reasons focus gets lost")
        }
        return String(localized: "You said it's not \(correction.cause.name).", comment: "Analyzer: a reason focus gets lost")
    }
}

/// "Your experiment": running, finished, or none; and fixes kept on.
struct AnalyzerExperimentCard: View {
    let analyzer: FocusAnalyzer
    var now: Date = .now
    let openSheet: (AnalyzerSheet) -> Void

    var body: some View {
        AnalyzerCard(padding: EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18)) {
            VStack(alignment: .leading, spacing: 10) {
                if let experiment = analyzer.state.experiment {
                    running(experiment)
                } else if let finished = analyzer.state.finished {
                    done(finished)
                } else {
                    idle
                }
                ForEach(analyzer.state.kept) { kept in
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Kept on")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.secondaryText)
                            Text(kept.plan)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Button("Stop") { Task { await analyzer.stopKept(kept) } }
                            .buttonStyle(.textLink)
                            .font(.system(size: 12))
                    }
                }
            }
        }
    }

    private func title(_ trailing: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Your experiment")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func running(_ experiment: AnalyzerExperiment) -> some View {
        let day = Calendar.current.startOfDay(for: now)
        let number = min(AnalyzerRules.experimentDays, experiment.countedDays + 1)
        return VStack(alignment: .leading, spacing: 10) {
            title(String(localized: "Day \(number) of \(AnalyzerRules.experimentDays)"))
            Text(experiment.plan)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primaryText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 4), count: 10), spacing: 4) {
                ForEach(experiment.visibleSlots) { slot in chip(slot, isToday: slot.day == day) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "On and Off days in shuffled order; \(experiment.countedDays) done"))
            Text(status(experiment, day: day))
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Stop it") { Task { await analyzer.stop() } }
                .buttonStyle(.textLink)
                .font(.system(size: 12))
        }
    }

    private func status(_ experiment: AnalyzerExperiment, day: Date) -> String {
        let result = AnalyzerFormat.longDay(experiment.resultDay())
        if let first = experiment.slots.first, first.day > day {
            let start = AnalyzerFormat.longDay(first.day)
            return String(localized: "Starts \(start). Result on \(result).")
        }
        switch experiment.slot(on: day)?.arm {
        case .on:  return String(localized: "Today is an On day. Result on \(result).")
        case .off: return String(localized: "Today is an Off day. Result on \(result).")
        case nil:  return String(localized: "Today doesn't count. Result on \(result).")
        }
    }

    private func chip(_ slot: AnalyzerExperiment.Slot, isToday: Bool) -> some View {
        let on = slot.arm == .on, done = slot.state == .counted
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return Text(on ? String(localized: "On", comment: "Analyzer: a day with the change on") : String(localized: "Off", comment: "Analyzer: a day with the change off"))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(on ? (done ? Color.white : Theme.focus) : Theme.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(shape.fill(on ? (done ? Theme.focusFill : Theme.focusTint) : Theme.track))
            .overlay(shape.strokeBorder(Theme.primaryText, lineWidth: isToday ? 1.5 : 0))
    }

    private func done(_ finished: AnalyzerFinished) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            title(String(localized: "Finished", comment: "Analyzer: an experiment is over"))
            Text(finished.outcome.verdict.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text(finished.experiment.plan)
                .font(.system(size: 13))
                .foregroundStyle(Theme.bodyText)
                .fixedSize(horizontal: false, vertical: true)
            Button("See the result") { openSheet(.result) }
                .buttonStyle(.capsule(.primary, height: 30))
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 6) {
            title(nil)
            Text("None running. Open a reason to see what you could test on your own days.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.bodyText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension AnalyzerOutcome.Verdict {
    var title: String {
        switch self {
        case .worked:        return String(localized: "It worked for you")
        case .noDifference:  return String(localized: "No clear difference")
        case .notEnoughDays: return String(localized: "Not enough days")
        }
    }
}

// MARK: - First week

/// Until 7 working days: nothing named, just the numbers so far.
private struct AnalyzerEarlyBody: View {
    let report: AnalyzerReport
    let daysLeft: Int

    var body: some View {
        VStack(spacing: 10) {
            AnalyzerCard(radius: 18, padding: EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20)) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Still learning")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.focus)
                    Text(daysLeft == 1 ? String(localized: "It needs 1 more working day to say why")
                         : String(localized: "It needs \(daysLeft) more working days to say why"))
                        .font(.system(size: 22, weight: .bold))
                        .kerning(-0.44)
                        .foregroundStyle(Theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("A few days could just be an unusual week, so it won't guess yet. Work as you normally do; there's nothing to set up.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.bodyText)
                        .lineSpacing(2)
                        .frame(maxWidth: 600, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            AnalyzerMeasureGrid(measures: report.measures, previous: nil, early: true)
            AnalyzerCard(padding: EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18)) {
                VStack(alignment: .leading, spacing: 11) {
                    Text("What you'll get")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    step(1, String(localized: "Why you lose focus: meetings, chat, habits, unclear tasks or a late-day dip."))
                    step(2, String(localized: "One thing to try, as a simple if-then plan."))
                    step(3, String(localized: "A fair test on your own days, so you can see whether it helped you."))
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.focus)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.focusTint))
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Locked

/// Free: a faded preview of the page with a card about it, as Ask has.
private struct AnalyzerLocked: View {
    let entitlements: Entitlements
    @Environment(\.openWindowSheet) private var openSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: String(localized: "Analyzer", comment: "The name of the Analyzer page: why focus gets lost"),
                       subtitle: String(localized: "Part of FocusGuard Pro")) { EmptyView() }
            ZStack(alignment: .top) {
                skeleton
                    .opacity(0.45)
                    .blur(radius: 1.5)
                    .saturation(0.6)
                    .accessibilityHidden(true)
                card.padding(.top, 36)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.leading, 16)
        .padding(.trailing, 24)
        .padding(.bottom, 20)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.focus)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.focusTint))
                ProBadge()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Why you lose focus, and what helps")
                    .font(.system(size: 22, weight: .bold))
                    .kerning(-0.44)
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("FocusGuard looks at how your working days break up, says what seems to cost the most, and tests one fix on your own days.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.bodyText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                point(String(localized: "Four measures of attention"), String(localized: "Your longest stretch, deep blocks, coming back and getting started."))
                point(String(localized: "A fair test"), String(localized: "Ten working days, half with the change and half without."))
                point(String(localized: "On this Mac"), String(localized: "Worked out here. Nothing leaves it."))
            }
            VStack(spacing: 8) {
                if entitlements.canStartTrial {
                    Button("Try Pro free for \(Plan.trialDays) days") {
                        entitlements.startTrialIfNeeded(for: .analyzer)
                    }
                    .buttonStyle(.capsule(.primary, height: 36, fullWidth: true))
                } else {
                    Button("Get Pro") { openSheet(.upgrade(.analyzer)) }
                        .buttonStyle(.capsule(.primary, height: 36, fullWidth: true))
                }
                Button("See everything in Pro") { openSheet(.upgrade(.analyzer)) }
                    .buttonStyle(.textLink)
                    .frame(height: 32)
            }
            .padding(.top, 4)
            Text(footnote)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 28, leading: 30, bottom: 24, trailing: 30))
        .frame(width: 480)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.headerControlStroke, lineWidth: 0.5))
        .shadow(color: Color(red: 20/255, green: 30/255, blue: 60/255).opacity(0.18), radius: 30, y: 24)
        .frame(maxWidth: .infinity)
    }

    private var footnote: String {
        entitlements.canStartTrial
            ? String(localized: "Then \(ProPricing.yearly) a year or \(ProPricing.monthly) a month.")
            : String(localized: "\(ProPricing.yearly) a year or \(ProPricing.monthly) a month.")
    }

    private func point(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.focusFill))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The faded shapes of the page behind the card.
    private var skeleton: some View {
        VStack(spacing: 10) {
            AnalyzerCard(radius: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Capsule().fill(Theme.focusTint).frame(width: 140, height: 10)
                    Capsule().fill(Theme.secondaryText.opacity(0.4)).frame(width: 320, height: 16)
                    Capsule().fill(Theme.track).frame(height: 8)
                }
            }
            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { _ in
                    AnalyzerCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Capsule().fill(Theme.track).frame(height: 8)
                            Capsule().fill(Theme.secondaryText.opacity(0.4)).frame(width: 60, height: 16)
                            Capsule().fill(Theme.track).frame(height: 8)
                        }
                    }
                }
            }
            AnalyzerCard {
                VStack(spacing: 12) {
                    ForEach([1, 0.7, 0.45, 0.35, 0.2] as [CGFloat], id: \.self) { share in
                        GeometryReader { proxy in
                            Capsule().fill(Theme.focusSoft).frame(width: proxy.size.width * share)
                        }
                        .frame(height: 8)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
