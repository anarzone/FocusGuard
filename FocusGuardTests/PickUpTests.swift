import SwiftData
import XCTest
@testable import FocusGuard

/// "Pick up where you left off": which places, when the card comes up, what
/// it says and how it goes back. Nothing here reaches a real app.
@MainActor
final class PickUpTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let xcode = "com.example.code"
    private let terminal = "com.example.shell"
    private let arc = "company.thebrowser.Browser"

    // MARK: - Fakes

    private final class FakeOpener: PickUpOpening {
        var calls: [String] = []
        var failingApps: Set<String> = []
        var failingPages = false
        var pagesShowing: Set<String> = []
        var windows: Set<String> = []
        var defaultBrowserPages: [String] = []

        func bringToFront(bundleId: String) async -> Bool {
            calls.append("front \(bundleId)")
            return !failingApps.contains(bundleId)
        }
        func isShowing(_ url: String, inBrowser bundleId: String) -> Bool { pagesShowing.contains(url) }
        func openPage(_ url: URL, inBrowser bundleId: String) async -> Bool {
            calls.append("page \(url.absoluteString) in \(bundleId)")
            return !failingPages
        }
        func openInDefaultBrowser(_ url: URL) { defaultBrowserPages.append(url.absoluteString) }
        func raiseWindow(bundleId: String, title: String) -> Bool {
            guard windows.contains(title) else { return false }
            calls.append("raise \(title)")
            return true
        }
        func reopenDocument(bundleId: String, title: String) async -> Bool {
            calls.append("document \(title)")
            return true
        }
        func noteFrontWindow(bundleId: String, title: String?) { calls.append("note \(bundleId)") }
    }

    private final class FakePresenter: PickUpPresenting {
        var shown: [PickUpCard] = []
        var closes = 0
        func show(_ card: PickUpCard, coordinator: PickUpCoordinator) { shown.append(card) }
        func close() { closes += 1 }
    }

    private func event(_ bundleId: String = "com.example.code", _ app: String = "Xcode", title: String? = "AuthSession.swift",
                       url: String? = nil, minutesAgo: Double = 10, minutes: Double = 5, classification: Classification? = .focus,
                       goal: String? = nil) -> PickUpEvent {
        let end = now.addingTimeInterval(-minutesAgo * 60)
        return PickUpEvent(bundleId: bundleId, appName: app, title: title, url: url,
                           startedAt: end.addingTimeInterval(-minutes * 60), endedAt: end,
                           classification: classification, sessionGoal: goal)
    }

    private func place(_ bundleId: String = "com.example.code", _ app: String = "Xcode", title: String? = "AuthSession.swift",
                       url: String? = nil) -> PickUpPlace {
        PickUpPlace(bundleId: bundleId, appName: app, title: title, url: url, at: now.addingTimeInterval(-600))
    }

    private func snapshot(_ bundleId: String, classification: Classification = .neutral, url: String? = nil,
                          secondsAgo: TimeInterval = 0, isPrivate: Bool = false) -> ActivitySnapshot {
        ActivitySnapshot(bundleIdentifier: bundleId, appName: bundleId, windowTitle: nil, url: url, classification: classification,
                         observedAt: now.addingTimeInterval(-secondsAgo), isPrivateWindow: isPrivate)
    }

    private func choose(_ events: [PickUpEvent], optedOut: Set<String> = [], forgetBefore: Date? = nil, limit: Int = 3) -> [PickUpPlace] {
        PickUpPlaces.choose(events, optedOut: optedOut, forgetBefore: forgetBefore, now: now, limit: limit)
    }

    private func defaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "PickUpTests-\(UUID().uuidString)"))
    }

    // MARK: - Choosing places

    func testPlacesAreNewestFirstOnePerApp() {
        let places = choose([
            event(xcode, "Xcode", title: "Old.swift", minutesAgo: 30),
            event(terminal, "Terminal", title: "zsh", minutesAgo: 20),
            event(xcode, "Xcode", title: "New.swift", minutesAgo: 10),
        ])
        XCTAssertEqual(places.map(\.appName), ["Xcode", "Terminal"])
        XCTAssertEqual(places.first?.title, "New.swift")
    }

    func testPlacesStopAtTheLimit() {
        let events = (0..<5).map { event("com.example.app\($0)", "App \($0)", minutesAgo: Double($0 * 10)) }
        XCTAssertEqual(choose(events).count, 3)
        XCTAssertEqual(choose(events, limit: 1).map(\.appName), ["App 0"])
    }

    func testNeutralDistractingAndUnsortedAreNotPlaces() {
        XCTAssertEqual(choose([
            event("com.example.a", "A", classification: .neutral),
            event("com.example.b", "B", classification: .distraction),
            event("com.example.c", "C", classification: nil),
        ]), [])
    }

    func testPassingThroughIsNotAPlace() {
        XCTAssertEqual(choose([event(minutes: 0.1)]), [])
    }

    func testCallsAndFocusGuardAreNeverPlaces() {
        XCTAssertEqual(choose([
            event("us.zoom.xos", "Zoom"),
            event(ActivityTracker.selfBundleId, "FocusGuard"),
            event(arc, "Arc", title: "Meet", url: "https://meet.google.com/abc"),
        ]), [])
    }

    func testOptedOutTitlesAreNotShownEvenFromBefore() throws {
        let place = try XCTUnwrap(choose([event(title: "Secret plans")], optedOut: [xcode]).first)
        XCTAssertNil(place.title)
        XCTAssertNil(place.what)
        XCTAssertEqual(place.appName, "Xcode")
    }

    func testPlacesOlderThanAWeekAreDropped() {
        XCTAssertEqual(choose([event(minutesAgo: 7 * 24 * 60 + 1)]), [])
        XCTAssertEqual(choose([event(minutesAgo: 7 * 24 * 60 - 1)]).count, 1)
    }

    func testForgettingDropsEverythingBeforeTheCutOff() {
        let cut = now.addingTimeInterval(-15 * 60)
        let places = choose([event(terminal, "Terminal", minutesAgo: 30), event(minutesAgo: 5, minutes: 5)], forgetBefore: cut)
        XCTAssertEqual(places.map(\.appName), ["Xcode"])
        // Begun before the cut-off, even if it ended after: it goes too.
        XCTAssertEqual(choose([event(minutesAgo: 10, minutes: 20)], forgetBefore: cut), [])
    }

    func testPrivateWindowsAreNotRemembered() {
        // The extension couldn't see it, so there's no address.
        XCTAssertEqual(choose([event(arc, "Arc", title: "My bank", url: nil)]), [])
        // From before the tracker knew: the browser names it in the title.
        XCTAssertEqual(choose([event(arc, "Arc", title: "Bank - Incognito", url: "https://bank.example/")]), [])
        XCTAssertEqual(choose([event("org.mozilla.firefox", "Firefox", title: "Bank — Private Browsing")]), [])
        // Only a browser's title counts that way.
        XCTAssertEqual(choose([event(title: "Incognito.swift")]).count, 1)
    }

    func testOnlyWebAddressesAreKeptForReopening() {
        XCTAssertEqual(choose([event(arc, "Arc", title: "Local", url: "file:///Users/me/a.html")]), [])
        XCTAssertEqual(choose([event(arc, "Arc", title: "PR", url: "https://github.com/x/1")]).first?.url, "https://github.com/x/1")
    }

    func testAPrivateWindowAfterTheLastPlaceIsNoticed() {
        let work = event(minutesAgo: 20)
        let hidden = event(arc, "Arc", title: nil, url: nil, minutesAgo: 10, classification: .neutral)
        let places = choose([work, hidden])
        XCTAssertTrue(PickUpPlaces.hadPrivateWindow(in: [work, hidden], after: places.first))
        XCTAssertFalse(PickUpPlaces.hadPrivateWindow(in: [work], after: places.first))
    }

    func testFocusedTimeCountsOnlyTheHalfHourBefore() {
        let moment = now
        let seconds = PickUpPlaces.focusedSeconds(before: moment, in: [
            event(minutesAgo: 0, minutes: 40),   // only 30 of these
            event("com.example.b", "B", minutesAgo: 1, minutes: 1, classification: .neutral),
        ], forgetBefore: nil, now: now)
        XCTAssertEqual(seconds, 30 * 60, accuracy: 0.5)
    }

    func testWhatTheRowsSay() {
        XCTAssertEqual(place(title: "AuthSession.swift — FocusGuard").what, "AuthSession.swift")
        XCTAssertEqual(place(arc, "Arc", title: "Pull request #142", url: "https://www.github.com/x").what, "Pull request #142 · github.com")
        XCTAssertEqual(place(arc, "Arc", title: nil, url: "https://github.com/x").what, "github.com")
        XCTAssertNil(place(title: "Xcode").what)
    }

    // MARK: - Finding returns

    private func moment(at secondsLater: TimeInterval = 0, front: ActivitySnapshot? = nil, away: Bool = false, lastActive: TimeInterval? = nil,
                        call: TimeInterval? = nil, screenUp: Bool = false) -> PickUpMoment {
        PickUpMoment(now: now.addingTimeInterval(secondsLater), front: front, isAway: away,
                     lastActiveAt: lastActive.map { now.addingTimeInterval($0) },
                     callSince: call.map { now.addingTimeInterval($0) }, screenUp: screenUp)
    }

    func testAwayOfFiveMinutesIsAReturn() {
        var watcher = PickUpWatcher()
        XCTAssertNil(watcher.observe(moment(away: true, lastActive: 0)))
        let found = watcher.observe(moment(at: 6 * 60))
        XCTAssertEqual(found, PickUpReturn(kind: .away, since: now, seconds: 6 * 60))
        XCTAssertNil(watcher.observe(moment(at: 6 * 60 + 1)), "once per return")
    }

    func testAShortTimeAwayIsNotAReturn() {
        var watcher = PickUpWatcher()
        _ = watcher.observe(moment(away: true, lastActive: 0))
        XCTAssertNil(watcher.observe(moment(at: 4 * 60)))
    }

    func testAwayCountsFromTheLastInput() {
        var watcher = PickUpWatcher()
        _ = watcher.observe(moment(away: true, lastActive: -5 * 60))
        XCTAssertEqual(watcher.observe(moment(at: 60))?.seconds, 6 * 60)
    }

    func testACallOfFiveMinutesIsAReturnOnceItSettles() {
        var watcher = PickUpWatcher()
        XCTAssertNil(watcher.observe(moment(at: 6 * 60, call: 0)))
        XCTAssertNil(watcher.observe(moment(at: 6 * 60 + 3)), "the microphone may come back")
        let found = watcher.observe(moment(at: 6 * 60 + 13))
        XCTAssertEqual(found, PickUpReturn(kind: .call, since: now, seconds: 6 * 60 + 3))
        XCTAssertNil(watcher.observe(moment(at: 6 * 60 + 14)))
    }

    func testAMicrophoneThatComesBackIsTheSameCall() {
        var watcher = PickUpWatcher()
        _ = watcher.observe(moment(at: 60, call: 0))
        _ = watcher.observe(moment(at: 63))
        XCTAssertNil(watcher.observe(moment(at: 66, call: 66)))
        _ = watcher.observe(moment(at: 6 * 60))
        XCTAssertEqual(watcher.observe(moment(at: 6 * 60 + 11))?.since, now, "counted from the first start")
    }

    func testAShortCallIsNotAReturn() {
        var watcher = PickUpWatcher()
        _ = watcher.observe(moment(at: 4 * 60, call: 0))
        _ = watcher.observe(moment(at: 4 * 60 + 1))
        XCTAssertNil(watcher.observe(moment(at: 4 * 60 + 12)))
    }

    private let distraction = "com.example.feed"

    private func drift(_ watcher: inout PickUpWatcher, secondsAgo: TimeInterval = 180) -> PickUpReturn? {
        watcher.observe(moment(front: snapshot(distraction, classification: .distraction, url: "https://www.x.com/home", secondsAgo: secondsAgo)))
    }

    func testLeavingADistractingSiteForSomethingElseIsAReturn() {
        var watcher = PickUpWatcher()
        XCTAssertNil(drift(&watcher))
        let found = watcher.observe(moment(at: 1, front: snapshot("com.example.notes")))
        XCTAssertEqual(found?.kind, .drift(name: "x.com"))
        XCTAssertEqual(found?.seconds ?? 0, 181, accuracy: 0.5)
        XCTAssertNil(watcher.observe(moment(at: 2, front: snapshot("com.example.notes"))))
    }

    func testUnderTwoMinutesOfDriftIsNotAReturn() {
        var watcher = PickUpWatcher()
        _ = drift(&watcher, secondsAgo: 60)
        XCTAssertNil(watcher.observe(moment(at: 1, front: snapshot("com.example.notes"))))
    }

    func testGoingStraightBackToWorkAfterDriftIsNotAReturn() {
        var watcher = PickUpWatcher()
        _ = drift(&watcher)
        XCTAssertNil(watcher.observe(moment(at: 1, front: snapshot(xcode, classification: .focus))))
    }

    func testABlockScreenEndsTheDrift() {
        var watcher = PickUpWatcher()
        _ = drift(&watcher)
        XCTAssertNil(watcher.observe(moment(at: 1, front: snapshot(distraction, classification: .distraction), screenUp: true)))
        XCTAssertNil(watcher.observe(moment(at: 2, front: snapshot("com.example.notes"))))
    }

    func testAPausedTabOrABrowserPageIsNotLeaving() {
        var watcher = PickUpWatcher()
        _ = drift(&watcher)
        XCTAssertNil(watcher.observe(moment(at: 1, front: snapshot(arc, url: nil))))
        _ = drift(&watcher)
        XCTAssertNil(watcher.observe(moment(at: 1, front: snapshot(arc, url: "file:///paused.html"))))
        _ = drift(&watcher)
        XCTAssertEqual(watcher.observe(moment(at: 1, front: snapshot(arc, url: "https://news.example/")))?.kind, .drift(name: "x.com"))
    }

    func testAPrivateWindowIsNeverDrift() {
        var watcher = PickUpWatcher()
        _ = watcher.observe(moment(front: snapshot(distraction, classification: .distraction, url: "https://x.com/", secondsAgo: 300, isPrivate: true)))
        XCTAssertNil(watcher.observe(moment(at: 1, front: snapshot("com.example.notes"))))
    }

    func testASiteAllowedForWorkIsNotDrift() {
        var watcher = PickUpWatcher()
        var allowed = moment(front: snapshot(distraction, classification: .distraction, url: "https://x.com/", secondsAgo: 300))
        allowed.frontAllowed = true
        _ = watcher.observe(allowed)
        XCTAssertNil(watcher.observe(moment(at: 1, front: snapshot("com.example.notes"))))
    }

    func testFocusGuardInFrontDoesNotEndADrift() {
        var watcher = PickUpWatcher()
        _ = drift(&watcher)
        var own = moment(at: 1, front: snapshot(distraction, classification: .distraction))
        own.frontIsSelf = true
        XCTAssertNil(watcher.observe(own))
        XCTAssertEqual(watcher.observe(moment(at: 2, front: snapshot("com.example.notes")))?.kind, .drift(name: "x.com"))
    }

    // MARK: - The nevers

    private func allows(_ moment: PickUpMoment, places: [PickUpPlace]? = nil, focused: TimeInterval = 600,
                        cardShowing: Bool = false, lastCardAt: Date? = nil) -> Bool {
        PickUpRules.allows(moment, places: places ?? [place()], focused: focused, cardShowing: cardShowing, lastCardAt: lastCardAt)
    }

    func testTheCardNeedsSomewhereToGoBackTo() {
        let front = snapshot("com.example.notes")
        XCTAssertTrue(allows(moment(front: front)))
        XCTAssertFalse(allows(moment(front: front), places: []))
        XCTAssertFalse(allows(moment(front: front), focused: 119))
        XCTAssertTrue(allows(moment(front: front), focused: 120))
    }

    func testTheCardNeverComesDuringACallOrAScreen() {
        let front = snapshot("com.example.notes")
        XCTAssertFalse(allows(moment(front: front, call: -60)))
        XCTAssertFalse(allows(moment(front: front, screenUp: true)))
        XCTAssertFalse(allows(moment(front: front, away: true)))
    }

    func testTheCardNeverComesWhenAlreadyBack() {
        XCTAssertFalse(allows(moment(front: snapshot(xcode, classification: .focus))))
        // A browser counts only on the same site.
        let page = place(arc, "Arc", title: "PR", url: "https://github.com/x/1")
        XCTAssertFalse(allows(moment(front: snapshot(arc, url: "https://www.github.com/y")), places: [page]))
        XCTAssertTrue(allows(moment(front: snapshot(arc, url: "https://news.example/")), places: [page]))
    }

    func testOneCardAtATimeWithAGapBetween() {
        let front = snapshot("com.example.notes")
        XCTAssertFalse(allows(moment(front: front), cardShowing: true))
        XCTAssertFalse(allows(moment(front: front), lastCardAt: now.addingTimeInterval(-60)))
        XCTAssertTrue(allows(moment(front: front), lastCardAt: now.addingTimeInterval(-5 * 60)))
    }

    // MARK: - Wording

    func testTitleAndSubLineFromTheGoal() {
        let card = PickUpCard.returning(PickUpReturn(kind: .call, since: now, seconds: 38 * 60), places: [place()],
                                        session: PickUpSessionInfo(goal: "Fix the login redirect", isPaused: false), sawPrivateWindow: false)
        XCTAssertEqual(card.top, "Back from your call · 38 min")
        XCTAssertEqual(card.title, "You were working on “Fix the login redirect”")
        XCTAssertEqual(card.sub, "Your goal for this session")
        XCTAssertEqual(card.primary, "Pick up")
        XCTAssertEqual(card.secondary, "Not now")
    }

    func testTitleFromTheLastWindowWithoutAGoal() {
        let card = PickUpCard.returning(PickUpReturn(kind: .away, since: now, seconds: 52 * 60), places: [place()],
                                        session: nil, sawPrivateWindow: false)
        XCTAssertEqual(card.top, "Back after 52 min")
        XCTAssertEqual(card.title, "You were in AuthSession.swift")
        XCTAssertEqual(card.sub, "From your last windows")
    }

    func testTheGoalOfTheSessionTheWorkBelongedTo() {
        var last = place()
        last.sessionGoal = "Q4 report"
        let card = PickUpCard.returning(PickUpReturn(kind: .away, since: now, seconds: 300), places: [last], session: nil, sawPrivateWindow: false)
        XCTAssertEqual(card.title, "You were working on “Q4 report”")
    }

    func testALongOrMissingTitleUsesTheApp() {
        let long = place(title: String(repeating: "a", count: 60))
        let card = PickUpCard.returning(PickUpReturn(kind: .away, since: now, seconds: 300), places: [long], session: nil, sawPrivateWindow: false)
        XCTAssertEqual(card.title, "You were in Xcode")
        let none = PickUpCard.returning(PickUpReturn(kind: .away, since: now, seconds: 300), places: [place(title: nil)], session: nil, sawPrivateWindow: false)
        XCTAssertEqual(none.title, "You were in Xcode")
    }

    func testAfterDriftingItGoesBackToOnePlace() {
        let card = PickUpCard.returning(PickUpReturn(kind: .drift(name: "x.com"), since: now, seconds: 6 * 60),
                                        places: [place(), place(terminal, "Terminal")],
                                        session: PickUpSessionInfo(isPaused: false), sawPrivateWindow: false)
        XCTAssertEqual(card.top, "x.com for 6 min")
        XCTAssertEqual(card.sub, "Your session is still running")
        XCTAssertEqual(card.primary, "Back to Xcode")
        XCTAssertEqual(card.rows.map(\.place.appName), ["Xcode"])
    }

    func testAPrivateWindowIsMentioned() {
        let card = PickUpCard.returning(PickUpReturn(kind: .away, since: now, seconds: 20 * 60), places: [place()], session: nil, sawPrivateWindow: true)
        XCTAssertEqual(card.sub, "Private windows are never remembered")
    }

    func testTheResumeLineOnlyWithAPausedSession() {
        func offer(_ session: PickUpSessionInfo?) -> String? {
            PickUpCard.returning(PickUpReturn(kind: .away, since: now, seconds: 300), places: [place()], session: session, sawPrivateWindow: false).resumeOffer
        }
        XCTAssertNil(offer(nil))
        XCTAssertNil(offer(PickUpSessionInfo(isPaused: false, minutesLeft: 14)))
        XCTAssertEqual(offer(PickUpSessionInfo(isPaused: true, minutesLeft: 14)), "Resume your session too · 14 min left")
        XCTAssertEqual(offer(PickUpSessionInfo(isPaused: true, minutesLeft: nil)), "Resume your session too")
    }

    func testDurations() {
        XCTAssertEqual(PickUpCard.duration(10), "1 min")
        XCTAssertEqual(PickUpCard.duration(59 * 60), "59 min")
        XCTAssertEqual(PickUpCard.duration(3600), "1 h")
        XCTAssertEqual(PickUpCard.duration(65 * 60), "1 h 5 min")
    }

    func testTheFailedCard() {
        let page = place(arc, "Arc", title: "Pull request #142", url: "https://github.com/x/1")
        let card = PickUpCard.failed(back: [place(), place(terminal, "Terminal")], failed: [page])
        XCTAssertEqual(card.top, "Back in place")
        XCTAssertEqual(card.title, "Xcode and Terminal are back")
        XCTAssertEqual(card.sub, "Arc couldn't reopen one page")
        XCTAssertEqual(card.primary, "Open in browser")
        XCTAssertEqual(card.secondary, "Skip")
        XCTAssertEqual(PickUpCard.failed(back: [place()], failed: [page]).title, "Xcode is back")
        XCTAssertNil(PickUpCard.failed(back: [], failed: [place()]).primary, "nothing to open in a browser")
    }

    func testTheMenusCard() throws {
        let card = PickUpCard.lastPlaces([place()], now: now)
        XCTAssertEqual(card.top, "Earlier today")
        XCTAssertEqual(card.title, "Where you left off")
        XCTAssertEqual(card.sub, "Your last places, newest first")
        XCTAssertEqual(card.rows.first?.detail, "at \(MomentText.time(place().at))")
        XCTAssertEqual(card.primary, "Pick up \(MomentText.time(place().at))")
        XCTAssertEqual(card.secondary, "Close")
        let older = PickUpPlace(bundleId: xcode, appName: "Xcode", title: nil, url: nil, at: now.addingTimeInterval(-3 * 24 * 3600))
        XCTAssertEqual(PickUpCard.lastPlaces([older], now: now).top, "Earlier this week")
    }

    // MARK: - Picking up

    func testThePlacesComeBackWithTheLastUsedInFront() async {
        let opener = FakeOpener()
        opener.windows = ["AuthSession.swift"]
        let page = place(arc, "Arc", title: "PR", url: "https://github.com/x/1")
        let shell = place(terminal, "Terminal", title: nil)
        let result = await PickUpRestore.run([place(), page, shell], with: opener)
        XCTAssertEqual(opener.calls, [
            "front \(terminal)",
            "front \(arc)", "page https://github.com/x/1 in \(arc)",
            "front \(xcode)", "raise AuthSession.swift",
        ])
        XCTAssertEqual(result.back.map(\.appName), ["Xcode", "Arc", "Terminal"])
        XCTAssertEqual(result.failed, [])
    }

    func testAWindowThatIsNotThereFallsBackToItsDocument() async {
        let opener = FakeOpener()
        _ = await PickUpRestore.run([place()], with: opener)
        XCTAssertEqual(opener.calls, ["front \(xcode)", "document AuthSession.swift"])
    }

    func testAPageAlreadyOpenIsNotOpenedAgain() async {
        let opener = FakeOpener()
        opener.pagesShowing = ["https://github.com/x/1"]
        _ = await PickUpRestore.run([place(arc, "Arc", title: "PR", url: "https://github.com/x/1")], with: opener)
        XCTAssertEqual(opener.calls, ["front \(arc)"])
    }

    func testAFailedPageOrAppIsReported() async {
        let opener = FakeOpener()
        opener.failingPages = true
        opener.failingApps = [terminal]
        let page = place(arc, "Arc", title: "PR", url: "https://github.com/x/1")
        let result = await PickUpRestore.run([place(), page, place(terminal, "Terminal")], with: opener)
        XCTAssertEqual(result.back.map(\.appName), ["Xcode"])
        XCTAssertEqual(result.failed.map(\.appName), ["Arc", "Terminal"])
    }

    // MARK: - The whole way through

    private struct Rig {
        let coordinator: PickUpCoordinator
        let opener: FakeOpener
        let presenter: FakePresenter
        let defaults: UserDefaults
    }

    /// A coordinator with `events` as its activity and Notes in front.
    private func rig(events: [PickUpEvent]? = nil, session: PickUpSessionInfo? = nil) throws -> (Rig, () -> Int) {
        let store = try defaults()
        let opener = FakeOpener()
        let presenter = FakePresenter()
        let coordinator = PickUpCoordinator(opener: opener, presenter: presenter, defaults: store)
        coordinator.readEvents = { _, _, _ in events ?? [self.event(self.terminal, "Terminal", title: "zsh", minutesAgo: 20), self.event(minutesAgo: 10)] }
        coordinator.session = { session }
        var resumes = 0
        coordinator.resumeSession = { resumes += 1 }
        coordinator.currentMoment = { self.moment(at: 400, front: self.snapshot("com.example.notes")) }
        return (Rig(coordinator: coordinator, opener: opener, presenter: presenter, defaults: store), { resumes })
    }

    private func comeBack(_ rig: Rig, at seconds: TimeInterval = 400) async {
        rig.coordinator.observe(moment(away: true, lastActive: 0))
        rig.coordinator.observe(moment(at: seconds, front: snapshot("com.example.notes")))
        await rig.coordinator.considering?.value
    }

    func testCameBackAndTheCardShows() async throws {
        let (rig, _) = try rig()
        await comeBack(rig)
        XCTAssertEqual(rig.presenter.shown.count, 1)
        XCTAssertEqual(rig.coordinator.card?.kind, .away)
        XCTAssertEqual(rig.coordinator.card?.places.map(\.appName), ["Xcode", "Terminal"])
    }

    func testEachSwitchTurnsItsMomentOff() async throws {
        let (rig, _) = try rig()
        rig.defaults.set(false, forKey: PickUpSettings.afterAway)
        await comeBack(rig)
        XCTAssertNil(rig.coordinator.card)
    }

    func testTheCardBringsBackOnlyAsManyAsSet() async throws {
        let (rig, _) = try rig()
        rig.defaults.set(1, forKey: PickUpSettings.bringBack)
        await comeBack(rig)
        XCTAssertEqual(rig.coordinator.card?.places.map(\.appName), ["Xcode"])
    }

    func testNoCardWithoutEnoughFocusBefore() async throws {
        let (rig, _) = try rig(events: [event(minutesAgo: 10, minutes: 1)])
        await comeBack(rig)
        XCTAssertNil(rig.coordinator.card)
    }

    func testNotNowMeansOncePerReturn() async throws {
        let (rig, _) = try rig()
        await comeBack(rig)
        rig.coordinator.close()
        rig.coordinator.observe(moment(at: 401, front: snapshot("com.example.notes")))
        await rig.coordinator.considering?.value
        XCTAssertEqual(rig.presenter.shown.count, 1)
        XCTAssertNil(rig.coordinator.card)
    }

    func testAnotherReturnSoonAfterGetsNoSecondCard() async throws {
        let (rig, _) = try rig()
        await comeBack(rig)
        rig.coordinator.close()
        rig.coordinator.currentMoment = { self.moment(at: 500, front: self.snapshot("com.example.notes")) }
        rig.coordinator.observe(moment(at: 500, front: snapshot("com.example.notes"), away: true, lastActive: 100))
        rig.coordinator.observe(moment(at: 450, front: snapshot("com.example.notes")))
        await rig.coordinator.considering?.value
        XCTAssertEqual(rig.presenter.shown.count, 1)
    }

    func testTheCardClosesOnceBackInThatWork() async throws {
        let (rig, _) = try rig()
        await comeBack(rig)
        rig.coordinator.observe(moment(at: 410, front: snapshot(terminal, classification: .focus)))
        XCTAssertNil(rig.coordinator.card)
        XCTAssertEqual(rig.presenter.closes, 1)
    }

    func testTheCardClosesAfterAWhile() async throws {
        let (rig, _) = try rig()
        await comeBack(rig)
        rig.coordinator.observe(moment(at: 400 + 119, front: snapshot("com.example.notes")))
        XCTAssertNotNil(rig.coordinator.card)
        rig.coordinator.observe(moment(at: 400 + 120, front: snapshot("com.example.notes")))
        XCTAssertNil(rig.coordinator.card)
    }

    func testTheCardClosesWhenACallOrAScreenComesUp() async throws {
        let (rig, _) = try rig()
        await comeBack(rig)
        rig.coordinator.observe(moment(at: 410, front: snapshot("com.example.notes"), call: 405))
        XCTAssertNil(rig.coordinator.card)
    }

    func testPickingUpResumesTheSessionWhenTicked() async throws {
        let (rig, resumes) = try rig(session: PickUpSessionInfo(isPaused: true, minutesLeft: 14))
        await comeBack(rig)
        await rig.coordinator.pressPrimary()
        XCTAssertEqual(resumes(), 1)
        XCTAssertNil(rig.coordinator.card)
        XCTAssertEqual(rig.opener.calls.filter { $0.hasPrefix("front") }, ["front \(terminal)", "front \(xcode)"])
    }

    func testPickingUpLeavesTheSessionWhenUnticked() async throws {
        let (rig, resumes) = try rig(session: PickUpSessionInfo(isPaused: true, minutesLeft: 14))
        await comeBack(rig)
        rig.coordinator.resumeTicked = false
        await rig.coordinator.pressPrimary()
        XCTAssertEqual(resumes(), 0)
    }

    func testAFailedPageShowsTheFailedCardAndOpensInTheBrowser() async throws {
        let (rig, _) = try rig(events: [event(arc, "Arc", title: "PR", url: "https://github.com/x/1", minutesAgo: 10), event(minutesAgo: 20)])
        rig.opener.failingPages = true
        await comeBack(rig)
        await rig.coordinator.pressPrimary()
        XCTAssertEqual(rig.coordinator.card?.kind, .failed)
        XCTAssertEqual(rig.coordinator.card?.title, "Xcode is back")
        await rig.coordinator.pressPrimary()
        XCTAssertEqual(rig.opener.defaultBrowserPages, ["https://github.com/x/1"])
        XCTAssertNil(rig.coordinator.card)
    }

    func testTheMenuListsTheLastPlacesAndPicksOne() async throws {
        let (rig, _) = try rig()
        await rig.coordinator.refreshMenuPlaces(now: now, force: true)
        XCTAssertEqual(rig.coordinator.menuPlaces.map(\.appName), ["Xcode", "Terminal"])
        await rig.coordinator.showLastPlaces(now: now)
        XCTAssertEqual(rig.coordinator.card?.kind, .menu)
        XCTAssertEqual(rig.coordinator.pickedPlaceID, xcode)
        rig.coordinator.pickedPlaceID = terminal
        await rig.coordinator.pressPrimary()
        XCTAssertEqual(rig.opener.calls.filter { $0.hasPrefix("front") }, ["front \(terminal)"])
    }

    func testForgettingEmptiesTheMenu() async throws {
        let (rig, _) = try rig()
        await rig.coordinator.refreshMenuPlaces(now: now, force: true)
        rig.coordinator.forgetPlaces(now: now)
        XCTAssertEqual(rig.coordinator.menuPlaces, [])
        await rig.coordinator.refreshMenuPlaces(now: now, force: true)
        XCTAssertEqual(rig.coordinator.menuPlaces, [])
    }

    func testTheShortcutPressesTheCardOrBringsUpTheLastPlaces() async throws {
        let (rig, _) = try rig()
        rig.coordinator.shortcutPressed(now: now)
        await rig.coordinator.considering?.value
        XCTAssertEqual(rig.coordinator.card?.kind, .menu)
        rig.coordinator.shortcutPressed(now: now)
        await rig.coordinator.considering?.value
        XCTAssertNil(rig.coordinator.card)
        XCTAssertEqual(rig.opener.calls.filter { $0.hasPrefix("front") }, ["front \(xcode)"])
    }

    func testNoDocumentNotesForOptedOutAppsOrPrivateWindows() throws {
        let (rig, _) = try rig()
        rig.coordinator.optedOut = { ["com.example.secret"] }
        rig.coordinator.observe(moment(front: snapshot(xcode, classification: .focus)))
        rig.coordinator.observe(moment(at: 1, front: snapshot(xcode, classification: .focus)))
        rig.coordinator.observe(moment(at: 2, front: snapshot("com.example.secret", classification: .focus)))
        rig.coordinator.observe(moment(at: 3, front: snapshot(arc, classification: .focus, url: "https://x.example/")))
        XCTAssertEqual(rig.opener.calls, ["note \(xcode)"], "once for the same window, never the others")
    }

    func testSettingsDefaults() throws {
        let store = try defaults()
        for key in [PickUpSettings.afterCall, PickUpSettings.afterAway, PickUpSettings.afterDrift, PickUpSettings.shortcut] {
            XCTAssertTrue(PickUpSettings.isOn(key, store), key)
        }
        XCTAssertEqual(PickUpSettings.bringBackCount(store), 3)
        XCTAssertNil(PickUpSettings.forgottenBefore(store))
        store.set(9, forKey: PickUpSettings.bringBack)
        XCTAssertEqual(PickUpSettings.bringBackCount(store), 3)
    }

    // MARK: - Private windows, from the browser to the store

    func testThePrivacyCopySaysWhatItDoes() {
        XCTAssertTrue(PrivacyNote.pickUp.contains("past 7 days"))
        XCTAssertTrue(PrivacyNote.pickUp.contains("only on this Mac"))
        XCTAssertTrue(PrivacyNote.pickUp.contains("Safari"), "the one browser it can't tell in")
    }

    func testThePrivateWindowCheckIsAskedOfEveryBrowserButSafari() throws {
        let chrome = try XCTUnwrap(BrowserTabReader.scriptSource(for: "com.google.Chrome", appName: "Google Chrome"))
        XCTAssertTrue(chrome.contains("mode of front window is not \"normal\""))
        let arcScript = try XCTUnwrap(BrowserTabReader.scriptSource(for: arc, appName: "Arc"))
        XCTAssertTrue(arcScript.contains("incognito of front window"))
        let safari = try XCTUnwrap(BrowserTabReader.scriptSource(for: "com.apple.Safari", appName: "Safari"))
        XCTAssertFalse(safari.contains("mode of front window"))
        XCTAssertTrue(safari.contains("URL of current tab of front window"))
    }

    func testTheExtensionsPrivateReportReachesTheTab() throws {
        let message = try ExtensionMessage.decode(Data(#"{"type":"tab","tab":{"url":"https://x.com/","title":"X","incognito":true}}"#.utf8))
        guard case .tab(let report) = message else { return XCTFail("\(message)") }
        XCTAssertEqual(report?.incognito, true)
        var client = ExtensionBridge.Client()
        client.browser = "com.google.Chrome"
        client.greeted = true
        client.tab = report
        let tab = ExtensionBridge.pickTab(from: [client], browser: "com.google.Chrome")
        XCTAssertEqual(tab?.isPrivate, true)
        XCTAssertEqual(tab?.url, "https://x.com/", "kept for blocking")
    }

    func testThePrivateWindowIsNeverWrittenDownButStillCountsForBlocking() throws {
        let rig = try FlowRig()
        let start = Date()
        rig.tab = ExtensionTab(url: "https://x.com/home", title: "Home / X", isPrivate: true)
        rig.tracker.record(FlowRig.safari, now: start)
        rig.tracker.record(FlowRig.safari, now: start.addingTimeInterval(30))
        XCTAssertEqual(rig.tracker.currentSnapshot?.url, "https://x.com/home")
        XCTAssertEqual(rig.tracker.currentSnapshot?.isPrivateWindow, true)
        rig.tracker.flush(now: start.addingTimeInterval(30))
        let events = try rig.context.fetch(FetchDescriptor<ActivityEvent>())
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events.first?.url)
        XCTAssertNil(events.first?.windowTitle)
        XCTAssertEqual(events.first?.duration ?? 0, 30, accuracy: 0.5)
    }

    // MARK: - Reading

    func testTheStoreIsReadOffTheMainThreadWithTheSessionGoal() async throws {
        let container = try FlowRig.makeContainer()
        let context = container.mainContext
        let session = Session(startedAt: now.addingTimeInterval(-3600))
        session.goal = "Q4 report"
        context.insert(session)
        let work = ActivityEvent(startedAt: now.addingTimeInterval(-1200), endedAt: now.addingTimeInterval(-600),
                                 bundleIdentifier: xcode, appName: "Xcode", windowTitle: "A.swift", session: session)
        work.classification = .focus
        let idle = ActivityEvent(startedAt: now.addingTimeInterval(-500), endedAt: now.addingTimeInterval(-400),
                                 bundleIdentifier: terminal, appName: "Terminal")
        idle.classification = .neutral
        context.insert(work)
        context.insert(idle)
        try context.save()

        let store = StatsStore(container: container)
        let focused = await store.pickUpEvents(from: now.addingTimeInterval(-7200), before: now, focusOnly: true)
        XCTAssertEqual(focused.map(\.appName), ["Xcode"])
        XCTAssertEqual(focused.first?.sessionGoal, "Q4 report")
        let all = await store.pickUpEvents(from: now.addingTimeInterval(-7200), before: now, focusOnly: false)
        XCTAssertEqual(all.map(\.appName), ["Terminal", "Xcode"], "newest first")
    }
}
