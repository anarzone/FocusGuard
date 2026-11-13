import Foundation

/// The setting: on until it's switched off.
enum WaitSettings {
    static let enabled = "waits.enabled"

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabled) as? Bool ?? true
    }
}

/// Turns what the watcher notices into the island's card. Reaching for a
/// distraction while a tool works says nothing: most looks away are over
/// before the tool is (the log showed 89 of 107 back in time). The card comes
/// only when the tool's answer is really sitting: a minute after it finished,
/// or half that after it asked a question, with the user still on a
/// distraction. A site under a hold test is still held. Every wait that ends
/// goes in the log, and so does every run a tool times itself.
///
/// It stays quiet when it isn't wanted: at most 3 cards a day, one in ten
/// minutes, and after two closed in a row without going back, none for four hours.
@MainActor
final class WaitCoordinator {
    private var watcher = WaitWatcher()
    private let log: WaitLog
    private let island: IslandController?
    private var timer: Timer?
    private var lastCardAt: Date?
    private var ignoredInARow = 0
    private var quietUntil: Date?
    /// The tool's word that it's done, waiting out the grace before a card.
    private var pendingDone: (reach: WaitReach, project: String?, needsInput: Bool, due: Date)?
    /// Cards shown today, for the daily cap.
    private var cardsToday: (day: Date, count: Int)?
    /// Where cards go. Tests read them here.
    var showCard: ((IslandMoment) -> Void)?
    var calendar = Calendar.current

    /// What's going on now, for the looks between the tracker's.
    var currentMoment: () -> WaitMoment = { WaitMoment(now: .now) }
    /// The open task that fits the project, if any: "CUR-38 Waiter wipes the table".
    var nextTask: (_ project: String?) -> TaskItem? = { _ in nil }
    var isOn: () -> Bool = { WaitSettings.isOn() }
    /// Seconds the site is held when the user leaves this tool for it today
    /// (an Analyzer test or a kept fix), nil when it isn't.
    var holdSeconds: (WaitReach) -> Int? = { _ in nil }
    /// Puts the site's tab on hold until the given time.
    var hold: (WaitReach, Date) -> Void = { _, _ in }
    /// Sites the user said are fine while a tool works, as trigger ids.
    var fine: () -> Set<String> = { [] }
    /// The clock, for the quiet times.
    var now: () -> Date = { .now }
    /// How long the Mac has been awake: it stands still while it sleeps, so
    /// a run the Mac slept through shows.
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    init(log: WaitLog = .shared, island: IslandController?) {
        self.log = log
        self.island = island
    }

    func observe(_ moment: WaitMoment) {
        guard isOn() else {
            stopTimer()
            return
        }
        watcher.fine = fine()
        for event in watcher.observe(moment) {
            handle(event, now: moment.now)
        }
        showDoneIfDue(moment)
        // The tracker may look rarely when nothing's timed: keep an eye on
        // the wait while one is going.
        watcher.isWaiting ? startTimer() : stopTimer()
    }

    /// The user left a tool that's working and isn't back yet.
    var isWaiting: Bool { watcher.isWaiting }

    /// A wait card was answered: going back (true) or closing it (false).
    func answered(wentBack: Bool) {
        if wentBack {
            ignoredInARow = 0
            return
        }
        ignoredInARow += 1
        if ignoredInARow >= WaitRules.ignoredInARow {
            ignoredInARow = 0
            quietUntil = now().addingTimeInterval(WaitRules.quietAfterIgnored)
            DecisionLog.shared.record(.wait, "quieted")
        }
    }

    /// Whether a wait card may show now.
    func mayShowCard(at now: Date) -> Bool {
        if let quietUntil, now < quietUntil { return false }
        if let lastCardAt, now.timeIntervalSince(lastCardAt) < WaitRules.gapBetweenCards { return false }
        if let cardsToday, calendar.isDate(cardsToday.day, inSameDayAs: now), cardsToday.count >= WaitRules.cardsPerDay { return false }
        return true
    }

    private func post(_ card: IslandMoment, at now: Date) {
        lastCardAt = now
        let count = cardsToday.map { calendar.isDate($0.day, inSameDayAs: now) ? $0.count : 0 } ?? 0
        cardsToday = (now, count + 1)
        if let showCard { showCard(card) } else { island?.post(card) }
    }

    /// The grace is over and they're still on a distraction: now it's worth saying.
    private func showDoneIfDue(_ moment: WaitMoment) {
        guard let pending = pendingDone, moment.now >= pending.due else { return }
        pendingDone = nil
        let onDistraction = moment.front.map { $0.classification == .distraction && !$0.isPrivateWindow } ?? false
        guard watcher.isWaiting, onDistraction, !moment.isAway, mayShowCard(at: moment.now) else {
            DecisionLog.shared.record(.wait, "notSaid", detail: pending.reach.tool.kind.rawValue)
            return
        }
        post(.waitDone(pending.reach, project: pending.project, needsInput: pending.needsInput, now: moment.now), at: moment.now)
    }

