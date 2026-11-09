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
    /// A tool's usual wait is never taken to be shorter or longer than this.
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
    /// A tool that said it started is taken to be working for this long with
    /// no finish, unless its own past runs on the project went on longer…
    static let believedWorking: TimeInterval = 30 * 60
    /// …then for that much longer than its longest, up to `longestBelieved`.
    static let believedMargin = 1.5
    static let longestBelieved: TimeInterval = 4 * 60 * 60
    /// A start is kept this long so a late finish still tells how long the run took.
    static let forgetRunAfter: TimeInterval = 12 * 60 * 60
    /// Runs of its own needed before a tool's times are gone by.
    static let enoughRuns = 3
    /// The latest runs that count: how a tool works now, not last month.
    static let recentRuns = 30
    /// Past this share of its past runs, a run has gone on "longer than most".
    static let longRunShare = 0.8
    /// The clock moved this much further than the Mac was awake: it slept mid-run.
    static let sleptThrough: TimeInterval = 60
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
    /// When the tool said it started on what's being waited for.
    var runStarted: Date?
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

/// One run of a tool, from its start to its finish, both said by the tool
/// itself: how long it really worked, whether the user waited or not.
struct RunRecord: Codable, Equatable, Sendable {
    let start: Date
    let tool: String
    var project: String?
    let seconds: TimeInterval
    /// It stopped to ask the user something, rather than finishing.
    var asked = false
}

enum WaitEvent: Equatable {
    /// A tool finished a run it had said it started.
    case ran(RunRecord)
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
///   it's done. Its app (the Claude app, a terminal) is then where it lives,
///   and is never guessed at again;
/// - or a terminal's title shows something running: an agent or a command.
/// Chats and editors give no such sign, so leaving them isn't a wait.
///
/// Every run a tool starts and finishes by its own word is timed, whether
/// the user waited on it or not: that's how long the tool really works.
/// Nothing that was typed is ever read.
struct WaitWatcher: Equatable {
    private struct Open: Equatable {
        let tool: WaitTool
        var project: String?
        let left: Date
        /// The tool said it was working when the user left it.
        let exact: Bool
        /// The run being waited on, when the tool said it started.
        var run: String?
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
        /// The app it runs in. Nil when it started with some other app in
        /// front (a prompt sent from a phone, a session another one started):
        /// its time still counts, but leaving that app is no wait.
        let bundleId: String?
        let project: String?
        let session: String?
        let since: Date
        /// With no word that it's done, it's taken to be working this long.
        let believedFor: TimeInterval
        /// The Mac's time awake when it started: a run it slept through isn't timed.
        let uptime: TimeInterval?

        func isLive(at now: Date) -> Bool { now.timeIntervalSince(since) < believedFor }
    }

    /// The tool in front, and since when.
    private struct InTool: Equatable {
        var tool: WaitTool
        var project: String?
        var since: Date
        var exact: Bool
        var run: String?
    }

    /// By session, or by tool and project when the tool names none: several can run at once.
    private var running: [String: Run] = [:]
    /// Apps a tool has reported from. Their waits come from the tool, never a guess.
    private(set) var hooked: Set<String> = []
    /// The app each session was first seen in: its later prompts may be sent
    /// with something else in front (queued, or from a phone).
    private var sessionHomes: [String: String] = [:]
    private var inTool: InTool?
    private var open: Open?
    private var lastProject: (name: String, at: Date)?

    static func == (a: WaitWatcher, b: WaitWatcher) -> Bool {
        a.open == b.open && a.running == b.running && a.hooked == b.hooked && a.inTool == b.inTool
    }

    /// A wait is going: the user left a working tool and hasn't come back yet.
    var isWaiting: Bool { open != nil }
    /// Runs that started and haven't finished, for the tests.
    var runCount: Int { running.count }

    private static func key(_ tool: String, _ project: String?) -> String { "\(tool)|\(project ?? "")" }
    private static func key(_ tool: String, session: String) -> String { "\(tool)#\(session)" }

