import SwiftUI

/// What the sheets share: a heading and small grey boxes.
private struct AnalyzerStatBox: View {
    let title: String
    let value: String
    var note: String?
    var fill: Color = Theme.inset
    var valueSize: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(.system(size: valueSize, weight: .bold).monospacedDigit())
                .kerning(-0.4)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill))
        .accessibilityElement(children: .combine)
    }
}

private func analyzerHeading(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(Theme.primaryText)
        .accessibilityAddTraits(.isHeader)
}

// MARK: - Why it looks this way

/// A cause: what's behind it, real times it happened, and one thing to try
/// when the data supports one.
struct AnalyzerCauseSheet: View {
    let cause: AnalyzerCause
    let detail: AnalyzerCauseDetail
    let workingDays: Int
    let analyzer: FocusAnalyzer
    let optedOut: Set<String>
    let context: AnalyzerFixes.Context
    let open: (AnalyzerSheet) -> Void
    let close: () -> Void

    private var fix: AnalyzerFix? { AnalyzerFixes.fix(for: cause, detail: detail, context: context) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(cause.title)
                        .font(.system(size: 20, weight: .bold))
                        .kerning(-0.4)
                        .foregroundStyle(Theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    Text("About \(WindowFormat.hm(detail.row.perDay)) a day, over \(workingDays) working days")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                }
                why
                examples
                tryThis
                Text("FocusGuard sees apps, sites and times, not what you were thinking, so this is its best explanation rather than a fact. A test will show whether it helps you.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                buttons
            }
            .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
        }
        .frame(width: 620)
        .frame(maxHeight: 640)
    }

    private var why: some View {
        VStack(alignment: .leading, spacing: 8) {
            analyzerHeading(String(localized: "Why it looks this way"))
            HStack(spacing: 8) {
                switch cause {
                case .unclearTask where detail.withGoal != nil && detail.withoutGoal != nil:
                    if let with = detail.withGoal, let without = detail.withoutGoal {
                        AnalyzerStatBox(title: String(localized: "Sessions with a goal"), value: AnalyzerFormat.duration(with.longest),
                                        note: String(localized: "longest stretch · \(with.count) sessions"))
                        AnalyzerStatBox(title: String(localized: "Sessions without one"), value: AnalyzerFormat.duration(without.longest),
                                        note: String(localized: "longest stretch · \(without.count) sessions"))
                    }
                case .tiredness where detail.earlyRate != nil && detail.lateRate != nil:
                    AnalyzerStatBox(title: String(localized: "Earlier hours"), value: Self.percent(detail.earlyRate),
                                    note: String(localized: "focus rate"))
                    AnalyzerStatBox(title: String(localized: "Later hours"), value: Self.percent(detail.lateRate),
                                    note: String(localized: "focus rate"))
                default:
                    AnalyzerStatBox(title: String(localized: "Times it happened"), value: "\(detail.row.episodes)",
                                    note: String(localized: "on \(detail.row.daysSeen) of \(workingDays) working days"))
                    switch cause {
                    case .chatAndMail:
                        if let app = detail.topMessageApp, !isOptedOutSite(app) {
                            AnalyzerStatBox(title: String(localized: "Most often in"), value: app)
                        }
                    case .habit:
                        if let top = detail.topDistraction, !isOptedOutSite(top.name) {
                            AnalyzerStatBox(title: String(localized: "Most time on"), value: top.name,
                                            note: String(localized: "\(WindowFormat.hm(detail.topDistractionPerDay)) a day"))
                        }
                    default:
                        EmptyView()
                    }
                }
            }
            if cause == .unclearTask, detail.withGoal != nil {
                Text("These two go together here. That doesn't show the goal is the reason.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if cause == .tiredness {
                Text("This is a pattern in the times. FocusGuard can't know how you feel.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A site in an app the person opted out of isn't named.
    private func isOptedOutSite(_ name: String) -> Bool {
        detail.examples.contains { $0.places.contains { $0.name == name && $0.isSite && $0.bundleId.map(optedOut.contains) == true } }
    }

    private static func percent(_ rate: Double?) -> String {
        rate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
    }

    @ViewBuilder
    private var examples: some View {
        if !detail.examples.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                analyzerHeading(String(localized: "Times it happened"))
                VStack(spacing: 0) {
                    ForEach(detail.examples.indices, id: \.self) { index in
                        let loss = detail.examples[index]
                        HStack(spacing: 10) {
                            Text(AnalyzerFormat.when(loss))
                                .foregroundStyle(Theme.secondaryText)
                                .frame(minWidth: 124, alignment: .leading)
                            Text(names(loss))
                                .foregroundStyle(Theme.primaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(trailing(loss))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .font(.system(size: 13).monospacedDigit())
                        .frame(minHeight: 30)
                        if index < detail.examples.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    private func names(_ loss: AnalyzerLoss) -> String {
        let names = loss.placeNames(optedOut: optedOut)
        return names.isEmpty ? String(localized: "Private", comment: "Analyzer: in place of a site's name the person opted out of") : names.joined(separator: ", ")
    }

    private func trailing(_ loss: AnalyzerLoss) -> String {
        cause == .unclearTask ? String(localized: "\(loss.switches) switches") : AnalyzerFormat.duration(loss.seconds)
    }

    @ViewBuilder
    private var tryThis: some View {
        if let fix {
            VStack(alignment: .leading, spacing: 4) {
                Text("Try this")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.focus)
                Text(fix.change.plan)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                if analyzer.state.tested.contains(cause) {
                    Text("You've tested this before, with no clear difference.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.focusTint))
        } else {
            Text("The data doesn't back a fix for this yet, so FocusGuard won't suggest one.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.bodyText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if let fix {
                Button("Test it for 2 weeks") { open(.setup(fix)) }
                    .buttonStyle(.capsule(.primary, height: 44))
                    .disabled(analyzer.isRunning)
            }
            if !detail.row.isMuted {
                Button("That's not it") { open(.correct(cause)) }
                    .buttonStyle(.capsule(.secondary, height: 44))
            }
            Spacer(minLength: 8)
            Button("Close", action: close)
                .buttonStyle(.textLink)
                .keyboardShortcut(.cancelAction)
        }
    }
}

// MARK: - Test it for 2 weeks

/// The plan in the person's words, the 10 days as they'll run, what the app
/// does on On days, and the calendar OK where it's needed.
struct AnalyzerSetupSheet: View {
    let fix: AnalyzerFix
    let analyzer: FocusAnalyzer
    let close: () -> Void
    @State private var plan: String
    @State private var seed = UInt64.random(in: .min ... .max)
    @State private var calendarOK = false

    init(fix: AnalyzerFix, analyzer: FocusAnalyzer, close: @escaping () -> Void) {
        self.fix = fix
        self.analyzer = analyzer
        self.close = close
        self._plan = State(initialValue: fix.change.plan)
    }

    private var slots: [AnalyzerExperiment.Slot] {
        AnalyzerExperiment.schedule(after: analyzer.now(), seed: seed, weekendsCount: analyzer.weekendsCount())
    }

    private var needsCalendar: Bool {
        if case .protectBlock = fix.change { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Test it for 2 weeks")
                    .font(.system(size: 20, weight: .bold))
                    .kerning(-0.4)
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 8) {
                    analyzerHeading(String(localized: "Your plan"))
                    TextEditor(text: $plan)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 62)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.inset))
                        .accessibilityLabel(String(localized: "Your plan"))
                }
                VStack(alignment: .leading, spacing: 8) {
                    analyzerHeading(String(localized: "Your 10 working days"))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 5), count: 5), spacing: 5) {
                        ForEach(slots) { slot in dayChip(slot) }
                    }
                    Text("On days and Off days are shuffled, half and half, so a busy week or a slow Friday can't fool the result.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    row(String(localized: "On days"), fix.change.onDays)
                    row(String(localized: "What it compares"), fix.measure.compares)
                }
                if needsCalendar {
                    Toggle("FocusGuard may add a Focus block to my calendar on On days, and take it off again.", isOn: $calendarOK)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13))
                }
                if let problem = analyzer.problem ?? blockedByCoach {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.distractionInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button(startTitle) {
                        if analyzer.start(fix, plan: plan, seed: seed, calendarOK: calendarOK) { close() }
                    }
                    .buttonStyle(.capsule(.primary, height: 44))
                    .disabled(analyzer.isRunning || analyzer.coachIsRunning || (needsCalendar && !calendarOK))
                    Button("Cancel", action: close)
                        .buttonStyle(.capsule(.secondary, height: 44))
                        .keyboardShortcut(.cancelAction)
                    Spacer(minLength: 8)
                    Text("You can stop any time.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
        }
        .frame(width: 600)
        .frame(maxHeight: 640)
    }

    private var blockedByCoach: String? {
        analyzer.coachIsRunning ? String(localized: "The weekly coach has an experiment on. One at a time keeps both fair.") : nil
    }

    private var startTitle: String {
        let calendar = Calendar.current
        guard let first = slots.first?.day else { return String(localized: "Start tomorrow") }
        if calendar.startOfDay(1, from: analyzer.now()) == first { return String(localized: "Start tomorrow") }
        return String(localized: "Start on \(first.formatted(.dateTime.weekday(.wide)))")
    }

    private func dayChip(_ slot: AnalyzerExperiment.Slot) -> some View {
        let on = slot.arm == .on
        return VStack(spacing: 1) {
            Text(slot.day.formatted(.dateTime.weekday(.abbreviated).day()))
            Text(on ? String(localized: "On", comment: "Analyzer: a day with the change on") : String(localized: "Off", comment: "Analyzer: a day with the change off"))
        }
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .foregroundStyle(on ? Color.white : Theme.bodyText)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Theme.focusFill : Theme.track))
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The result

/// "It worked for you", "No clear difference" or "Not enough days", with the
/// days it's from.
struct AnalyzerResultSheet: View {
    let finished: AnalyzerFinished
    let analyzer: FocusAnalyzer
    let close: () -> Void

    private var measure: AnalyzerMeasureKind { finished.experiment.fix.measure }
    private var outcome: AnalyzerOutcome { finished.outcome }
    private var counted: [AnalyzerExperiment.Slot] { finished.experiment.slots.filter { $0.state == .counted } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(outcome.onDays + outcome.offDays == 1
                         ? String(localized: "Your experiment · 1 working day")
                         : String(localized: "Your experiment · \(outcome.onDays + outcome.offDays) working days"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                    Text(outcome.verdict.title)
                        .font(.system(size: 22, weight: .bold))
                        .kerning(-0.44)
                        .foregroundStyle(Theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    Text(finished.experiment.plan)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.bodyText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    AnalyzerStatBox(title: String(localized: "On days"), value: outcome.onMedian.map(measure.format) ?? "–",
                                    fill: Theme.focusTint, valueSize: 26)
                    AnalyzerStatBox(title: String(localized: "Off days"), value: outcome.offMedian.map(measure.format) ?? "–", valueSize: 26)
                }
                if !counted.isEmpty { chart }
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem = analyzer.problem {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.distractionInk)
                }
                buttons
            }
            .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
        }
        .frame(width: 560)
        .frame(maxHeight: 640)
    }

    private var chart: some View {
        let top = max(counted.compactMap(\.value).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text(measure.chartTitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(counted) { slot in
                    UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                        .fill(slot.arm == .on ? Theme.focusFill : Theme.secondaryText.opacity(0.3))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, 104 * (slot.value ?? 0) / top))
                        .help("\(slot.arm == .on ? String(localized: "On", comment: "Analyzer: a day with the change on") : String(localized: "Off", comment: "Analyzer: a day with the change off")), \(measure.format(slot.value ?? 0))")
                }
            }
            .frame(height: 104, alignment: .bottom)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(note)
            HStack(spacing: 14) {
                legend(String(localized: "On", comment: "Analyzer: a day with the change on"), Theme.focusFill)
                legend(String(localized: "Off", comment: "Analyzer: a day with the change off"), Theme.secondaryText.opacity(0.3))
            }
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.bodyText)
        }
    }

    private var note: String {
        let days = outcome.onDays + outcome.offDays
        switch outcome.verdict {
        case .worked:
            let gap = measure.format((outcome.onMedian ?? 0) - (outcome.offMedian ?? 0))
            switch measure {
            case .longestStretch:
                return String(localized: "Your longest stretch was about \(gap) longer on On days, and the two groups barely overlapped. \(days) days is a small test, but this is a clear gap.")
            case .deepBlocks:
                return String(localized: "You had about \(gap) more deep blocks on On days, and the two groups barely overlapped. \(days) days is a small test, but this is a clear gap.")
            }
        case .noDifference:
            return String(localized: "The two groups overlap too much to tell. This doesn't mean it can't help, only that it didn't show up in these \(days) days.")
        case .notEnoughDays:
            return String(localized: "Too few days counted to compare fairly: \(outcome.onDays) On and \(outcome.offDays) Off. This says nothing for or against it.")
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 8) {
            switch outcome.verdict {
            case .worked:
                Button("Keep it") {
                    Task {
                        await analyzer.keep()
                        if analyzer.problem == nil { close() }
                    }
                }
                .buttonStyle(.capsule(.primary, height: 44))
                Button("Drop it") {
                    analyzer.dismissResult()
                    close()
                }
                .buttonStyle(.capsule(.secondary, height: 44))
            case .noDifference:
                Button("Try something else") {
                    analyzer.dismissResult()
                    close()
                }
                .buttonStyle(.capsule(.primary, height: 44))
                testAgain
            case .notEnoughDays:
                testAgain.buttonStyle(.capsule(.primary, height: 44))
                Button("Drop it") {
                    analyzer.dismissResult()
                    close()
                }
                .buttonStyle(.capsule(.secondary, height: 44))
            }
            Spacer(minLength: 8)
        }
    }

    private var testAgain: some View {
        Button("Test it again") {
            if analyzer.testAgain(seed: .random(in: .min ... .max)) { close() }
        }
        .buttonStyle(.capsule(.secondary, height: 44))
    }
}

// MARK: - The person's word

/// "That's not it" and "Tell it what really happened": remembered, and the
/// cause stops being named. Nothing else follows from it.
struct AnalyzerCorrectionSheet: View {
    let cause: AnalyzerCause
    let analyzer: FocusAnalyzer
    let close: () -> Void
    @State private var actual: AnalyzerCause?
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What really happened?")
                    .font(.system(size: 20, weight: .bold))
                    .kerning(-0.4)
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("FocusGuard will stop naming \(cause.name). You can put it back on the page. Your words stay on this Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.bodyText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("It was more like", selection: $actual) {
                Text("Don't say").tag(AnalyzerCause?.none)
                ForEach(AnalyzerCause.allCases.filter { $0 != cause }) { other in
                    Text(other.name).tag(AnalyzerCause?.some(other))
                }
            }
            TextField("In your own words (optional)", text: $note)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button("That's not it") {
                    analyzer.correct(cause, actual: actual, note: note)
                    close()
                }
                .buttonStyle(.capsule(.primary, height: 36))
                Button("Cancel", action: close)
                    .buttonStyle(.capsule(.secondary, height: 36))
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

/// An On day's question: one line for the session that just started.
struct AnalyzerGoalSheet: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var goal = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What's this session for?")
                    .font(.system(size: 20, weight: .bold))
                    .kerning(-0.4)
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("One line is enough. This is your plan for today's test.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.bodyText)
            }
            TextField("Write the Q4 report", text: $goal)
                .textFieldStyle(.roundedBorder)
                .focused($typing)
                .onSubmit(save)
            HStack(spacing: 8) {
                Button("Set the goal", action: save)
                    .buttonStyle(.capsule(.primary, height: 36))
                    .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Not this time") { dismiss() }
                    .buttonStyle(.capsule(.secondary, height: 36))
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { typing = true }
    }

    private func save() {
        let typed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        if let session = appState.sessionManager.currentSession, session.goal?.isEmpty != false {
            session.goal = String(typed.prefix(SessionGoal.maxLength))
            Persistence.save(appState.container.mainContext)
        }
        dismiss()
    }
}
