import SwiftUI

/// "What sets it off": the triggers, most time first. Picking one shows why
/// the rule thinks so and each time it happened, any of which the user can
/// rule out.
struct AnalyzerTriggersCard: View {
    let triggers: [AnalyzerTrigger]
    let workingDays: Int
    var ruleOut: (AnalyzerTrigger.Moment) -> Void = { _ in }
    /// A test can start: none is running. Wait triggers offer to test a hold.
    var canTest = false
    var test: (AnalyzerFix) -> Void = { _ in }
    @State private var pickedID: String?

    private var picked: AnalyzerTrigger? { triggers.first { $0.id == pickedID } ?? triggers.first }

    var body: some View {
        AnalyzerCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: "What pulls you away", comment: "Analyzer card: what the user was doing right before losing focus"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(String(localized: "What you did right before you drifted", comment: "Analyzer card subtitle"))
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                VStack(spacing: 2) {
                    ForEach(Array(triggers.enumerated()), id: \.element.id) { index, trigger in
                        row(trigger, rank: index + 1)
                    }
                }
                if let picked { evidence(picked) }
            }
        }
    }

    private func row(_ trigger: AnalyzerTrigger, rank: Int) -> some View {
        let isPicked = trigger.id == picked?.id
        let sure = trigger.sureness(workingDays: workingDays)
        return Button { pickedID = trigger.id } label: {
            HStack(spacing: 10) {
                Text("\(rank)")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(isPicked ? Theme.focus : Theme.chip))
                    .foregroundStyle(isPicked ? Color.white : Theme.primaryText)
                AnalyzerTriggerChain(steps: trigger.steps)
                Spacer(minLength: 8)
                AnalyzerTriggerBars(perDay: trigger.perDay)
                    .accessibilityLabel(String(localized: "Times a day: \(trigger.perDay.map(String.init).joined(separator: ", "))"))
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(localized: "\(trigger.count)×", comment: "How many times a trigger happened: 14×"))
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    Text(WindowFormat.hm(trigger.seconds)).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).monospacedDigit()
                }
                .frame(minWidth: 52, alignment: .trailing)
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { step in
                        Circle().fill(step < sure ? Theme.focus : Theme.gridFuture).frame(width: 6, height: 6)
                    }
                }
                .help(Self.sureLabel(sure))
                .accessibilityLabel(Self.sureLabel(sure))
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isPicked ? Theme.focusTint : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    static func sureLabel(_ sure: Int) -> String {
        switch sure {
        case 3:  return String(localized: "Sure: seen on most days")
        case 2:  return String(localized: "Fairly sure")
        default: return String(localized: "Early: could change")
        }
    }

    private func evidence(_ trigger: AnalyzerTrigger) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AnalyzerTriggers.because(trigger, workingDays: workingDays))
                .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(trigger.moments.prefix(6)) { moment in
                HStack(spacing: 10) {
                    Text(moment.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                        .font(.system(size: 12)).monospacedDigit()
                        .frame(width: 92, alignment: .leading)
                    Text(trigger.steps.map(\.label).joined(separator: " → "))
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    Spacer()
                    Text(WindowFormat.hm(moment.seconds)).font(.system(size: 12)).monospacedDigit()
                    Button(moment.isRuledOut ? String(localized: "Undo") : String(localized: "Not a distraction")) {
                        ruleOut(moment)
                    }
                    .controlSize(.small)
                }
                .opacity(moment.isRuledOut ? 0.55 : 1)
            }
            if trigger.isWait {
                Label(String(localized: "Next time you open \(trigger.steps.last?.label ?? "it") while \(trigger.steps.first?.label ?? "it") works, FocusGuard will warn you what it cost here.",
                             comment: "Analyzer: what FocusGuard now does about a wait trigger; the site, then the tool"),
                      systemImage: "sparkles")
                    .font(.system(size: 12)).foregroundStyle(Theme.primaryText)
                    .padding(.top, 2)
                if canTest, let tool = trigger.steps.first?.label, let site = trigger.steps.last?.label {
                    let minutes = AnalyzerTriggers.holdMinutes
                    Button(String(localized: "Test holding \(site) for \(minutes) min while \(tool) works",
                                  comment: "Analyzer button: start a test. The site, minutes, then the tool")) {
                        test(AnalyzerFix(cause: .habit, change: .holdInWait(tool: tool, site: site, seconds: minutes * 60),
                                         measure: .longestStretch))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            if trigger.moments.contains(where: \.isRuledOut) {
                Text(String(localized: "Ruled-out moments don’t count here.", comment: "Analyzer: after the user said a moment wasn't a distraction"))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.top, 2)
    }
}

/// "Codex → x.com" as chips: the tool or app, then where it went.
struct AnalyzerTriggerChain: View {
    let steps: [AnalyzerTrigger.Step]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 { Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondaryText) }
                Text(step.kind == .wait ? String(localized: "Waiting on \(step.label)", comment: "Analyzer chip: a tool that was working") : step.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(index == steps.count - 1 ? Theme.distractionTint : Theme.focusTint))
                    .foregroundStyle(index == steps.count - 1 ? Theme.distractionInk : Theme.primaryText)
            }
        }
    }
}

/// Times a day as small bars, oldest first.
struct AnalyzerTriggerBars: View {
    let perDay: [Int]

