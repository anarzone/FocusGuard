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
struct WaitRecord: Codable, Equatable {
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

    var drifted: Bool { drift > 0 }
}

enum WaitEvent: Equatable {
    /// They reached for a distraction during the wait.
    case reached(WaitReach)
    /// Still on it when the tool's usual wait is up.
    case probablyDone(WaitReach)
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
    }

    /// The tool in front, and since when.
    private var inTool: (tool: WaitTool, project: String?, since: Date)?
    private var open: Open?

    static func == (a: WaitWatcher, b: WaitWatcher) -> Bool {
        a.open == b.open && a.inTool?.tool == b.inTool?.tool && a.inTool?.since == b.inTool?.since
    }

    /// The project last seen in a tool, for a chat that has none.
    private(set) var lastProject: String?

    /// A wait is going: the user left a tool and hasn't come back yet.
    var isWaiting: Bool { open != nil }

    mutating func observe(_ moment: WaitMoment, usualWait: (WaitTool) -> TimeInterval) -> [WaitEvent] {
        // Away, asleep, a call or a block screen: whatever wait there was is over.
        if moment.isAway || moment.inCall || moment.screenUp {
            inTool = nil
            return close(at: moment.now, back: false).map { [$0] } ?? []
        }
        // FocusGuard's own window says nothing either way.
        guard !moment.frontIsSelf, let front = moment.front else { return [] }
        var events: [WaitEvent] = []
        let tool = WaitTools.tool(for: front)

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
        if drifting, let reach = current.reach, !current.doneSent, elapsed >= usualWait(current.tool) {
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
        let record = WaitRecord(start: current.left, tool: current.tool.name, project: current.project,
                                seconds: seconds, drift: min(current.drift, seconds), to: current.to)
        return .ended(record, back: back)
    }

    static func name(of front: ActivitySnapshot) -> String {
        WaitTools.host(of: front.url) ?? front.appName
    }
}
