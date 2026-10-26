import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Work log, a Pro feature built on session goals and debriefs: the week's
/// sessions by day, the projects they went to, a standup draft and a
/// timesheet. Locked, it's a faded preview with a card about it.
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

// MARK: - The log

/// Loads the week from the store and keeps it fresh.
private struct WorkLogView: View {
    @Bindable var appState: AppState
    /// The week, its days and the timesheet's columns all come from this.
    var calendar: Calendar = .current

    @State private var offset = 0
    @State private var model: WorkLogModel

    init(appState: AppState, calendar: Calendar = .current) {
        self._appState = Bindable(wrappedValue: appState)
        self.calendar = calendar
        // Open on the week as last loaded; the fresh copy follows.
        let interval = ReportPeriod.week.interval(offset: 0, calendar: calendar)
        self._model = State(initialValue: appState.windowPages.workLog[interval.start] ?? .empty(interval))
    }

    var body: some View {
        WorkLogContent(model: model, offset: $offset, canWrite: appState.debriefs.canWrite, calendar: calendar) { entry, verdict in
            guard let session = appState.debriefs.session(id: entry.id) else { return }
            appState.debriefs.correct(session, to: verdict)
            reload()
        }
        .task(id: offset) {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: appState.debriefs.writing) { reload() }
        .onChange(of: appState.sessionManager.currentSession?.id) { reload() }
    }

    private func reload() {
        let interval = ReportPeriod.week.interval(offset: offset, calendar: calendar)
        model = WorkLogBuilder.load(interval: interval, context: appState.container.mainContext,
                                    isOptedOut: appState.optOutCache.isOptedOut, calendar: calendar)
        appState.windowPages.workLog[interval.start] = model
    }
}

/// The week laid out: sessions by day on the left; projects, the standup
/// draft and the timesheet on the right.
struct WorkLogContent: View {
    let model: WorkLogModel
    @Binding var offset: Int
    /// Apple Intelligence is there to write debriefs.
    let canWrite: Bool
    /// The one the model was built with, for the CSV's dates.
    var calendar: Calendar = .current
    /// The user's own call on a goal, from the row's menu.
    var onCorrect: (WorkLogEntry, GoalVerdict) -> Void = { _, _ in }

    @State private var editingStandup = false
    @State private var standupText = ""
    @State private var copied = false

    var body: some View {
        WindowScroll {
            PageHeader(title: "Work log", subtitle: subtitle) {
                PeriodStepper(offset: $offset, unit: "week")
                exportMenu
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                let headline = model.headline(offset: offset)
                WindowHeadline(lead: headline.lead, rest: headline.rest)
                if !canWrite { appleIntelligenceNote }
                WindowSplitRow(weights: [1.5, 1]) {
                    sessions
                    VStack(spacing: 12) {
                        projects
                        standup
                        timesheet
                    }
                }
            }
        }
        .onAppear { standupText = model.standup?.text ?? "" }
        .onChange(of: model.standup) {
            standupText = model.standup?.text ?? ""
            editingStandup = false
        }
    }

    private var subtitle: String {
        "Week of \(model.interval.start.formatted(.dateTime.day().month(.wide))) · from your session goals and debriefs"
    }

