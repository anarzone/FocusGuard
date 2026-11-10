import AppKit
import Foundation

/// Settings › Notifications: how FocusGuard's notifications show.
enum IslandSettings {
    static let surface = "notifications.surface"
    static let softSound = "notifications.softSound"
    static let quietWhileSharing = "notifications.quietWhileSharing"
    /// What's on the island or waiting, so a quit doesn't lose it (`IslandQueue.Saved`).
    static let savedQueue = "island.queue"

    enum Surface: String, CaseIterable, Identifiable {
        case cards, macOS
        var id: String { rawValue }
    }

    /// Cards until the user picks macOS notifications.
    static func surface(_ defaults: UserDefaults = .standard) -> Surface {
        defaults.string(forKey: surface).flatMap(Surface.init) ?? .cards
    }

    /// On until the user turns it off.
    static func isQuietWhileSharing(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: quietWhileSharing) as? Bool ?? true
    }

    /// Asked when macOS notifications get picked: cards don't need the
    /// permission, and macOS only prompts once.
    static func shouldAskForNotifications(surface: Surface, status: PermissionStatus) -> Bool {
        surface == .macOS && status == .notDetermined
    }

    static func hasSound(_ kind: IslandKind) -> Bool {
        kind == .drift || kind == .sessionFinished
    }
}

/// Puts the island on screen (`IslandPanelController`); tests record instead.
@MainActor
protocol IslandSurface: AnyObject {
    func attach(_ island: IslandController)
    func show(_ moment: IslandMoment, open: Bool, now: Date)
    func update(_ moment: IslandMoment, open: Bool, now: Date)
    func hide()
    func announce(_ text: String, urgent: Bool)
}

/// The one floating island: decides with `IslandQueue` what shows, tells the
/// surface, and sends button presses down the notifications' single route.
@MainActor
final class IslandController {
    /// Set by AppState.
    var conditions: () -> IslandConditions = { IslandConditions(now: .now) }
    /// Whether settings still allow a kind; a change applies to what's waiting too.
    var isAllowed: (IslandKind) -> Bool = { _ in true }
    /// Where the status item is, once it has a window.
    var statusItemFrame: () -> NSRect? = { nil }
    /// Pick up's card reads and acts on this.
    var pickUpCoordinator: PickUpCoordinator?
    /// The buttons' route. Tests record instead.
    var perform: (NotificationCommand) -> Void = { NotificationRouter.shared.perform($0) }
    var playSound: (IslandKind) -> Void = { _ in NSSound(named: "Tink")?.play() }
    /// A moment really showed. The trial reminder counts as sent only now.
    var didShow: (IslandMoment) -> Void = { _ in }
    /// A card was answered: the button's command, nil when it was closed or
    /// a button that only closes was pressed.
    var didAnswer: (IslandKind, NotificationCommand?) -> Void = { _, _ in }
    /// The menu's Recent list.
    let recents: IslandRecents

    private(set) var queue: IslandQueue
    private let surface: IslandSurface
    private let clock: () -> Date
    private let calendar: Calendar
    private let defaults: UserDefaults
    private let runsTimer: Bool
    private var timer: Timer?
    private var lastSaved: [IslandQueue.Saved] = []

    init(surface: IslandSurface, clock: @escaping () -> Date = { .now }, defaults: UserDefaults = .standard,
         calendar: Calendar = .current, runsTimer: Bool = true) {
        self.surface = surface
        self.clock = clock
        self.defaults = defaults
        self.runsTimer = runsTimer
        self.queue = IslandQueue(calendar: calendar)
        self.recents = IslandRecents(defaults: defaults, calendar: calendar)
        self.learning = IslandLearning.load(defaults)
        self.calendar = calendar
        surface.attach(self)
    }

    /// Brings back what was waiting at the last quit, once the conditions are wired.
    func restoreWaiting() {
        recents.forgetOtherDays(now: clock())
        guard let data = defaults.data(forKey: IslandSettings.savedQueue),
              let saved = try? JSONDecoder().decode([IslandQueue.Saved].self, from: data) else { return }
        queue.restore(saved, now: clock())
        lastSaved = saved
        tick()
    }

    /// When a suggestion last showed, and which: another kind keeps away for a while.
    private var lastSuggestion: (kind: IslandKind, at: Date)?
    /// Which cards get used, so a kind let go by again and again shows
    /// less, then pauses (`IslandLearning`).
    private(set) var learning: IslandLearning
    /// On screen and not answered yet: going away like this is letting it pass.
    private var unanswered: IslandMoment?

    func post(_ moment: IslandMoment) {
        let now = clock()
        // Another suggestion right after one about the same stretch says the
        // same thing twice. The wait card's own updates (done, needs you) pass.
        if moment.kind.isSuggestion, !moment.requested, let last = lastSuggestion, last.kind != moment.kind,
           now.timeIntervalSince(last.at) < IslandRules.betweenSuggestions {
            DecisionLog.shared.record(.island, "skipped", detail: moment.kind.rawValue)
            return
        }
        // A kind the user keeps letting go by waits: once a day, or a pause.
        // An update to one already here isn't a new card.
        if !moment.requested, !queue.has(key: moment.key), learning.holds(moment.kind, now: now, calendar: calendar) != nil {
            DecisionLog.shared.record(.island, "held", detail: moment.kind.rawValue)
            return
        }
        if queue.post(moment, now: now), let entry = queue.current {
            surface.update(entry.moment, open: entry.isOpen, now: now)
        }
        tick()
    }

