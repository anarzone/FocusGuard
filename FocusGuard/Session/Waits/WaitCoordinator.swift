import Foundation

/// The setting: on until it's switched off.
enum WaitSettings {
    static let enabled = "waits.enabled"

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabled) as? Bool ?? true
    }
}

/// Turns what the watcher notices into the island's card: when the user
/// reaches for a distraction while a tool works, the project's next step and
/// a way back; when the tool's usual wait is up and they're still away, that
/// it's probably done. Every wait that ends goes in the log.
@MainActor
final class WaitCoordinator {
    private var watcher = WaitWatcher()
    private let log: WaitLog
    private let island: IslandController?
    private var timer: Timer?
    private var lastCardAt: Date?

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

    init(log: WaitLog = .shared, island: IslandController?) {
        self.log = log
        self.island = island
    }

    func observe(_ moment: WaitMoment) {
        guard isOn() else {
            stopTimer()
            return
        }
        for event in watcher.observe(moment, usualWait: { [log] in log.usualWait(for: $0.name) }) {
            handle(event, now: moment.now)
        }
        // The tracker may look rarely when nothing's timed: keep an eye on
        // the wait's end while one is going.
        watcher.isWaiting ? startTimer() : stopTimer()
    }

    private func handle(_ event: WaitEvent, now: Date) {
        switch event {
        case .reached(let reach):
            DecisionLog.shared.record(.wait, "reached", detail: reach.tool.kind.rawValue)
            // Quick waits back to back: one card is enough for a while.
            // A held site is held every time, card or not.
            let held = holdSeconds(reach).map { reach.since.addingTimeInterval(TimeInterval($0)) }.flatMap { $0 > now ? $0 : nil }
            if let held {
                DecisionLog.shared.record(.wait, "held", detail: reach.tool.kind.rawValue)
                hold(reach, held)
            }
            if let lastCardAt, now.timeIntervalSince(lastCardAt) < WaitRules.gapBetweenCards { return }
            lastCardAt = now
            island?.post(.waitReach(reach, usual: log.usualWait(for: reach.tool.name), next: nextTask(reach.project),
                                    lastDrift: log.lastDrift(for: reach.tool.name), heldUntil: held, now: now))
        case .probablyDone(let reach, let exact):
            island?.post(.waitDone(reach, exact: exact, now: now))
        case .ended(let record, let back):
            log.add(record)
            DecisionLog.shared.record(.wait, record.drifted ? "drifted" : "stayed", detail: back ? "back" : "gone")
            if back { island?.remove(key: IslandMoment.waitKey) }
        }
    }

    /// A tool said it started: `focusguard://wait/start`, from its hook.
    func started(tool: String, project: String?, now: Date = .now) {
        guard isOn() else { return }
        DecisionLog.shared.record(.wait, "started", detail: "exact")
        watcher.started(tool: tool, project: project, front: currentMoment().front, at: now)
    }

    /// A tool said it finished: `focusguard://wait/done`.
    func finished(tool: String, now: Date = .now) {
        guard isOn() else { return }
        for event in watcher.finished(tool: tool, at: now) { handle(event, now: now) }
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
    /// faster; then something real to do meanwhile, and the way back.
    static func waitReach(_ reach: WaitReach, usual: TimeInterval, next: TaskItem?, lastDrift: WaitRecord?,
                          heldUntil: Date? = nil, now: Date) -> IslandMoment {
        let place = reach.project ?? reach.tool.name
        let tool = reach.tool.name
        let usualMinutes = max(1, Int((usual / 60).rounded()))
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
            body = String(localized: "\(tool) usually needs about \(usualMinutes) min. Stay close and you’ll catch it the moment it’s done.",
                          comment: "The tool, then minutes")
        }
        let ends = heldUntil ?? reach.since.addingTimeInterval(usual)
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
            countdown: ends > now ? IslandCountdown(ends: ends, total: ends.timeIntervalSince(now)) : nil,
            startsOpen: true
        )
    }

    /// "Codex has probably finished.": the usual wait is up and they are still away.
    /// "Codex just finished." when it said so itself.
    static func waitDone(_ reach: WaitReach, exact: Bool = false, now: Date) -> IslandMoment {
        let place = reach.project ?? reach.tool.name
        let minutes = max(1, Int(now.timeIntervalSince(reach.since) / 60))
        return IslandMoment(
            kind: .wait, key: waitKey, pillName: place,
            pillValue: exact ? String(localized: "Done", comment: "Pill: the tool has finished")
                             : String(localized: "Done?", comment: "Pill: the tool has probably finished"),
            kicker: String(localized: "\(minutes) min on \(reach.to)", comment: "Minutes, then the site the user went to: 4 min on x.com"),
            title: exact ? String(localized: "\(reach.tool.name) just finished.", comment: "The tool, which said it finished: Codex just finished.")
                         : String(localized: "\(reach.tool.name) has probably finished.", comment: "The tool: Codex has probably finished."),
            body: String(localized: "Its work is waiting in \(place). Go now, while what you asked is still fresh.",
                         comment: "The project or tool"),
            tone: .attention,
            buttons: [IslandButton(title: String(localized: "Back to \(place)", comment: "Button: the project or tool to go back to"),
                                   command: .backTo(bundleId: reach.tool.bundleId, host: reach.tool.host)),
                      IslandButton(title: String(localized: "In a minute", comment: "Button: close the card, go back later"))],
            startsOpen: true
        )
    }
}
