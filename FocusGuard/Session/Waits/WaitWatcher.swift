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
    static let gapBetweenCards: TimeInterval = 3 * 60
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
    /// Still on it when the tool's usual wait is up, or when the tool said
    /// it finished (`exact`).
    case probablyDone(WaitReach, exact: Bool = false)
    /// The wait's over: back in the tool, or gone too long.
    case ended(WaitRecord, back: Bool)
}

/// Notices waits from what's in front: the user was in a tool, left it, and
/// either came back (a wait, stayed or drifted) or didn't for a long time.
/// Learned from behaviour alone, so it works for any tool and never reads
/// what was typed.
struct WaitWatcher: Equatable {
    private struct Open: Equatable {
        let tool: WaitTool
        var project: String?
        let left: Date
        var drift: TimeInterval = 0
        var driftSince: Date?
        var to: String?
        var reach: WaitReach?
        var doneSent = false
        /// The tool said it finished.
        var finishedAt: Date?
    }

    /// Tools that said they started and haven't said they're done: their
    /// name, the app they're in, the project, and when.
    private var running: [String: (bundleId: String?, project: String?, since: Date)] = [:]

    /// The tool in front, and since when.
    private var inTool: (tool: WaitTool, project: String?, since: Date)?
    private var open: Open?

    static func == (a: WaitWatcher, b: WaitWatcher) -> Bool {
        a.open == b.open && a.inTool?.tool == b.inTool?.tool && a.inTool?.since == b.inTool?.since
            && a.running.keys == b.running.keys
    }

    /// The project last seen in a tool, for a chat that has none.
    private(set) var lastProject: String?

    /// A wait is going: the user left a tool and hasn't come back yet.
    var isWaiting: Bool { open != nil }

    mutating func observe(_ moment: WaitMoment, usualWait: (WaitTool) -> TimeInterval) -> [WaitEvent] {
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
        let tool = WaitTools.tool(for: front) ?? runningTool(in: front) ?? openTool(in: front)

        if let tool {
            let project = WaitTools.project(for: front, tool: tool)
            if let project { lastProject = project }
            if let open, open.tool.isSame(as: tool) {
                let seconds = moment.now.timeIntervalSince(open.left)
                if seconds >= WaitRules.shortestWait, let ended = close(at: moment.now, back: true) { events.append(ended) }
                self.open = nil
            } else if let ended = close(at: moment.now, back: false) {
                events.append(ended)
            }
            if inTool == nil || inTool?.tool.isSame(as: tool) == false {
                inTool = (tool, project ?? (tool.kind == .chat ? lastProject : nil), moment.now)
            }
            return events
        }

        // Just left a tool it had been in long enough: a wait may have begun.
        if let was = inTool {
            inTool = nil
            if moment.now.timeIntervalSince(was.since) >= WaitRules.shortestInTool {
                if let ended = close(at: moment.now, back: false) { events.append(ended) }
                open = Open(tool: was.tool, project: was.project ?? lastProject, left: moment.now)
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
            if current.reach == nil, elapsed <= WaitRules.reachWithin {
                let reach = WaitReach(tool: current.tool, project: current.project, since: current.left, to: current.to ?? front.appName)
                current.reach = reach
                events.append(.reached(reach))
            }
        } else if let since = current.driftSince {
            current.drift += moment.now.timeIntervalSince(since)
            current.driftSince = nil
        }
        // A tool that says when it's done isn't guessed at.
        let guessed = running[current.tool.name] == nil && current.finishedAt == nil
        if drifting, let reach = current.reach, !current.doneSent, guessed, elapsed >= usualWait(current.tool) {
            current.doneSent = true
            events.append(.probablyDone(reach))
        }
        open = current
        return events
    }

    /// The wait in progress, ended now. Nil when there's none, or it was too
    /// short to be one.
    private mutating func close(at now: Date, back: Bool) -> WaitEvent? {
        guard var current = open else { return nil }
        open = nil
        if let since = current.driftSince { current.drift += now.timeIntervalSince(since) }
        let seconds = min(now.timeIntervalSince(current.left), WaitRules.longestWait)
        guard seconds >= WaitRules.shortestWait, back || current.drift > 0 else { return nil }
        var record = WaitRecord(start: current.left, tool: current.tool.name, project: current.project,
                                seconds: seconds, drift: min(current.drift, seconds), to: current.to)
        if let finished = current.finishedAt {
            record.exact = true
            record.worked = workedSince.map { finished.timeIntervalSince($0) }
        }
        workedSince = nil
        return .ended(record, back: back)
    }

    // MARK: - Exact, from the tool itself

    /// When the tool in the wait last said it started.
    private var workedSince: Date?

    /// A tool said it started (Claude Code's prompt, a script's `fgwait`):
    /// the app in front is where it runs, whatever its window is called.
    mutating func started(tool name: String, project: String?, front: ActivitySnapshot?, at now: Date) {
        let bundleId = front.flatMap { $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0.bundleIdentifier }
        running[name] = (bundleId, project, now)
        if let project { lastProject = project }
        // Asked just now, from the app in front: that's the tool, long enough.
        if let bundleId, front.map({ WaitTools.tool(for: $0) == nil }) ?? false {
            inTool = (WaitTool(name: name, kind: .agent, bundleId: bundleId), project, now.addingTimeInterval(-WaitRules.shortestInTool))
        }
    }

    /// A tool said it finished. Mid-wait and away on a distraction: the
    /// card can say so for certain. Still at the tool: nothing to say.
    mutating func finished(tool name: String, at now: Date) -> [WaitEvent] {
        let since = running.removeValue(forKey: name)?.since
        guard var current = open, current.tool.name == name, current.finishedAt == nil else { return [] }
        current.finishedAt = now
        workedSince = since
        var events: [WaitEvent] = []
        if current.driftSince != nil, let reach = current.reach, !current.doneSent {
            current.doneSent = true
            events.append(.probablyDone(reach, exact: true))
        }
        open = current
        return events
    }

    /// Back in the app the wait's tool lives in, when its window can't say
    /// so: a tool that told FocusGuard it started, and has since finished.
    private func openTool(in front: ActivitySnapshot) -> WaitTool? {
        guard let tool = open?.tool, tool.bundleId == front.bundleIdentifier, tool.host == nil else { return nil }
        return tool
    }

    /// The front app is where a tool said it's running, though its window
    /// doesn't say so.
    private func runningTool(in front: ActivitySnapshot) -> WaitTool? {
        guard let match = running.first(where: { $0.value.bundleId == front.bundleIdentifier }),
              let bundleId = match.value.bundleId else { return nil }
        return WaitTool(name: match.key, kind: .agent, bundleId: bundleId)
    }

    static func name(of front: ActivitySnapshot) -> String {
        WaitTools.host(of: front.url) ?? front.appName
    }
}