    mutating func observe(_ moment: WaitMoment) -> [WaitEvent] {
        // A start with no finish for half a day: the tool was closed, or its hook taken out.
        running = running.filter { moment.now.timeIntervalSince($0.value.since) < WaitRules.forgetRunAfter }
        // Away, asleep, a call or a block screen: whatever wait there was is over.
        if moment.isAway || moment.inCall || moment.screenUp {
            inTool = nil
            return close(at: moment.now, back: false).map { [$0] } ?? []
        }
        // FocusGuard's own window says nothing either way.
        guard !moment.frontIsSelf, let front = moment.front else { return [] }
        var events: [WaitEvent] = []

        if let open, isSameApp(front, open.tool) {
            // Back where the tool lives: the wait is over.
            let seconds = moment.now.timeIntervalSince(open.left)
            if seconds >= WaitRules.shortestWait, let ended = close(at: moment.now, back: true) { events.append(ended) }
            self.open = nil
        }

        if let found = working(in: front, at: moment.now) {
            if let ended = close(at: moment.now, back: false) { events.append(ended) }
            if let current = inTool, current.tool.isSame(as: found.tool), current.exact == found.exact {
                // Still in it: the run in front may be another session's by now.
                inTool?.project = found.project
                inTool?.run = found.run
            } else {
                inTool = found
            }
            return events
        }

        // Just left a tool that was working, after long enough in it: a wait begins.
        if let was = inTool {
            inTool = nil
            if moment.now.timeIntervalSince(was.since) >= WaitRules.shortestInTool, !isSameApp(front, was.tool) {
                if let ended = close(at: moment.now, back: false) { events.append(ended) }
                if !was.exact {
                    open = Open(tool: was.tool, project: was.project, left: moment.now, exact: false)
                } else if let key = was.run, let run = running[key], run.isLive(at: moment.now) {
                    // Its own word that it's working, and none yet that it's done.
                    open = Open(tool: was.tool, project: was.project, left: moment.now, exact: true, run: key, workedSince: run.since)
                }
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
                var reach = WaitReach(tool: current.tool, project: current.project, since: current.left, to: current.to ?? front.appName)
                reach.runStarted = current.workedSince
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
    /// own word, or a terminal's title.
    private mutating func working(in front: ActivitySnapshot, at now: Date) -> InTool? {
        let id = front.bundleIdentifier
        // The run asked for last is the one being looked at.
        let here = running.filter { $0.value.bundleId == id && $0.value.isLive(at: now) }
        if let (key, run) = here.max(by: { $0.value.since < $1.value.since }) {
            return InTool(tool: WaitTool(name: run.tool, kind: .agent, bundleId: id), project: run.project, since: now, exact: true, run: key)
        }
        // A tool reports from here: when it isn't running, nothing is.
        guard !hooked.contains(id), let tool = WaitTools.tool(for: front), tool.kind == .agent || tool.kind == .command else { return nil }
        let project = WaitTools.project(for: front, tool: tool)
        if let project { lastProject = (project, now) }
        let recent = lastProject.flatMap { now.timeIntervalSince($0.at) < WaitRules.projectGoesStale ? $0.name : nil }
        return InTool(tool: tool, project: project ?? recent, since: now, exact: false)
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

    /// Whether the app in front can be where the tool runs: a terminal, an
    /// editor or the tool's own app, or a window whose title names the tool
    /// or the project. Never a browser or a distraction: a prompt sent from
    /// elsewhere mustn't make x.com the tool's home.
    static func canHost(_ front: ActivitySnapshot, tool: String, project: String?) -> Bool {
        let id = front.bundleIdentifier
        guard id != Bundle.main.bundleIdentifier, front.classification != .distraction,
              !BrowserTabReader.isBrowser(bundleIdentifier: id) else { return false }
        if WaitTools.isToolApp(id) { return true }
        guard !front.isPrivateWindow, let title = front.windowTitle?.lowercased(), !title.isEmpty else { return false }
        if let project = project?.lowercased(), project.count >= 3, title.contains(project) { return true }
        return WaitTools.agent(inTitle: title) == tool
    }

    /// A tool said it started (Claude Code's prompt, a script's `fgwait`).
    /// Its home is the app its session was first seen in, or the one in
    /// front now when that can be where it runs. False when it has none.
    @discardableResult
    mutating func started(tool name: String, project: String?, session: String? = nil, front: ActivitySnapshot?,
                          believeFor: TimeInterval = WaitRules.believedWorking, uptime: TimeInterval? = nil, at now: Date) -> Bool {
        let key = session.map { Self.key(name, session: $0) } ?? Self.key(name, project)
        let home = sessionHomes[key] ?? front.flatMap { Self.canHost($0, tool: name, project: project) ? $0.bundleIdentifier : nil }
        running[key] = Run(tool: name, bundleId: home, project: project, session: session, since: now,
                           believedFor: believeFor, uptime: uptime)
        guard let home else { return false }
        hooked.insert(home)
        if session != nil {
            if sessionHomes.count > 500 { sessionHomes.removeAll() }
            sessionHomes[key] = home
        }
        guard front?.bundleIdentifier == home else { return true }
        if let project { lastProject = (project, now) }
        // Asked just now, from the app in front: it's been in the tool long enough.
        inTool = InTool(tool: WaitTool(name: name, kind: .agent, bundleId: home), project: project,
                        since: now.addingTimeInterval(-WaitRules.shortestInTool), exact: true, run: key)
        return true
    }

    /// The runs a tool's word that it's done is about: its session's, or the
    /// one on that project when the start named no session.
    private func ending(tool name: String, project: String?, session: String?) -> [String] {
        if let session {
            let key = Self.key(name, session: session)
            if running[key] != nil { return [key] }
        }
        if session != nil || project != nil {
            let key = Self.key(name, project)
            return running[key] != nil ? [key] : []
        }
        // Neither said: every run of the tool that named no session.
        return running.filter { $0.value.session == nil && $0.value.tool == name }.map(\.key)
    }

    /// A tool said it finished, or that it needs the user's answer. Mid-wait
    /// and away on a distraction: the card says so, for certain.
    /// - Parameter quiet: it went idle or was closed, rather than finishing:
    ///   the run is over, with nothing to time and nothing to say.
    mutating func finished(tool name: String, project: String?, session: String? = nil, needsInput: Bool, quiet: Bool = false,
                           uptime: TimeInterval? = nil, at now: Date) -> [WaitEvent] {
        let keys = ending(tool: name, project: project, session: session)
        let ended = keys.compactMap { running[$0] }
        for key in keys { running[key] = nil }
        var events: [WaitEvent] = []
        if !quiet, ended.count == 1, let record = Self.record(of: ended[0], project: project, asked: needsInput, uptime: uptime, at: now) {
            events.append(.ran(record))
        }

        guard var current = open, current.tool.name == name else { return events }
        let waitedOn = current.run.map(keys.contains) ?? false
        if waitedOn || !current.exact {
            // The run waited on, or a wait guessed from a title, which the tool's word settles.
            guard current.finishedAt == nil else { return events }
            current.finishedAt = now
            // Gone idle or closed: when it stopped working isn't known.
            if quiet { current.workedSince = nil }
        } else if !needsInput || !ended.contains(where: { $0.bundleId == current.tool.bundleId }) {
            // Another session's: the one waited on is still working. Unless it
            // asks for an answer in the same app, which is worth going back for.
            return events
        }
        if !quiet, current.driftSince != nil, let reach = current.reach, !current.doneSent {
            current.doneSent = true
            events.append(.done(reach, project: project ?? ended.first?.project ?? current.project, needsInput: needsInput))
        }
        open = current
        return events
    }

    /// How long a run took, from its start to its finish. Nil when it can't
    /// be told: over in a moment, or the Mac slept through part of it.
    private static func record(of run: Run, project: String?, asked: Bool, uptime: TimeInterval?, at now: Date) -> RunRecord? {
        let seconds = now.timeIntervalSince(run.since)
        guard seconds >= 1 else { return nil }
        if let began = run.uptime, let uptime, seconds - (uptime - began) > WaitRules.sleptThrough { return nil }
        var record = RunRecord(start: run.since, tool: run.tool, project: run.project ?? project, seconds: seconds)
        record.asked = asked
        return record
    }

    static func name(of front: ActivitySnapshot) -> String {
        WaitTools.host(of: front.url) ?? front.appName
    }
}
