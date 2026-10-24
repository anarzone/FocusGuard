import Foundation

/// The calm page a paused tab shows (Resources/paused.html). It's a file in
/// the app, so it works offline and nothing goes over the network. The app
/// passes everything in the fragment and changes the fragment when the
/// state changes; the page's buttons call `FocusGuardURL` links.
enum PausedPage {
    enum State: String {
        /// During a session: "Back to …" / "Reopen after the session".
        case paused
        /// The tab reopens when the session ends: "Don't reopen it".
        case queued
        /// The session ended: "Take a 10-minute break" / "Reopen x.com".
        case over
        /// A daily limit ran out: paused until midnight.
        case limit
    }

    static var fileURL: URL? { Bundle.main.url(forResource: "paused", withExtension: "html") }

    static func url(base: URL, for tab: PausedTab, state: State) -> URL {
        var fields: [(String, String)] = [
            ("id", tab.id),
            ("host", tab.host),
            ("url", tab.originalURL.absoluteString),
            ("state", state.rawValue),
        ]
        if let ends = tab.endsAt { fields.append(("ends", String(Int(ends.timeIntervalSince1970)))) }
        if let back = tab.backTo { fields.append(("back", back)) }
        if case .limit(let minutes) = tab.reason { fields.append(("minutes", String(minutes))) }
        let fragment = fields.map { "\($0)=\(encode($1))" }.joined(separator: "&")
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.percentEncodedFragment = fragment
        return components?.url ?? base
    }

    /// Unreserved URL characters only, so values can't break the fragment
    /// or the AppleScript string they travel in.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    static func newID() -> String { UUID().uuidString.lowercased() }

    /// Ids are made by `newID`; anything else coming back through a link is refused.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// What a paused tab's URL contains, to find it again.
    static func idMarker(_ id: String) -> String { "id=\(id)&" }
}

/// A browser tab FocusGuard pointed at the paused page.
struct PausedTab: Equatable {
    enum Reason: Equatable {
        /// A drift in a session; the tab is paused until it ends.
        case session
        /// A daily limit of this many minutes ran out; paused until midnight.
        case limit(minutes: Int)
    }

    let id: String
    /// The browser's bundle id.
    let browser: String
    /// "x.com"
    let host: String
    /// Where the tab was, to reopen it.
    let originalURL: URL
    let reason: Reason
    /// When the session is planned to end; nil when open-ended.
    let endsAt: Date?
    /// The app "Back to …" returns to.
    let backTo: String?
    /// "Reopen after the session" was picked.
    var reopensAfterSession = false
}

/// Free "Pause the tab" (blocking level 1). When the block screen comes up
/// over a site, the browser's front tab is pointed at the paused page, so
/// the site is gone when you come back to the browser.
/// - A pass, "It's for work" or extra time on a limit put the tab back.
/// - "Reopen after the session" queues the tab; "Don't reopen it" undoes that.
/// - When the session ends, queued tabs reopen and the others offer a break
///   or the site.
@MainActor
final class TabPauseCoordinator {
    /// Off when another blocking level takes over (Pro, later).
    var isEnabled = true
    /// Tabs paused and not yet reopened, by id.
    private(set) var tabs: [String: PausedTab] = [:]
    /// The tab paused for the block screen that's up now.
    private(set) var lastPausedID: String?
    /// Pauses whose script hasn't answered yet.
    private var inFlight: Set<String> = []
    /// Of those, the ones let through meanwhile: put back as soon as they land.
    private var undoWhenDone: Set<String> = []

    private let pauser: TabPauser
    private let page: URL?

    init(pauser: TabPauser, page: URL? = PausedPage.fileURL) {
        self.pauser = pauser
        self.page = page
    }

    /// The block screen came up over `snapshot`: pause its tab if it's a
    /// web page in a browser we can reach.
    func blockShown(_ reason: PausedTab.Reason, snapshot: ActivitySnapshot?, endsAt: Date?, backTo: String?) {
        lastPausedID = nil
        guard isEnabled, let page, let snapshot, pauser.canPause(browser: snapshot.bundleIdentifier),
              let original = snapshot.url.flatMap(URL.init(string:)),
              ["http", "https"].contains(original.scheme?.lowercased() ?? ""),
              let host = BlockRequest.displayHost(snapshot.url) else { return }

        let tab = PausedTab(id: PausedPage.newID(), browser: snapshot.bundleIdentifier, host: host,
                            originalURL: original, reason: reason,
                            endsAt: reason == .session ? endsAt : nil, backTo: backTo)
        let state: PausedPage.State = reason == .session ? .paused : .limit
        lastPausedID = tab.id
        inFlight.insert(tab.id)
        pauser.pauseFrontTab(in: tab.browser, showing: host, with: PausedPage.url(base: page, for: tab, state: state)) { [weak self] done in
            guard let self else { return }
            self.inFlight.remove(tab.id)
            let undo = self.undoWhenDone.remove(tab.id) != nil
            if done {
                self.tabs[tab.id] = tab
                if undo { self.reopen(tab.id) }
            } else if self.lastPausedID == tab.id {
                self.lastPausedID = nil
            }
        }
    }

    /// The block screen let the site through (a pass, "It's for work",
    /// extra time): put the tab it paused back.
    func letThrough() {
        guard let id = lastPausedID else { return }
        lastPausedID = nil
        if inFlight.contains(id) {
            undoWhenDone.insert(id)
        } else {
            reopen(id)
        }
    }

    /// "Reopen after the session" (true) or "Don't reopen it" (false).
    func setReopensAfterSession(_ reopens: Bool, pauseID: String) {
        guard var tab = tabs[pauseID], tab.reason == .session, let page else { return }
        tab.reopensAfterSession = reopens
        tabs[pauseID] = tab
        pauser.redirectTab(showing: pauseID, in: tab.browser,
                           to: PausedPage.url(base: page, for: tab, state: reopens ? .queued : .paused))
    }

    /// The browser a paused tab is in, to bring it back to the front.
    func browser(for pauseID: String) -> String? { tabs[pauseID]?.browser }

    /// The session ended: queued tabs reopen; the rest show "session over".
    func sessionEnded() {
        lastPausedID = nil
        for tab in tabs.values where tab.reason == .session {
            if tab.reopensAfterSession {
                pauser.redirectTab(showing: tab.id, in: tab.browser, to: tab.originalURL)
            } else if let page {
                pauser.redirectTab(showing: tab.id, in: tab.browser, to: PausedPage.url(base: page, for: tab, state: .over))
            }
            tabs[tab.id] = nil
        }
    }

    private func reopen(_ id: String) {
        guard let tab = tabs.removeValue(forKey: id) else { return }
        pauser.redirectTab(showing: id, in: tab.browser, to: tab.originalURL)
    }
}