    private func handle(_ event: WaitEvent, now: Date) {
        switch event {
        case .ran(let run):
            log.add(run)
        case .reached(let reach):
            DecisionLog.shared.record(.wait, "reached", detail: reach.tool.kind.rawValue)
            // A held site is held every time, card or not.
            let held = holdSeconds(reach).map { reach.since.addingTimeInterval(TimeInterval($0)) }.flatMap { $0 > now ? $0 : nil }
            if let held {
                DecisionLog.shared.record(.wait, "held", detail: reach.tool.kind.rawValue)
                hold(reach, held)
            }
            // Only a site under a hold test gets a card: it says why the page waits.
            guard let held else { return }
            post(.waitReach(reach, estimate: estimate(for: reach, now: now), next: nextTask(reach.project),
                            lastDrift: log.lastDrift(for: reach.tool.name), heldUntil: held, now: now), at: now)
        case .done(let reach, let project, let needsInput):
            // The tool's own word, while they're away. Said only if they're
            // still away once the grace is over: most come back by then.
            DecisionLog.shared.record(.wait, needsInput ? "needsInput" : "done", detail: reach.tool.kind.rawValue)
            let grace = needsInput ? WaitRules.questionGrace : WaitRules.doneGrace
            pendingDone = (reach, project, needsInput, now.addingTimeInterval(grace))
            startTimer()
        case .ended(let record, let back):
            pendingDone = nil
            log.add(record)
            DecisionLog.shared.record(.wait, record.drifted ? "drifted" : "stayed", detail: back ? "back" : "gone")
            if back { island?.remove(key: IslandMoment.waitKey) }
        }
    }

    /// How much longer the tool has to go. A tool that said when it started
    /// is judged by its own past runs that got this far; one that didn't, by
    /// how long the user usually stays away from it.
    func estimate(for reach: WaitReach, now: Date) -> WaitEstimate {
        if let started = reach.runStarted {
            return log.estimate(tool: reach.tool.name, project: reach.project, elapsed: now.timeIntervalSince(started))
        }
        guard let usual = log.usualWait(for: reach.tool.name) else { return .unknown }
        let left = usual - now.timeIntervalSince(reach.since)
        return left > 0 ? .left(left) : .unknown
    }

    /// A tool said it started: `focusguard://wait/start`, from its hook.
    func started(tool: String, project: String?, session: String? = nil, now: Date = .now) {
        guard isOn() else { return }
        // With no word that it's done, it's believed for as long as its
        // longest run here and half as much again: a long job is still a wait.
        let longest = log.longestRun(tool: tool, project: project) ?? 0
        let believed = min(WaitRules.longestBelieved, max(WaitRules.believedWorking, WaitRules.believedMargin * longest))
        let hasHome = watcher.started(tool: tool, project: project, session: session, front: currentMoment().front,
                                      believeFor: believed, uptime: uptime(), at: now)
        DecisionLog.shared.record(.wait, "started", detail: hasHome ? "exact" : "elsewhere")
    }