    /// Taken away by what it was about: the offer stopped being true. That
    /// says nothing about whether the card was wanted.
    func remove(key: String) {
        if unanswered?.key == key { unanswered = nil }
        recents.noteAnswered(key: key)
        if queue.remove(key: key, now: clock()) { surface.hide() }
        tick()
    }

    /// A session or break ended: what's waiting can show.
    func notePause() {
        queue.notePause(now: clock())
        tick()
    }

    /// Once a second while there's anything to do, and after every change.
    func tick() {
        switch queue.step(conditions(), allowed: isAllowed) {
        case .showed(let moment):
            DecisionLog.shared.record(.island, "shown", detail: moment.kind.rawValue)
            // One pushed off by a more urgent card wasn't let go by: it says nothing.
            unanswered = moment.requested ? nil : moment
            if !moment.requested { learn { $0.shown(moment.kind, now: clock()) } }
            if moment.kind.isSuggestion { lastSuggestion = (moment.kind, clock()) }
            surface.show(moment, open: queue.isOpen, now: clock())
            surface.announce(moment.announcement(at: clock()), urgent: moment.kind == .drift || moment.kind == .limit)
            if IslandSettings.hasSound(moment.kind), defaults.bool(forKey: IslandSettings.softSound) { playSound(moment.kind) }
            recents.note(moment, at: clock(), expires: queue.current?.expires)
            didShow(moment)
        case .hid:
            // Its time on screen ran out with no answer.
            if let gone = unanswered { notePassed(gone) }
            surface.hide()
        case .none:
            refresh()
        }
        for gone in queue.takeTimedOut() { recents.noteTimedOut(gone.moment, expired: gone.expires, now: clock()) }
        save()
        keepTimer()
    }

    /// After every change, so a crash loses nothing either.
    private func save() {
        let saved = queue.saved
        guard saved != lastSaved else { return }
        lastSaved = saved
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: IslandSettings.savedQueue) }
    }

    // MARK: - From the surface

    func hover(_ inside: Bool) {
        queue.setHover(inside, now: clock())
        if queue.current?.moment.kind == .pickUp { pickUpCoordinator?.setBeingRead(inside) }
        refresh()
    }

    func openByHand() {
        queue.openByHand(now: clock())
        if queue.current?.moment.kind == .pickUp { pickUpCoordinator?.setBeingRead(true) }
        refresh()
    }

    func press(_ button: IslandButton) {
        let kind = queue.current?.moment.kind
        DecisionLog.shared.record(.island, button.command == nil ? "dismissed" : "pressed", detail: kind?.rawValue)
        if let kind, unanswered?.kind == kind { noteAnswer(kind, used: button.command != nil) }
        if let kind { didAnswer(kind, button.command) }
        if button.command == nil, kind == .weekReady {
            queue.tuck(now: clock())
            refresh()
            return
        }
        if let key = queue.current?.moment.key { remove(key: key) }
        if let command = button.command { perform(command) }
    }

    /// The close button.
    func closeCurrent() {
        guard let moment = queue.current?.moment else { return }
        DecisionLog.shared.record(.island, "closed", detail: moment.kind.rawValue)
        if unanswered?.key == moment.key { noteAnswer(moment.kind, used: false) }
        didAnswer(moment.kind, nil)
        remove(key: moment.key)
    }

    // MARK: - Learning

    /// Used or let go by, said once per card.
    func noteAnswer(_ kind: IslandKind, used: Bool) {
        unanswered = nil
        if used {
            learn { $0.used(kind) }
            return
        }
        var changed: IslandLearning.State?
        learn { changed = $0.passed(kind, now: clock(), calendar: calendar) }
        switch changed {
        case .resting?: DecisionLog.shared.record(.island, "rested", detail: kind.rawValue)
        case .paused?:  DecisionLog.shared.record(.island, "paused", detail: kind.rawValue)
        default: break
        }
    }

    private func notePassed(_ moment: IslandMoment) {
        guard !moment.requested else { return }
        noteAnswer(moment.kind, used: false)
    }

    /// "Erase all data".
    func forgetLearning() {
        learning = IslandLearning()
        unanswered = nil
    }

    /// Settings' "Bring it back".
    func bringBack(_ kind: IslandKind) {
        learn { $0.bringBack(kind) }
        DecisionLog.shared.record(.island, "broughtBack", detail: kind.rawValue)
    }

    private func learn(_ change: (inout IslandLearning) -> Void) {
        var next = learning
        change(&next)
        guard next != learning else { return }
        learning = next
        next.save(defaults)
    }

    private func refresh() {
        guard let entry = queue.current else { return }
        surface.update(entry.moment, open: entry.isOpen, now: clock())
    }

    private func keepTimer() {
        guard runsTimer else { return }
        if queue.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }
}

/// Pick up's card goes on the island: there's one surface.
@MainActor
final class IslandPickUpPresenter: PickUpPresenting {
    private let island: IslandController

    init(island: IslandController) {
        self.island = island
    }

    func show(_ card: PickUpCard, coordinator: PickUpCoordinator) {
        island.pickUpCoordinator = coordinator
        island.post(.pickUp(card))
    }

    func close() {
        island.remove(key: IslandMoment.pickUpKey)
    }

    func answered(used: Bool) {
        island.noteAnswer(.pickUp, used: used)
    }
}
