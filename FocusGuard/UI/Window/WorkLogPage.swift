import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Your week, a Pro feature built on session goals and debriefs: the week's
/// focus by day and project, an update to share, a standup draft, a timesheet
/// and every session. Locked, it's a faded preview with a card about it.
struct WorkLogPage: View {
    @Bindable var appState: AppState
    var entitlements: Entitlements = .shared

    var body: some View {
        if WorkLogAccess.isOpen(shipped: FeatureFlags.debrief, unlocked: entitlements.isUnlocked(.workLog)) {
            WorkLogView(appState: appState)
        } else {
            WorkLogLocked(appState: appState, entitlements: entitlements)
        }
    }
}

/// Whether the work log is open, and so whether the sidebar shows PRO next
/// to it.
enum WorkLogAccess {
    static func isOpen(shipped: Bool, unlocked: Bool) -> Bool { shipped && unlocked }
}

// MARK: - The week

/// Loads the week from the store and keeps it fresh.
private struct WorkLogView: View {
    @Bindable var appState: AppState
    /// The week, its days and the timesheet's columns all come from this.
    var calendar: Calendar = .current

    @State private var offset = 0
    @State private var model: WorkLogModel
    @State private var report: ReportsModel?
    @AppStorage(SettingsKeys.Goal.weekendsCount) private var weekendsCount = false
    @Environment(\.isOnScreen) private var isOnScreen

    private let edits = WeekEditStore()
    private let colours = WeekColourStore()
    private let blockerStore = WeekBlockerStore()
    /// Bumped when a decision changes, to rebuild the update.
    @State private var editCount = 0
    @State private var blockers = WeekBlockerStore().blockers
    @State private var meetings: [NextMeeting] = []
    /// The week before, for a Monday with nothing yet this week.
    @State private var earlier: WorkLogModel?

    init(appState: AppState, calendar: Calendar = .current) {
        self._appState = Bindable(wrappedValue: appState)
        self.calendar = calendar
        // Open on the week as last loaded; the fresh copy follows.
        let interval = ReportPeriod.week.interval(offset: 0, calendar: calendar)
        self._model = State(initialValue: appState.windowPages.workLog[interval.start] ?? .empty(interval))
        self._report = State(initialValue: appState.windowPages.reports[WindowPageCache.reportsKey(.week, 0)])
    }

    private var overview: WeekOverview {
        WeekOverview.make(model: model, report: report, goal: { FocusGoal.seconds(on: $0, calendar: calendar) },
                          weekendsCount: weekendsCount, remembered: colours.remembered, calendar: calendar)
    }

    private var update: WeekUpdate {
        _ = editCount
        return WeekUpdateBuilder.build(model, decisions: edits.decisions(week: model.interval.start),
                                       links: appState.integrations.taskLinks, calendar: calendar)
    }

    private var standup: WeekStandup {
        WeekStandup.make(model: model, earlier: earlier, isCurrent: offset == 0, tasks: appState.integrations.taskGoals,
                         meetings: meetings, calendar: calendar)
    }

    var body: some View {
        WorkLogContent(
            model: model, overview: overview, update: update, standup: standup, blockers: blockers, offset: $offset, calendar: calendar,
            onCorrect: { entry, verdict in
                guard let session = appState.debriefs.session(id: entry.id) else { return }
                appState.debriefs.correct(session, to: verdict)
                reload()
            },
            onDecide: { line, decision in
                edits.set(decision, line: line, week: model.interval.start)
                editCount += 1
            },
            onAddBlocker: {
                blockerStore.add($0)
                blockers = blockerStore.blockers
            },
            onRemoveBlocker: {
                blockerStore.remove($0)
                blockers = blockerStore.blockers
            },
            onOpenStandup: {
                Task {
                    await appState.integrations.refreshGoalSources()
                    meetings = await appState.integrations.meetingsLeftToday()
                }
            }
        )
        // Every minute while the window can be seen.
        .repeating(every: .seconds(60), while: isOnScreen, id: offset) { reload() }
        .onChange(of: appState.debriefs.writing) { reload() }
        .onChange(of: appState.sessionManager.currentSession?.id) { reload() }
    }

