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
    /// The menu's Recent list.
    let recents: IslandRecents

    private(set) var queue: IslandQueue
    private let surface: IslandSurface
    private let clock: () -> Date
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

    func post(_ moment: IslandMoment) {
        let now = clock()
        if queue.post(moment, now: now), let entry = queue.current {
            surface.update(entry.moment, open: entry.isOpen, now: now)
        }
        tick()
    }

    func remove(key: String) {
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
            surface.show(moment, open: queue.isOpen, now: clock())
            surface.announce(moment.announcement(at: clock()), urgent: moment.kind == .drift || moment.kind == .limit)
            if IslandSettings.hasSound(moment.kind), defaults.bool(forKey: IslandSettings.softSound) { playSound(moment.kind) }
            recents.note(moment, at: clock(), expires: queue.current?.expires)
            didShow(moment)
        case .hid:
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
        remove(key: moment.key)
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
}
