import Foundation

/// How waits are told apart from everything else.
enum WaitRules {
    /// Time in the tool before leaving it: passing through doesn't count.
    static let shortestInTool: TimeInterval = 5
    /// Reaching for a distraction this soon after leaving the tool is
    /// reaching for it in the wait.
    static let reachWithin: TimeInterval = 90
    /// Back in the tool after less than this: just a look elsewhere.
    static let shortestWait: TimeInterval = 10
    /// Away from the tool longer than this: not a wait any more.
    static let longestWait: TimeInterval = 30 * 60
    /// What a tool's wait is taken to be until there are waits of its own to go by.
    static let usualWait: TimeInterval = 90
    static let usualWaitRange: ClosedRange<TimeInterval> = 20...(10 * 60)
    /// Waits of its own needed before a tool's usual wait is its own.
    static let enoughWaits = 3
    /// One wait card, then none for this long.
    static let gapBetweenCards: TimeInterval = 10 * 60
    /// Wait cards closed this many times in a row, without going back…
    static let ignoredInARow = 2
    /// …and there are none for this long.
    static let quietAfterIgnored: TimeInterval = 60 * 60
    /// A project seen this long ago is no longer the one being worked on.
    static let projectGoesStale: TimeInterval = 20 * 60
}

/// What the watcher goes by, read at each of the tracker's looks.
struct WaitMoment {
    var now: Date
    var front: ActivitySnapshot?
    var frontIsSelf = false
    /// Nobody's at the Mac, or it's asleep or locked.
    var isAway = false
    var inCall = false
    /// The block, daily-limit or break screen is up, or a break is on.
    var screenUp = false
}

/// The user left a tool and went for a distraction while it worked.
struct WaitReach: Equatable {
    let tool: WaitTool
    let project: String?
    /// When they left the tool: the wait's start.
    let since: Date
    /// The site or app they went to: "x.com".
    let to: String
}

/// One wait, once it's over: what it turned into.
struct WaitRecord: Codable, Equatable, Sendable {
    let start: Date
    let tool: String
    var project: String?
    /// How long until the user was back in the tool.
    let seconds: TimeInterval
    /// Of that, on distractions. Zero: they stayed with the work.
    let drift: TimeInterval
    /// Where the drift went: "x.com".
    var to: String?
    /// The tool said when it finished, rather than being timed from the user.
    var exact = false
    /// How long the tool worked, when it said: from the prompt to its answer.
    var worked: TimeInterval?

    var drifted: Bool { drift > 0 }
}

enum WaitEvent: Equatable {
    /// They reached for a distraction during the wait.
    case reached(WaitReach)
    /// The tool said it finished while they were away on a distraction, or
    /// that it needs their answer (`needsInput`).
    case done(WaitReach, project: String?, needsInput: Bool)
    /// The wait's over: back in the tool, or gone too long.
    case ended(WaitRecord, back: Bool)
}

/// Notices waits: the user was in a tool that was working, left it, and
/// came back (a wait, stayed or drifted) or didn't for a long time.
///
/// A wait only counts when there's a reason to think the tool was working:
/// - it said so itself (Claude Code's hook, Codex, `fgwait`), and hasn't said
///   it's done. Its app, whatever it is (the Claude app, a terminal), is then
///   where it lives, and is never guessed at again;
/// - or a terminal's title shows something running: an agent or a command.
/// Chats and editors give no such sign, so leaving them isn't a wait.
/// Nothing that was typed is ever read.
struct WaitWatcher: Equatable {
    private struct Open: Equatable {
        let tool: WaitTool
        var project: String?
        let left: Date
        /// The tool said it was working when the user left it.
        let exact: Bool
        var drift: TimeInterval = 0
        var driftSince: Date?
        var to: String?
        var reach: WaitReach?
        var doneSent = false
        /// The tool said it finished.
        var finishedAt: Date?
        var workedSince: Date?
    }

    /// A tool that said it started and hasn't said it's done.
    private struct Run: Equatable {
        let tool: String
        let bundleId: String
        let project: String?
        let since: Date
    }

    /// By tool and project: several sessions can run at once.
    private var running: [String: Run] = [:]
    /// Apps a tool has reported from. Their waits come from the tool, never a guess.
    private(set) var hooked: Set<String> = []
    /// The tool in front, and since when.
    private var inTool: (tool: WaitTool, project: String?, since: Date, exact: Bool)?
    private var open: Open?
    private var lastProject: (name: String, at: Date)?

    static func == (a: WaitWatcher, b: WaitWatcher) -> Bool {
        a.open == b.open && a.running == b.running && a.hooked == b.hooked
            && a.inTool?.tool == b.inTool?.tool && a.inTool?.since == b.inTool?.since
    }

    /// A wait is going: the user left a working tool and hasn't come back yet.
    var isWaiting: Bool { open != nil }

    private static func key(_ tool: String, _ project: String?) -> String { "\(tool)|\(project ?? "")" }