    private func reload() {
        let interval = ReportPeriod.week.interval(offset: offset, calendar: calendar)
        model = WorkLogBuilder.load(interval: interval, context: appState.container.mainContext,
                                    isOptedOut: appState.optOutCache.isOptedOut, calendar: calendar)
        appState.windowPages.workLog[interval.start] = model
        let lastWeek = ReportPeriod.week.interval(offset: offset + 1, calendar: calendar)
        earlier = offset == 0 && !model.days.contains { $0.day < calendar.startOfDay(for: .now) }
            ? WorkLogBuilder.load(interval: lastWeek, context: appState.container.mainContext,
                                  isOptedOut: appState.optOutCache.isOptedOut, calendar: calendar)
            : nil
        let key = WindowPageCache.reportsKey(.week, offset)
        report = appState.windowPages.reports[key]
        let weekOffset = offset
        Task {
            let fresh = await appState.stats.reports(period: .week, offset: weekOffset, now: .now,
                                                     historyStart: Entitlements.shared.historyStart(),
                                                     weekendsCount: weekendsCount)
            appState.windowPages.reports[key] = fresh
            // The user may have stepped to another week meanwhile.
            guard weekOffset == offset else { return }
            report = fresh
            colours.remember(WeekOverview.assignSlots(overview.series.compactMap { $0.slot == nil ? nil : $0.id },
                                                      remembered: colours.remembered))
        }
    }
}

/// The page's views. The top row stays put; the tabs change what's below it.
enum WeekTab: Hashable {
    case week, standup, sheet, log
}

/// The week laid out: its total, its days and its projects along the top; below
/// them a tab, and beside it where that came from.
struct WorkLogContent: View {
    let model: WorkLogModel
    let overview: WeekOverview
    let update: WeekUpdate
    var standup = WeekStandup(lastDay: nil, lastTitle: "", last: [], nextTitle: "", next: [])
    var blockers: [String] = []
    @Binding var offset: Int
    /// The one the model was built with, for the CSV's dates.
    var calendar: Calendar = .current
    /// The user's own call on a goal.
    var onCorrect: (WorkLogEntry, GoalVerdict) -> Void = { _, _ in }
    /// The user's call on a guess; nil takes it back.
    var onDecide: (String, WeekDecision?) -> Void = { _, _ in }
    var onAddBlocker: (String) -> Void = { _ in }
    var onRemoveBlocker: (String) -> Void = { _ in }
    /// Looks up the task list and today's meetings, which take a moment.
    var onOpenStandup: () -> Void = {}

    @State private var tab = WeekTab.week
    @State private var pickedLine: String?
    @State private var pickedSession: UUID?
    @State private var hoverProject: String?
    @State private var pinnedProject: String?
    @State private var copied = false
    @ReduceMotion private var reduced

    private var highlight: String? { hoverProject ?? pinnedProject }

    /// The line picked, else the first one that needs an answer, else the first.
    private var currentLine: WeekLine? {
        update.lines.first { $0.id == pickedLine } ?? update.check.first ?? update.lines.first
    }

    private var currentSession: WorkLogEntry? {
        model.entries.first { $0.id == pickedSession }
    }

    private var chartDays: [Date] { overview.days.map(\.date) }

