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
            if let lastCardAt, now.timeIntervalSince(lastCardAt) < WaitRules.gapBetweenCards { return }
            lastCardAt = now
            island?.post(.waitReach(reach, usual: log.usualWait(for: reach.tool.name), next: nextTask(reach.project),
                                    lastDrift: log.lastDrift(for: reach.tool.name), now: now))
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

    /// "While Codex works on Curiplay": the next step, and the way back.
    static func waitReach(_ reach: WaitReach, usual: TimeInterval, next: TaskItem?, lastDrift: WaitRecord?, now: Date) -> IslandMoment {
        let place = reach.project ?? reach.tool.name
        let kicker = reach.project.map {
            String(localized: "While \(reach.tool.name) works on \($0)", comment: "The tool, then the project: While Codex works on Curiplay")
        } ?? String(localized: "While \(reach.tool.name) works", comment: "The tool: While Codex works")
        let body: String
        if let next {
            body = String(localized: "Next on \(place): \(next.title)", comment: "The project, then an open task's title")
        } else if let lastDrift, lastDrift.drift >= 60 {
            body = String(localized: "Last time you opened \(lastDrift.to ?? reach.to) in a wait, you were gone \(Int(lastDrift.drift / 60)) min.",
                          comment: "The site, then minutes: Last time you opened x.com in a wait, you were gone 9 min.")
        } else {
            body = String(localized: "It usually takes about \(max(1, Int((usual / 60).rounded()))) min. A minute on \(reach.to) tends to become more.",
                          comment: "Minutes, then the site")
        }
        let ends = reach.since.addingTimeInterval(usual)
        return IslandMoment(
            kind: .wait, key: waitKey, pillName: place,
            kicker: kicker,
            title: String(localized: "Use the wait for the next step?", comment: "Card title when the user reaches for a distraction while a tool works"),
            body: body,
            buttons: [IslandButton(title: String(localized: "Back to \(place)", comment: "Button: the project or tool to go back to"),
                                   command: .backTo(bundleId: reach.tool.bundleId, host: reach.tool.host)),
                      IslandButton(title: String(localized: "Open \(reach.to) anyway", comment: "Button: the site, kept open"))],
            countdown: ends > now ? IslandCountdown(ends: ends, total: ends.timeIntervalSince(now)) : nil,
            startsOpen: true
        )
    }

    /// "Codex is probably done": the usual wait is up and they're still away.
    /// "Codex is done" when it said so itself.
    static func waitDone(_ reach: WaitReach, exact: Bool = false, now: Date) -> IslandMoment {
        let place = reach.project ?? reach.tool.name
        let minutes = max(1, Int(now.timeIntervalSince(reach.since) / 60))
        return IslandMoment(
            kind: .wait, key: waitKey, pillName: place,
            pillValue: exact ? String(localized: "Done", comment: "Pill: the tool has finished")
                             : String(localized: "Done?", comment: "Pill: the tool has probably finished"),
            kicker: String(localized: "\(minutes) min since you left it", comment: "Minutes since the user left the tool"),
            title: exact ? String(localized: "\(reach.tool.name) is done", comment: "The tool, which said it finished: Codex is done")
                         : String(localized: "\(reach.tool.name) is probably done", comment: "The tool: Codex is probably done"),
            body: String(localized: "\(place) is where you left it.", comment: "The project or tool"),
            tone: .attention,
            buttons: [IslandButton(title: String(localized: "Back to \(place)", comment: "Button: the project or tool to go back to"),
                                   command: .backTo(bundleId: reach.tool.bundleId, host: reach.tool.host)),
                      IslandButton(title: String(localized: "In a minute", comment: "Button: close the card, go back later"))],
            startsOpen: true
        )
    }
}
