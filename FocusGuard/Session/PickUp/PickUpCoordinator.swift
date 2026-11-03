import Foundation

/// Shows and hides the floating card (`PickUpPanelController`).
@MainActor
protocol PickUpPresenting: AnyObject {
    func show(_ card: PickUpCard, coordinator: PickUpCoordinator)
    func close()
}

/// "Pick up where you left off": watches for returns (`PickUpWatcher`), works
/// out the places from the activity already tracked (`PickUpPlaces`), and
/// goes back to them (`PickUpRestore`).
@MainActor
@Observable
final class PickUpCoordinator {
    /// The card on screen.
    private(set) var card: PickUpCard?
    /// "Resume your session too", ticked unless the user unticks it.
    var resumeTicked = true
    /// The row picked on the menu's card; the first until another is.
    var pickedPlaceID: String?
    /// The last places, for the menu's entry.
    private(set) var menuPlaces: [PickUpPlace] = []

    // MARK: Hooks (set by AppState)

    /// Activity between two dates, newest first, read off the main thread.
    @ObservationIgnored var readEvents: (_ from: Date, _ before: Date, _ focusOnly: Bool) async -> [PickUpEvent] = { _, _, _ in [] }
    @ObservationIgnored var optedOut: () -> Set<String> = { [] }
    @ObservationIgnored var session: () -> PickUpSessionInfo? = { nil }
    /// Resumes the paused session, unless it's been paused too long.
    @ObservationIgnored var resumeSession: () -> Void = {}
    /// What's going on right now, for a decision made after reading the store.
    @ObservationIgnored var currentMoment: () -> PickUpMoment = { PickUpMoment(now: .now) }

    @ObservationIgnored private let opener: PickUpOpening
    @ObservationIgnored private let presenter: PickUpPresenting?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var watcher = PickUpWatcher()
    @ObservationIgnored private var shownAt: Date?
    @ObservationIgnored private var lastCardAt: Date?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var menuPlacesAt: Date = .distantPast
    @ObservationIgnored private var lastNoted: ActivitySnapshot?
    /// The read in progress after a return, for tests to wait on.
    @ObservationIgnored private(set) var considering: Task<Void, Never>?

    init(opener: PickUpOpening, presenter: PickUpPresenting?, defaults: UserDefaults = .standard) {
        self.opener = opener
        self.presenter = presenter
        self.defaults = defaults
    }

    // MARK: - Watching

    /// Called from the tracker's tick.
    func observe(_ moment: PickUpMoment) {
        noteFrontWindow(moment)
        closeIfDue(moment)
        guard let found = watcher.observe(moment), isSwitchedOn(found.kind) else { return }
        considering = Task { await consider(found, at: moment.now) }
    }

    private func isSwitchedOn(_ kind: PickUpReturn.Kind) -> Bool {
        switch kind {
        case .call:  return PickUpSettings.isOn(PickUpSettings.afterCall, defaults)
        case .away:  return PickUpSettings.isOn(PickUpSettings.afterAway, defaults)
        case .drift: return PickUpSettings.isOn(PickUpSettings.afterDrift, defaults)
        }
    }

    /// Reads what came before the interruption, then decides.
    private func consider(_ found: PickUpReturn, at now: Date) async {
        let events = await readEvents(found.since.addingTimeInterval(-PickUpRules.placesLookback), found.since, false)
        let forgetBefore = PickUpSettings.forgottenBefore(defaults)
        let places = PickUpPlaces.choose(events, optedOut: optedOut(), forgetBefore: forgetBefore, now: now,
                                         limit: PickUpSettings.bringBackCount(defaults))
        let focused = PickUpPlaces.focusedSeconds(before: found.since, in: events, forgetBefore: forgetBefore, now: now)
        guard PickUpRules.allows(currentMoment(), places: places, focused: focused,
                                 cardShowing: card != nil, lastCardAt: lastCardAt) else { return }
        let next = PickUpCard.returning(found, places: places, session: session(),
                                        sawPrivateWindow: PickUpPlaces.hadPrivateWindow(in: events, after: places.first))
        lastCardAt = now
        present(next, at: now)
    }