    mutating func observe(_ moment: WaitMoment) -> [WaitEvent] {
        // A start with no finish: the tool went quiet, or its hook was taken out.
        running = running.filter { moment.now.timeIntervalSince($0.value.since) < WaitRules.longestWait }
        // Away, asleep, a call or a block screen: whatever wait there was is over.
        if moment.isAway || moment.inCall || moment.screenUp {
            inTool = nil
            return close(at: moment.now, back: false).map { [$0] } ?? []
        }
        // FocusGuard's own window says nothing either way.
        guard !moment.frontIsSelf, let front = moment.front else { return [] }
        var events: [WaitEvent] = []

        if let open, front.bundleIdentifier == open.tool.bundleId, open.tool.host == nil || WaitTools.host(of: front.url) == open.tool.host {
            // Back where the tool lives: the wait is over.
            let seconds = moment.now.timeIntervalSince(open.left)
            if seconds >= WaitRules.shortestWait, let ended = close(at: moment.now, back: true) { events.append(ended) }
            self.open = nil
        }

        if let found = working(in: front, at: moment.now) {
            let (tool, project, exact) = found
            if let ended = close(at: moment.now, back: false) { events.append(ended) }
            if inTool == nil || inTool?.tool.isSame(as: tool) == false || inTool?.exact != exact {
                inTool = (tool, project, moment.now, exact)
            }
            return events
        }

        // Just left a tool that was working, after long enough in it: a wait begins.
        if let was = inTool {
            inTool = nil
            if moment.now.timeIntervalSince(was.since) >= WaitRules.shortestInTool, !isSameApp(front, was.tool) {
                if let ended = close(at: moment.now, back: false) { events.append(ended) }
                let since = was.exact ? running.values.filter { $0.tool == was.tool.name }.map(\.since).max() : nil
                open = Open(tool: was.tool, project: was.project, left: moment.now, exact: was.exact, workedSince: since)
            }
        }
        guard var current = open else { return events }
        let elapsed = moment.now.timeIntervalSince(current.left)
        if elapsed > WaitRules.longestWait {
            if let ended = close(at: moment.now, back: false) { events.append(ended) }
            return events
        }

        let drifting = front.classification == .distraction && !front.isPrivateWindow
        if drifting {
            if current.driftSince == nil { current.driftSince = front.observedAt < current.left ? current.left : front.observedAt }
            current.to = Self.name(of: front)
            // A tool that already finished isn't being waited on.
            if current.reach == nil, current.finishedAt == nil, elapsed <= WaitRules.reachWithin {
                let reach = WaitReach(tool: current.tool, project: current.project, since: current.left, to: current.to ?? front.appName)
                current.reach = reach
                events.append(.reached(reach))
            }
        } else if let since = current.driftSince {
            current.drift += moment.now.timeIntervalSince(since)
            current.driftSince = nil
        }
        open = current
        return events
    }

    /// The tool in front, when there's a reason to think it's working: its
    /// own word, or a terminal's title. Its project, and whether it said so.
    private mutating func working(in front: ActivitySnapshot, at now: Date) -> (WaitTool, String?, Bool)? {
        let id = front.bundleIdentifier
        if let run = running.values.filter({ $0.bundleId == id }).max(by: { $0.since < $1.since }) {
            return (WaitTool(name: run.tool, kind: .agent, bundleId: id), run.project, true)
        }
        // A tool reports from here: when it isn't running, nothing is.
        guard !hooked.contains(id), let tool = WaitTools.tool(for: front), tool.kind == .agent || tool.kind == .command else { return nil }
        let project = WaitTools.project(for: front, tool: tool)
        if let project { lastProject = (project, now) }
        let recent = lastProject.flatMap { now.timeIntervalSince($0.at) < WaitRules.projectGoesStale ? $0.name : nil }
        return (tool, project ?? recent, false)
    }

    private func isSameApp(_ front: ActivitySnapshot, _ tool: WaitTool) -> Bool {
        front.bundleIdentifier == tool.bundleId && (tool.host == nil || WaitTools.host(of: front.url) == tool.host)
    }

    /// The wait in progress, ended now. Nil when there's none, or it was too
    /// short to be one.
    private mutating func close(at now: Date, back: Bool) -> WaitEvent? {
        guard let current = open else { return nil }
        open = nil
        var drift = current.drift
        if let since = current.driftSince { drift += now.timeIntervalSince(since) }
        let seconds = min(now.timeIntervalSince(current.left), WaitRules.longestWait)
        guard seconds >= WaitRules.shortestWait, back || drift > 0 else { return nil }
        var record = WaitRecord(start: current.left, tool: current.tool.name, project: current.project,
                                seconds: seconds, drift: min(drift, seconds), to: current.to)
        record.exact = current.exact
        if let finished = current.finishedAt, let since = current.workedSince { record.worked = finished.timeIntervalSince(since) }
        return .ended(record, back: back)
    }

    // MARK: - From the tool itself

    /// A tool said it started (Claude Code's prompt, a script's `fgwait`).
    /// The app in front is where it runs, whatever that app is.
    mutating func started(tool name: String, project: String?, front: ActivitySnapshot?, at now: Date) {
        guard let id = front?.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
        running[Self.key(name, project)] = Run(tool: name, bundleId: id, project: project, since: now)
        hooked.insert(id)
        if let project { lastProject = (project, now) }
        // Asked just now, from the app in front: it's been in the tool long enough.
        inTool = (WaitTool(name: name, kind: .agent, bundleId: id), project, now.addingTimeInterval(-WaitRules.shortestInTool), true)
    }

    /// A tool said it finished, or that it needs the user's answer. Mid-wait
    /// and away on a distraction: the card says so, for certain.
    mutating func finished(tool name: String, project: String?, needsInput: Bool, at now: Date) -> [WaitEvent] {
        if let project {
            running[Self.key(name, project)] = nil
        } else {
            running = running.filter { $0.value.tool != name }
        }
        guard var current = open, current.tool.name == name, current.finishedAt == nil else { return [] }
        // Other sessions of the same tool still running: the wait goes on.
        if !needsInput, running.values.contains(where: { $0.tool == name && $0.bundleId == current.tool.bundleId }) { return [] }
        current.finishedAt = now
        var events: [WaitEvent] = []
        if current.driftSince != nil, let reach = current.reach, !current.doneSent {
            current.doneSent = true
            events.append(.done(reach, project: project ?? current.project, needsInput: needsInput))
        }
        open = current
        return events
    }

    static func name(of front: ActivitySnapshot) -> String {
        WaitTools.host(of: front.url) ?? front.appName
    }
}