    var body: some View {
        WindowScroll {
            header
        } content: {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    WeekHeroCard(overview: overview, offset: offset).frame(width: 216)
                    WeekChartCard(overview: overview, highlight: highlight)
                    WeekProjectsCard(overview: overview, hover: $hoverProject, pinned: $pinnedProject).frame(width: 232)
                }
                .frame(height: 188)
                HStack(spacing: 10) {
                    panel.frame(maxWidth: .infinity, maxHeight: .infinity)
                    side.frame(width: 272)
                }
                .frame(minHeight: 320, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .onChange(of: tab) {
            copied = false
            if tab == .standup { onOpenStandup() }
        }
    }

    // MARK: Header

    private var subtitle: String {
        let last = model.interval.end.addingTimeInterval(-1)
        let range = ReportPeriod.week.title(for: DateInterval(start: model.interval.start, end: last), calendar: calendar)
        let projects = overview.series.filter { $0.slot != nil }.count
        return String(localized: "\(range) · \(model.entries.count) sessions · \(projects) projects", comment: "Plural on both: 2 – 8 November · 1 session · 3 projects")
    }

    private var heading: some View {
        Text("Your week")
            .font(.system(size: 22, weight: .bold))
            .kerning(-0.44)
            .foregroundStyle(Theme.primaryText)
            .accessibilityAddTraits(.isHeader)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 1) {
            heading
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
    }

    private var tabs: some View {
        WeekTabs(options: [(WeekTab.week, String(localized: "Week update")),
                           (WeekTab.standup, String(localized: "Standup")),
                           (WeekTab.sheet, String(localized: "Timesheet")),
                           (WeekTab.log, String(localized: "Sessions"))],
                 selection: $tab, label: String(localized: "Choose a view"))
    }

    /// In one row when it fits. On a narrow window the subtitle goes first,
    /// then the tabs drop below.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                title.fixedSize()
                Spacer(minLength: 12)
                PeriodStepper(offset: $offset, unit: .week)
                tabs
            }
            .frame(height: 60)
            HStack(spacing: 12) {
                heading.fixedSize()
                Spacer(minLength: 12)
                PeriodStepper(offset: $offset, unit: .week)
                tabs
            }
            .frame(height: 60)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    title
                    Spacer(minLength: 12)
                    PeriodStepper(offset: $offset, unit: .week)
                }
                tabs
            }
        }
    }

    // MARK: Below the top row

    @ViewBuilder private var panel: some View {
        switch tab {
        case .week:
            WeekUpdateCard(update: update, overview: overview, offset: offset, selected: currentLine?.id, highlight: highlight, copied: copied,
                           onSelect: { pickedLine = $0.id }, onCopy: { copy(update.text(interval: model.interval)) },
                           onBringBack: { update.leftOut.forEach { onDecide($0.id, nil) } }, onCorrect: onCorrect)
        case .standup:
            WeekStandupCard(standup: standup, blockers: blockers, copied: copied,
                            onAddBlocker: onAddBlocker, onRemoveBlocker: onRemoveBlocker,
                            onCopy: { copy(standup.text(blockers: blockers)) })
        case .sheet:
            WeekTimesheetCard(sheet: model.timesheet, onExport: exportTimesheet)
        case .log:
            WeekSessionsCard(model: model, overview: overview, selected: pickedSession, copied: copied, calendar: calendar,
                             onSelect: { pickedSession = $0.id }, onCopy: { copy(WorkLogText.make(model)) })
        }
    }

    @ViewBuilder private var side: some View {
        switch tab {
        case .week:
            WeekSourcePanel(source: currentLine.map(WeekSource.init(line:)), days: chartDays) {
                if let line = currentLine { lineActions(line) }
            }
        case .standup:
            WeekSourcePanel(source: WeekSource(id: "standup", title: String(localized: "Your standup"),
                                               days: standup.lastDay.map { [$0] } ?? [], items: [
                .init(symbol: "checkmark", text: String(localized: "What's behind you comes from your goals")),
                .init(symbol: "checklist", text: String(localized: "Today comes from open goals and your task list")),
                .init(symbol: "calendar", text: String(localized: "Meetings come from your calendar")),
                .init(symbol: "questionmark", text: String(localized: "Only you can say what's blocking you")),
            ]), days: chartDays) { EmptyView() }
        case .sheet:
            WeekSourcePanel(source: note(id: "sheet", title: String(localized: "Your timesheet"), [
                ("clock", String(localized: "Focused hours in sessions, per project and day")),
                ("macwindow", String(localized: "Projects come from your goals and apps")),
            ]), days: chartDays) { EmptyView() }
        case .log:
            if let entry = currentSession {
                WeekSourcePanel(source: WeekSessionText.source(entry, calendar: calendar), days: chartDays) {
                    if entry.hasGoal && !entry.isLive { verdictPicker(entry) }
                }
            } else {
                WeekSourcePanel(source: note(id: "log", title: String(localized: "Every session"), [
                    ("clock", String(localized: "Sessions coloured by project")),
                    ("questionmark", String(localized: "Hover one for its time; click it for its goal and debrief")),
                ]), days: chartDays) { EmptyView() }
            }
        }
    }

    private func note(id: String, title: String, _ items: [(String, String)]) -> WeekSource {
        WeekSource(id: id, title: title, days: Set(model.days.map(\.day)),
                   items: items.map { WeekSource.Item(symbol: $0.0, text: $0.1) })
    }

    @ViewBuilder private func lineActions(_ line: WeekLine) -> some View {
        switch line.group {
        case .check:
            WeekGuessActions(line: line, onKeep: { onDecide(line.id, .kept(name: $0)) }, onLeave: { onDecide(line.id, .left) })
        case .also:
            Button("Take it back") { onDecide(line.id, nil) }
                .buttonStyle(.capsule(.secondary, height: 26))
        case .done, .going:
            if let entry = line.sessions.first(where: { !$0.isLive }) { verdictPicker(entry) }
        }
    }

    private func verdictPicker(_ entry: WorkLogEntry) -> some View {
        var current: GoalVerdict?
        if case .verdict(let verdict) = entry.state { current = verdict }
        return WeekVerdictPicker(current: current) { onCorrect(entry, $0) }
    }

    /// Puts it on the clipboard, and turns the button into "Copied" for a moment.
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    // MARK: Timesheet

    private func exportTimesheet() {
        let csv = model.timesheet.csv(calendar: calendar)
        let panel = NSSavePanel()
        panel.title = String(localized: "Export timesheet")
        panel.nameFieldStringValue = "focusguard-timesheet-\(model.interval.start.formatted(.iso8601.year().month().day())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let save: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(csv.utf8).write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "Export failed")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: save)
        } else {
            panel.begin(completionHandler: save)
        }
    }
}