    /// A tool said it finished, or that it needs an answer: `focusguard://wait/done`.
    /// - Parameter quiet: it went idle or was closed, rather than finishing.
    func finished(tool: String, project: String?, session: String? = nil, needsInput: Bool = false, quiet: Bool = false,
                  now: Date = .now) {
        guard isOn() else { return }
        let events = watcher.finished(tool: tool, project: project, session: session, needsInput: needsInput, quiet: quiet,
                                      uptime: uptime(), at: now)
        for event in events { handle(event, now: now) }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.observe(self.currentMoment())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

extension IslandMoment {
    /// One wait card at a time: the done card takes the reach card's place.
    static let waitKey = "wait"

    /// What it cost last time, or that the site won't make the tool any
    /// faster; then something real to do meanwhile, or how much longer the
    /// tool usually needs from here, and the way back.
    static func waitReach(_ reach: WaitReach, estimate: WaitEstimate, next: TaskItem?, lastDrift: WaitRecord?,
                          heldUntil: Date? = nil, now: Date) -> IslandMoment {
        let place = reach.project ?? reach.tool.name
        let tool = reach.tool.name
        let kicker = reach.project.map {
            String(localized: "\(tool) is still working on \($0)", comment: "The tool, then the project: Codex is still working on Curiplay")
        } ?? String(localized: "\(tool) is still working", comment: "The tool: Codex is still working")
        let title: String
        if let heldUntil {
            let minutes = max(1, Int((heldUntil.timeIntervalSince(now) / 60).rounded(.up)))
            title = String(localized: "\(reach.to) is on hold for \(minutes) min.",
                           comment: "Wait card when the site is held by the user's Analyzer test. The site, then minutes")
        } else if let lastDrift, lastDrift.drift >= 60 {
            title = String(localized: "Last time, \(lastDrift.to ?? reach.to) took \(Int(lastDrift.drift / 60)) min.",
                           comment: "Warning on the wait card. The site, then minutes: Last time, x.com took 9 min.")
        } else {
            title = String(localized: "\(reach.to) won’t make \(tool) any faster.",
                           comment: "Warning on the wait card. The site, then the tool: x.com won't make Codex any faster.")
        }
        let body: String
        if let next {
            body = String(localized: "Read “\(next.title)” while you wait, so you’re ready when \(tool) is.",
                          comment: "The open task's title, then the tool")
        } else {
            body = waitBody(tool: tool, estimate: estimate)
        }
        // Counted down only when there's something to count: a hold, or the tool's own usual time.
        var ends = heldUntil
        if ends == nil, case .left(let seconds) = estimate { ends = now.addingTimeInterval(seconds) }
        return IslandMoment(
            kind: .wait, key: waitKey, pillName: place,
            kicker: kicker,
            title: title,
            body: body,
            tone: .attention,
            buttons: [IslandButton(title: String(localized: "Back to \(place)", comment: "Button: the project or tool to go back to"),
                                   command: .backTo(bundleId: reach.tool.bundleId, host: reach.tool.host)),
                      IslandButton(title: heldUntil == nil ? String(localized: "Open \(reach.to) anyway", comment: "Button: the site, kept open")
                                                           : String(localized: "OK", comment: "Button: close the card"))],
            countdown: ends.flatMap { $0 > now ? IslandCountdown(ends: $0, total: $0.timeIntervalSince(now)) : nil },
            startsOpen: true
        )
    }

    /// How much longer the tool needs, in its own numbers; with none yet, no number at all.
    private static func waitBody(tool: String, estimate: WaitEstimate) -> String {
        switch estimate {
        case .left(let seconds) where seconds >= 45:
            let minutes = max(1, Int((seconds / 60).rounded()))
            return String(localized: "\(tool) usually needs about \(minutes) more min from here. Stay close and you’ll catch it the moment it’s done.",
                          comment: "Wait card. The tool, then minutes still to go, from its own past runs")
        case .overdue(let worked) where worked >= 90:
            let minutes = Int((worked / 60).rounded())
            return String(localized: "\(tool) has been working for \(minutes) min, longer than most of its runs. It could be done any moment.",
                          comment: "Wait card. The tool, then the minutes it has worked so far")
        case .left, .overdue:
            return String(localized: "\(tool) is usually done within a minute from here. Stay and you’ll catch it.",
                          comment: "Wait card. The tool, which is about to finish going by its past runs")
        case .unknown:
            return String(localized: "Stay close and you’ll catch it the moment it’s done.",
                          comment: "Wait card, when the tool's usual time isn't known yet")
        }
    }

    /// "Claude Code just finished.", or "Claude Code needs your answer.":
    /// the tool said so while the user was away.
    static func waitDone(_ reach: WaitReach, project: String?, needsInput: Bool, now: Date) -> IslandMoment {
        let place = project ?? reach.project ?? reach.tool.name
        let minutes = max(1, Int(now.timeIntervalSince(reach.since) / 60))
        return IslandMoment(
            kind: .wait, key: waitKey, pillName: place,
            pillValue: needsInput ? String(localized: "Needs you", comment: "Pill: the tool is waiting for the user's answer")
                                  : String(localized: "Done", comment: "Pill: the tool has finished"),
            kicker: String(localized: "\(minutes) min on \(reach.to)", comment: "Minutes, then the site the user went to: 4 min on x.com"),
            title: needsInput ? String(localized: "\(reach.tool.name) needs your answer.", comment: "The tool, which asked the user something: Claude Code needs your answer.")
                              : String(localized: "\(reach.tool.name) just finished.", comment: "The tool, which said it finished: Codex just finished."),
            body: needsInput ? String(localized: "It asked you something in \(place) and can’t go on until you answer.", comment: "The project or tool")
                             : String(localized: "Its work is waiting in \(place). Go now, while what you asked is still fresh.",
                                      comment: "The project or tool"),
            tone: .attention,
            buttons: [IslandButton(title: String(localized: "Back to \(place)", comment: "Button: the project or tool to go back to"),
                                   command: .backTo(bundleId: reach.tool.bundleId, host: reach.tool.host)),
                      IslandButton(title: String(localized: "In a minute", comment: "Button: close the card, go back later"))],
            startsOpen: true
        )
    }
}