    private var exportMenu: some View {
        Menu {
            Button("Timesheet as CSV…") { exportTimesheet() }
                .disabled(model.timesheet.rows.isEmpty)
            Button("Copy the work log") { copy(WorkLogText.make(model), flash: false) }
                .disabled(model.days.isEmpty)
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

    private var appleIntelligenceNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Theme.focus).accessibilityHidden(true)
            Text("\(OnDeviceAI.unavailableNote) to write debriefs. Goals, times and apps still show here.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.bodyText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.inset))
    }

    // MARK: Sessions

    private var sessions: some View {
        WindowCard(padding: EdgeInsets(top: 6, leading: 20, bottom: 10, trailing: 20)) {
            if model.days.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.text").font(.system(size: 20)).foregroundStyle(Theme.focus)
                        .accessibilityHidden(true)
                    Text("Nothing logged").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.primaryText)
                    Text("Sessions show up here with their goals and debriefs.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.days) { day in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(day.day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.primaryText)
                                .accessibilityAddTraits(.isHeader)
                            Spacer(minLength: 8)
                            Text("\(WindowFormat.count(day.entries.count, "session")) · \(WindowFormat.hm(day.focused)) focused")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .padding(.top, 12)
                        .padding(.bottom, 6)
                        ForEach(day.entries) { entry in row(entry) }
                    }
                }
            }
        }
    }

    private func row(_ entry: WorkLogEntry) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.end.map { WindowFormat.span(entry.start, $0) } ?? "\(WindowFormat.clock(entry.start))–now")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.primaryText)
                    Text(entry.name)
                    if entry.hasRate {
                        Text("\(Int((entry.focusRate * 100).rounded()))% \(entry.isLive ? "so far" : "focus rate")")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(entry.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(entry.hasGoal ? Theme.primaryText : Theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let project = entry.project { projectChip(project) }
                        stateChip(entry.state)
                    }
                    if let note = entry.note {
                        Text(note)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.bodyText)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !entry.apps.isEmpty {
                        Text(entry.apps).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 10)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if entry.hasGoal && !entry.isLive {
                ForEach(GoalVerdict.allCases, id: \.self) { verdict in
                    Button("Mark as \(verdict.chipText.lowercased())") { onCorrect(entry, verdict) }
                        .disabled(entry.state == .verdict(verdict))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func projectChip(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 11))
            .foregroundStyle(Theme.bodyText)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.track))
            .fixedSize()
    }

    @ViewBuilder private func stateChip(_ state: WorkLogEntry.State) -> some View {
        switch state {
        case .verdict(.done):
            chip(fill: Theme.focusFill, ink: .white) {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                Text("Done")
            }
        case .verdict(.partly):
            chip(fill: Theme.focusTint, ink: Theme.link) {
                Image(systemName: "circle.lefthalf.filled").font(.system(size: 8, weight: .bold))
                Text("Partly")
            }
        case .verdict(.notYet):
            chip(fill: Theme.track, ink: Theme.bodyText) { Text("Not yet") }
        case .live:
            chip(fill: Theme.track, ink: Theme.bodyText) {
                Circle().fill(Theme.focus).frame(width: 6, height: 6)
                Text("In progress")
            }
        case .open:
            EmptyView()
        }
    }

    private func chip<Content: View>(fill: Color, ink: Color, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) { content() }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(fill))
            .fixedSize()
    }

    // MARK: Projects

    /// Indigo, a shade further for each next project; grey for "No project".
    private func projectColor(_ project: WorkLogProject, at index: Int) -> Color {
        guard project.name != nil else { return Theme.other.opacity(0.6) }
        return Self.projectShades[min(index, Self.projectShades.count - 1)]
    }

    /// #6155F5, #9C94FA, #C9C4FC, #E0DDFD; on dark #6D7CFF, #9AA3FF, #4A50A6, #3A3F80.
    private static let projectShades: [Color] = [
        (0x6155F5, 0x6D7CFF), (0x9C94FA, 0x9AA3FF), (0xC9C4FC, 0x4A50A6), (0xE0DDFD, 0x3A3F80),
    ].map { light, dark in
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    private var projects: some View {
        WindowCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)) {
            VStack(alignment: .leading, spacing: 10) {
                WindowCardTitle("Projects")
                if model.projects.isEmpty {
                    Text("No focused time yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    let shown = Array(model.projects.prefix(6))
                    GeometryReader { geo in
                        let total = max(1, shown.reduce(0) { $0 + $1.seconds })
                        let free = geo.size.width - CGFloat(max(0, shown.count - 1)) * 2
                        HStack(spacing: 2) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, project in
                                Rectangle().fill(projectColor(project, at: index))
                                    .frame(width: max(2, free * CGFloat(project.seconds / total)))
                            }
                        }
                    }
                    .frame(height: 8)
                    .clipShape(Capsule())
                    .accessibilityHidden(true)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                              alignment: .leading, spacing: 6) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, project in
                            HStack(spacing: 6) {
                                Circle().fill(projectColor(project, at: index)).frame(width: 8, height: 8)
                                    .accessibilityHidden(true)
                                Text(project.title)
                                    .fontWeight(project.name == nil ? .regular : .semibold)
                                    .foregroundStyle(project.name == nil ? Theme.secondaryText : Theme.primaryText)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(WindowFormat.hm(project.seconds))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .font(.system(size: 12))
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Standup

    private var standup: some View {
        WindowCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)) {
            VStack(alignment: .leading, spacing: 8) {
                if let draft = model.standup {
                    WindowCardTitle("Standup draft", note: "for \(draft.day.formatted(.dateTime.weekday(.wide)))")
                    Group {
                        if editingStandup {
                            TextEditor(text: $standupText)
                                .font(.system(size: 12))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 78)
                        } else {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(standupText.split(separator: "\n").map(String.init), id: \.self) { line in
                                    standupLine(line)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.inset))
                    HStack(spacing: 8) {
                        Button(copied ? "Copied" : "Copy") { copy(standupText) }
                            .buttonStyle(.capsule(.primary, height: 28))
                        Button(editingStandup ? "Done" : "Edit") { editingStandup.toggle() }
                            .buttonStyle(.capsule(.secondary, height: 28))
                        Spacer(minLength: 8)
                        Text("Worked out on this Mac").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                    }
                } else {
                    WindowCardTitle("Standup draft")
                    Text("After a session with a goal, a draft of done, next and blocked shows here.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "Done:" in bold, then the rest.
    private func standupLine(_ line: String) -> some View {
        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
        let text = parts.count == 2
            ? Text(parts[0] + ":").fontWeight(.semibold) + Text(parts[1])
            : Text(line)
        return text
            .font(.system(size: 12))
            .foregroundStyle(Theme.primaryText)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// `flash` turns the standup's Copy into "Copied" for a moment.
    private func copy(_ text: String, flash: Bool = true) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        guard flash else { return }
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    // MARK: Timesheet

    private var timesheet: some View {
        WindowCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)) {
            VStack(alignment: .leading, spacing: 8) {
                WindowCardTitle("Timesheet", note: "focused hours")
                let sheet = model.timesheet
                if sheet.rows.isEmpty {
                    Text("Focused hours per project and day show here.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow {
                            Text("Project").gridColumnAlignment(.leading)
                            ForEach(sheet.days, id: \.self) { Text($0.formatted(.dateTime.weekday(.abbreviated))) }
                            Text("Total").fontWeight(.semibold).foregroundStyle(Theme.primaryText)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        ForEach(sheet.rows, id: \.title) { row in
                            Divider().gridCellUnsizedAxes(.horizontal)
                            GridRow {
                                Text(row.title)
                                    .fontWeight(row.project == nil ? .regular : .semibold)
                                    .foregroundStyle(row.project == nil ? Theme.secondaryText : Theme.primaryText)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                ForEach(Array(row.seconds.enumerated()), id: \.offset) { Text(Timesheet.hours($0.element)) }
                                Text(Timesheet.hours(row.total)).fontWeight(.semibold)
                            }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            Text("Total").fontWeight(.bold)
                            ForEach(Array(sheet.dayTotals.enumerated()), id: \.offset) {
                                Text(Timesheet.hours($0.element)).fontWeight(.semibold)
                            }
                            Text(Timesheet.hours(sheet.total)).fontWeight(.bold)
                        }
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.primaryText)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Text("Projects come from your goals and apps.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Export CSV") { exportTimesheet() }
                        .buttonStyle(.capsule(.secondary, height: 28))
                        .disabled(sheet.rows.isEmpty)
                }
            }
        }
    }

    private func exportTimesheet() {
        let csv = model.timesheet.csv(calendar: calendar)
        let panel = NSSavePanel()
        panel.title = "Export timesheet"
        panel.nameFieldStringValue = "focusguard-timesheet-\(model.interval.start.formatted(.iso8601.year().month().day())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let save: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(csv.utf8).write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Export failed"
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
                let time = entry.end.map { WindowFormat.span(entry.start, $0) } ?? "\(WindowFormat.clock(entry.start))–now"
                var line = "- \(time) \(entry.title)"
                if case .verdict(let verdict) = entry.state { line += " (\(verdict.chipText.lowercased()))" }
                if let project = entry.project { line += " [\(project)]" }
                lines.append(line)
                if let note = entry.note, !entry.isLive { lines.append("  \(note)") }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
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
            PageHeader(title: "Work log", subtitle: "Part of FocusGuard Pro") { EmptyView() }
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
                Text("Give a session a goal when it starts and say how it went when it ends. FocusGuard turns that into a work log, a standup draft and a timesheet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.bodyText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                point("Goals and debriefs", "Done, partly or not, in one click when a session ends.")
                point("Standup draft", "Done, next and blocked, ready to paste into Slack.")
                point("Timesheet", "Focused hours per project and day, exported as CSV.")
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
        let price = "\(ProPricing.yearly) a year or \(ProPricing.monthly) a month"
        let lead = entitlements.canStartTrial ? "Then \(price)." : "\(price.prefix(1).uppercased())\(price.dropFirst())."
        guard sessionsThisWeek > 0 else { return lead }
        let count = sessionsThisWeek == 1 ? "This week's session shows" : "This week's \(sessionsThisWeek) sessions show"
        return "\(lead) \(count) up here as soon as Pro is on."
    }

    private var comingNote: String {
        entitlements.isUnlocked(.workLog)
            ? "The work log arrives in a coming update. It's included in your Pro."
            : "The work log arrives in a coming update, as part of Pro."
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
                    Text("Thursday").font(.system(size: 13, weight: .bold))
                    ForEach(0..<3, id: \.self) { i in entry(width: [220, 180, 240][i], strong: i != 1) }
                    Text("Wednesday").font(.system(size: 13, weight: .bold)).padding(.top, 8)
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