    /// The card closes once the user's back there, when a call or a screen
    /// comes up, and after a while anyway.
    private func closeIfDue(_ moment: PickUpMoment) {
        guard let card, let shownAt else { return }
        let expired = moment.now.timeIntervalSince(shownAt) >= PickUpRules.cardLifetime
        let returned = card.kind != .menu && card.kind != .failed && PickUpRules.isBack(moment, in: card.places)
        // What was asked for from the menu can stay through a call.
        let called = moment.inCall && card.kind != .menu
        if expired || returned || called || moment.screenUp { close() }
    }

    /// While the user is in focused work, macOS may name the window's
    /// document. Never for an opted-out app or a browser's private window.
    private func noteFrontWindow(_ moment: PickUpMoment) {
        guard let front = moment.front, !moment.frontIsSelf, !moment.isAway, front.classification == .focus,
              !front.isPrivateWindow, !BrowserTabReader.isBrowser(bundleIdentifier: front.bundleIdentifier),
              !optedOut().contains(front.bundleIdentifier) else { return }
        if let lastNoted, lastNoted.isSameActivity(as: front) { return }
        lastNoted = front
        opener.noteFrontWindow(bundleId: front.bundleIdentifier, title: front.windowTitle)
    }

    // MARK: - Showing

    private func present(_ next: PickUpCard, at now: Date) {
        card = next
        resumeTicked = true
        pickedPlaceID = next.kind == .menu ? next.places.first?.id : nil
        shownAt = now
        presenter?.show(next, coordinator: self)
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PickUpRules.cardLifetime))
            guard !Task.isCancelled, let self, self.card?.id == next.id else { return }
            self.close()
        }
    }

    /// Not now, Skip, Close, or closing by itself.
    func close() {
        expiry?.cancel()
        expiry = nil
        card = nil
        pickedPlaceID = nil
        shownAt = nil
        presenter?.close()
    }

    // MARK: - The menu

    /// The menu's entry reads this. At most every half minute while the menu's open.
    func refreshMenuPlaces(now: Date = .now, force: Bool = false) async {
        guard force || now.timeIntervalSince(menuPlacesAt) >= 30 else { return }
        menuPlacesAt = now
        let places = await lastPlaces(now: now)
        if places != menuPlaces { menuPlaces = places }
    }

    private func lastPlaces(now: Date) async -> [PickUpPlace] {
        let events = await readEvents(now.addingTimeInterval(-PickUpPlaces.keptFor), now, true)
        return PickUpPlaces.choose(events, optedOut: optedOut(), forgetBefore: PickUpSettings.forgottenBefore(defaults), now: now)
    }

    /// The menu's "Where you left off", or the shortcut with no card up.
    func showLastPlaces(now: Date = .now) async {
        guard !currentMoment().screenUp else { return }
        let places = await lastPlaces(now: now)
        menuPlaces = places
        guard !places.isEmpty, !currentMoment().screenUp else { return }
        present(PickUpCard.lastPlaces(places, now: now), at: now)
    }

    /// "Forget my last places".
    func forgetPlaces(now: Date = .now) {
        PickUpSettings.forget(now: now, defaults)
        menuPlaces = []
        if card?.kind == .menu { close() }
    }

    /// The menu card's button, which follows the row picked.
    func menuPrimaryTitle(now: Date = .now) -> String? {
        guard card?.kind == .menu else { return card?.primary }
        return pickedPlace.map { PickUpCard.pickUpTitle(for: $0, now: now) }
    }

    private var pickedPlace: PickUpPlace? {
        card?.places.first { $0.id == pickedPlaceID } ?? card?.places.first
    }

    // MARK: - Picking up

    /// The shortcut: presses the card's button, or brings up the last places.
    func shortcutPressed(now: Date = .now) {
        considering = Task {
            if card == nil { await showLastPlaces(now: now) } else { await pressPrimary() }
        }
    }

    /// The card's main button.
    func pressPrimary() async {
        guard let card else { return }
        if card.kind == .failed { return openFailedPages() }
        let places = card.kind == .menu ? (pickedPlace.map { [$0] } ?? []) : card.places
        let resume = card.resumeOffer != nil && resumeTicked
        close()
        let result = await PickUpRestore.run(places, with: opener)
        if resume { resumeSession() }
        guard !result.failed.isEmpty else { return }
        present(PickUpCard.failed(back: result.back, failed: result.failed), at: currentMoment().now)
    }

    /// "Open in browser", for pages that didn't come back.
    private func openFailedPages() {
        for address in card?.places.compactMap(\.url) ?? [] {
            if let url = URL(string: address) { opener.openInDefaultBrowser(url) }
        }
        close()
    }
}