    var body: some View {
        let most = max(1, perDay.max() ?? 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(perDay.suffix(14).enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(value > 0 ? Theme.distraction : Theme.gridFuture)
                    .frame(width: 4, height: max(2, CGFloat(value) / CGFloat(most) * 20))
            }
        }
        .frame(height: 20, alignment: .bottom)
    }
}

// MARK: - Waits, by project

/// What waits on a tool turned into this week, a project at a time.
struct AnalyzerWaitsSummary: Equatable {
    struct Project: Equatable, Identifiable {
        let name: String
        var waits = 0
        var drifted = 0
        var driftSeconds: TimeInterval = 0
        var id: String { name }
        var stayed: Int { waits - drifted }
    }

    var projects: [Project] = []
    var waits = 0
    var drifted = 0
    var averageWait: TimeInterval = 0
    var averageDrift: TimeInterval = 0
    /// The tool whose waits end on a distraction most often, with its count.
    var pullsAway: (tool: String, drifted: Int, of: Int)?

    static func == (a: AnalyzerWaitsSummary, b: AnalyzerWaitsSummary) -> Bool {
        a.projects == b.projects && a.waits == b.waits && a.drifted == b.drifted && a.pullsAway?.tool == b.pullsAway?.tool
    }

    static func make(_ records: [WaitRecord]) -> AnalyzerWaitsSummary {
        var summary = AnalyzerWaitsSummary()
        guard !records.isEmpty else { return summary }
        var byProject: [String: Project] = [:]
        let other = String(localized: "Other", comment: "Analyzer: waits with no project")
        for record in records {
            let name = record.project ?? other
            var project = byProject[name] ?? Project(name: name)
            project.waits += 1
            if record.drifted {
                project.drifted += 1
                project.driftSeconds += record.drift
            }
            byProject[name] = project
        }
        summary.projects = byProject.values.sorted { $0.waits != $1.waits ? $0.waits > $1.waits : $0.name < $1.name }
        summary.waits = records.count
        let drifts = records.filter(\.drifted)
        summary.drifted = drifts.count
        let stayed = records.filter { !$0.drifted }
        let stayedSeconds: TimeInterval = stayed.reduce(0) { $0 + $1.seconds }
        let driftSeconds: TimeInterval = drifts.reduce(0) { $0 + $1.drift }
        summary.averageWait = stayed.isEmpty ? 0 : stayedSeconds / Double(stayed.count)
        summary.averageDrift = drifts.isEmpty ? 0 : driftSeconds / Double(drifts.count)
        var tools: [(tool: String, drifted: Int, of: Int)] = []
        for (tool, list) in Dictionary(grouping: records, by: \.tool) where list.count >= 3 {
            let drifted = list.filter(\.drifted).count
            if drifted > 0 { tools.append((tool, drifted, list.count)) }
        }
        func share(_ item: (tool: String, drifted: Int, of: Int)) -> Double { Double(item.drifted) / Double(item.of) }
        summary.pullsAway = tools.max { share($0) != share($1) ? share($0) < share($1) : $0.tool > $1.tool }
        return summary
    }
}

/// "While your tools work": stayed with it, or drifted, by project.
struct AnalyzerWaitsCard: View {
    let summary: AnalyzerWaitsSummary

    var body: some View {
        AnalyzerCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: "While your tools work", comment: "Analyzer card: waits on an AI agent, a chat or a build"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(String(localized: "Last 7 days", comment: "Analyzer card subtitle"))
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                Text(headline).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                ForEach(summary.projects.prefix(4)) { project in
                    projectRow(project)
                }
                HStack(spacing: 14) {
                    legend(Theme.focus, String(localized: "Stayed with it"))
                    legend(Theme.distraction, String(localized: "Drifted"))
                }
                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var headline: String {
        let stayed = summary.waits - summary.drifted
        var text = String(localized: "You stayed with \(stayed) of \(summary.waits) waits.", comment: "Analyzer: waits stayed with, of all waits")
        if summary.drifted > 0, summary.averageWait > 0 {
            text += " " + String(localized: "A wait takes about \(WindowFormat.hm(summary.averageWait)); a drift lasts \(WindowFormat.hm(summary.averageDrift)).",
                                 comment: "Analyzer: the usual wait, then the usual drift")
        }
        if let pulls = summary.pullsAway {
            text += " " + String(localized: "You drift most while \(pulls.tool) works: \(pulls.drifted) of \(pulls.of) waits.",
                                 comment: "Analyzer: the tool, then drifted waits of all its waits")
        }
        return text
    }

    private func projectRow(_ project: AnalyzerWaitsSummary.Project) -> some View {
        HStack(spacing: 10) {
            Text(project.name).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: 110, alignment: .leading)
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    if project.stayed > 0 {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.focus)
                            .frame(width: max(4, proxy.size.width * CGFloat(project.stayed) / CGFloat(max(1, project.waits)) - 1))
                    }
                    if project.drifted > 0 {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.distraction)
                    }
                }
            }
            .frame(height: 12)
            Text(String(localized: "\(project.stayed) stayed · \(project.drifted) drifted", comment: "Analyzer: waits stayed with, then drifted"))
                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText).monospacedDigit()
                .frame(minWidth: 120, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label)
        }
    }
}