/// The week as plain text, for pasting into notes.
enum WorkLogText {
    static func make(_ model: WorkLogModel) -> String {
        var lines: [String] = []
        for day in model.days {
            lines.append(day.day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            for entry in day.entries.reversed() {
                let time = entry.end.map { WindowFormat.span(entry.start, $0) }
                    ?? String(localized: "\(WindowFormat.clock(entry.start))–now", comment: "A session still running: 14:05–now")
                var line = "- \(time) \(entry.title)"
                if case .verdict(let verdict) = entry.state { line += " (\(word(for: verdict)))" }
                if let project = entry.project { line += " [\(project)]" }
                lines.append(line)
                if let note = entry.note, !entry.isLive { lines.append("  \(note)") }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// A goal's outcome, in brackets after the session's line.
    private static func word(for verdict: GoalVerdict) -> String {
        switch verdict {
        case .done:   return String(localized: "done", comment: "A session goal's outcome, in a copied work log line")
        case .partly: return String(localized: "partly", comment: "A session goal's outcome, in a copied work log line")
        case .notYet: return String(localized: "not yet", comment: "A session goal's outcome, in a copied work log line")
        }
    }
}

// MARK: - Locked

/// Free (or before the work log ships): a faded preview with a card about it.
private struct WorkLogLocked: View {
    @Bindable var appState: AppState
    let entitlements: Entitlements
    @Environment(\.openWindowSheet) private var openSheet
    @State private var sessionsThisWeek = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: String(localized: "Your week"), subtitle: String(localized: "Part of FocusGuard Pro")) { EmptyView() }
            ZStack(alignment: .top) {
                WorkLogSkeleton()
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
        .onAppear(perform: countSessions)
    }

    private func countSessions() {
        let start = ReportPeriod.week.interval(offset: 0).start
        sessionsThisWeek = Persistence.fetchCount(appState.container.mainContext, FetchDescriptor<Session>(
            predicate: #Predicate { $0.startedAt >= start }
        ))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.focus)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.focusTint))
                ProBadge()
                if !FeatureFlags.debrief { ComingLaterBadge() }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Your week, written up for you")
                    .font(.system(size: 22, weight: .bold))
                    .kerning(-0.44)
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("Give a session a goal when it starts and say how it went when it ends. FocusGuard turns that into a week update, a standup draft and a timesheet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.bodyText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                point(String(localized: "Goals and debriefs"), String(localized: "Done, partly or not, in one click when a session ends."))
                point(String(localized: "Standup draft"), String(localized: "Done, next and blocked, ready to paste into Slack."))
                point(String(localized: "Timesheet"), String(localized: "Focused hours per project and day, exported as CSV."))
            }
            VStack(spacing: 8) {
                if FeatureFlags.debrief && entitlements.canStartTrial {
                    Button("Try Pro free for \(Plan.trialDays) days") {
                        entitlements.startTrialIfNeeded(for: .workLog)
                    }
                    .buttonStyle(.capsule(.primary, height: 36, fullWidth: true))
                } else if FeatureFlags.debrief {
                    Button("Get Pro") { openSheet(.upgrade(.workLog)) }
                        .buttonStyle(.capsule(.primary, height: 36, fullWidth: true))
                } else {
                    Text(comingNote)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.bodyText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.inset))
                }
                Button("See everything in Pro") { openSheet(.upgrade(.workLog)) }
                    .buttonStyle(.textLink)
                    .frame(height: 32)
            }
            .padding(.top, 4)
            if FeatureFlags.debrief {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(EdgeInsets(top: 28, leading: 30, bottom: 24, trailing: 30))
        .frame(width: 480)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.headerControlStroke, lineWidth: 0.5))
        .shadow(color: Color(red: 20/255, green: 30/255, blue: 60/255).opacity(0.18), radius: 30, y: 24)
    }

    private var footnote: String {
        let lead = entitlements.canStartTrial
            ? String(localized: "Then \(ProPricing.yearly) a year or \(ProPricing.monthly) a month.")
            : String(localized: "\(ProPricing.yearly) a year or \(ProPricing.monthly) a month.")
        guard sessionsThisWeek > 0 else { return lead }
        let shows = sessionsThisWeek == 1
            ? String(localized: "This week's session shows up here as soon as Pro is on.")
            : String(localized: "This week's \(sessionsThisWeek) sessions show up here as soon as Pro is on.")
        return "\(lead) \(shows)"
    }

    private var comingNote: String {
        entitlements.isUnlocked(.workLog)
            ? String(localized: "Your week arrives in a coming update. It's included in your Pro.")
            : String(localized: "Your week arrives in a coming update, as part of Pro.")
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
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Coming later", for Pro parts that aren't built yet.
struct ComingLaterBadge: View {
    var body: some View {
        Text("Coming later")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.freeBadgeText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.freeBadge))
            .fixedSize()
    }
}

/// The faded shapes of a work log behind the card.
private struct WorkLogSkeleton: View {
    var body: some View {
        WindowSplitRow(weights: [1.5, 1]) {
            WindowCard(padding: EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20)) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Calendar.current.weekdaySymbols[4]).font(.system(size: 13, weight: .bold))
                    ForEach(0..<3, id: \.self) { i in entry(width: [220, 180, 240][i], strong: i != 1) }
                    Text(Calendar.current.weekdaySymbols[3]).font(.system(size: 13, weight: .bold)).padding(.top, 8)
                    entry(width: 200, strong: true)
                }
            }
            VStack(spacing: 12) {
                WindowCard { Color.clear }.frame(height: 120)
                WindowCard { Color.clear }.frame(height: 180)
                WindowCard { Color.clear }
            }
        }
    }

    private func entry(width: CGFloat, strong: Bool) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.bottom, 10)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(Theme.secondaryText.opacity(0.35)).frame(width: 80, height: 10)
                    Capsule().fill(Theme.track).frame(width: 64, height: 8)
                }
                .frame(width: 112, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Capsule().fill(Theme.secondaryText.opacity(0.4)).frame(maxWidth: width).frame(height: 11)
                        Capsule().fill(strong ? Theme.focus : Theme.focus.opacity(0.3)).frame(width: 52, height: 18)
                    }
                    Capsule().fill(Theme.track).frame(height: 8)
                }
            }
        }
    }
}
