import Darwin
import SwiftData
import XCTest
@testable import FocusGuard

// MARK: - Slack sign-in and calls

@MainActor
final class SlackAccountTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var slack: FakeSlack!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "SlackAccountTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        slack = FakeSlack()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func make(tokens: SlackAccount.Tokens? = nil) -> (SlackAccount, MemoryTokenStore) {
        let store = MemoryTokenStore(tokens.map(MemoryTokenStore.encode))
        let account = SlackAccount(clientID: "123.456", keychain: store, defaults: defaults, now: { [unowned self] in self.clock })
        account.send = { [slack] in try await slack!.send($0) }
        account.openURL = { [slack] in slack?.opened.append($0) }
        return (account, store)
    }

    private func sampleTokens(expiresIn: TimeInterval = 12 * 3600, refreshedAgo: TimeInterval = 0) -> SlackAccount.Tokens {
        SlackAccount.Tokens(access: "xoxe.xoxp-old", refresh: "xoxe-1-old", expiresAt: clock.addingTimeInterval(expiresIn),
                            refreshedAt: clock.addingTimeInterval(-refreshedAgo))
    }

    // MARK: PKCE and the authorize URL

    func testChallengeIsS256OfTheVerifier() {
        // RFC 7636, appendix B.
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAuthorizeURLAsksForTheTwoUserScopesWithAChallengeAndNoSecret() throws {
        let url = try XCTUnwrap(SlackAccount.authorizeURL(clientID: "123.456", verifier: "the-verifier", state: "st"))
        XCTAssertEqual(url.host, "slack.com")
        XCTAssertEqual(url.path, "/oauth/v2/authorize")
        let items = query(url)
        XCTAssertEqual(items, [
            "client_id": "123.456",
            "user_scope": "users.profile:write,dnd:write",
            "redirect_uri": "focusguard://slack-auth",
            "state": "st",
            "code_challenge": PKCE.challenge(for: "the-verifier"),
            "code_challenge_method": "S256",
        ])
    }

    func testConnectOpensTheBrowserAndOnlyItsOwnStateComesBack() async throws {
        let (account, store) = make()
        account.connect()
        let opened = try XCTUnwrap(slack.opened.first)
        let state = try XCTUnwrap(query(opened)["state"])
        XCTAssertTrue(account.isWaiting)

        await account.finishConnect(code: "code", state: "someone-else", error: nil)
        XCTAssertTrue(slack.requests.isEmpty)
        XCTAssertTrue(account.isWaiting)

        slack.answers["oauth.v2.access"] = [#"""
            {"ok":true,"app_id":"A1","team":{"id":"T1","name":"Acme"},
             "authed_user":{"id":"U1","scope":"users.profile:write,dnd:write","access_token":"xoxe.xoxp-1",
                            "expires_in":43200,"refresh_token":"xoxe-1-r1","token_type":"user"}}
            """#]
        await account.finishConnect(code: "the-code", state: state, error: nil)

        let exchange = try XCTUnwrap(slack.requests.first)
        XCTAssertEqual(exchange.url?.absoluteString, "https://slack.com/api/oauth.v2.access")
        XCTAssertEqual(exchange.httpMethod, "POST")
        XCTAssertNil(exchange.value(forHTTPHeaderField: "Authorization"))
        let sent = form(exchange)
        XCTAssertEqual(sent["code"], "the-code")
        XCTAssertEqual(sent["client_id"], "123.456")
        XCTAssertEqual(sent["redirect_uri"], "focusguard://slack-auth")
        XCTAssertNil(sent["client_secret"])
        // The verifier sent is the one the challenge in the browser came from.
        XCTAssertEqual(PKCE.challenge(for: try XCTUnwrap(sent["code_verifier"])), query(opened)["code_challenge"])

        XCTAssertTrue(account.isConnected)
        XCTAssertFalse(account.isWaiting)
        XCTAssertEqual(account.teamName, "Acme")
        let saved = try XCTUnwrap(store.decoded)
        XCTAssertEqual(saved.access, "xoxe.xoxp-1")
        XCTAssertEqual(saved.refresh, "xoxe-1-r1")
        XCTAssertEqual(saved.expiresAt, clock.addingTimeInterval(43200))
    }

    func testCancellingOnSlacksPageIsNoProblemButAFailedExchangeIs() async throws {
        let (account, _) = make()
        account.connect()
        var state = try XCTUnwrap(query(try XCTUnwrap(slack.opened.last))["state"])
        await account.finishConnect(code: nil, state: state, error: "access_denied")
        XCTAssertNil(account.problem)
        XCTAssertFalse(account.isConnected)

        account.connect()
        state = try XCTUnwrap(query(try XCTUnwrap(slack.opened.last))["state"])
        slack.answers["oauth.v2.access"] = [#"{"ok":false,"error":"invalid_code_verifier"}"#]
        await account.finishConnect(code: "c", state: state, error: nil)
        XCTAssertEqual(account.problem, .connectFailed)
        XCTAssertFalse(account.isConnected)
    }

    func testAnAnswerAfterTenMinutesIsIgnored() {
        let pending = SlackAccount.Pending(verifier: "v", state: "s", startedAt: clock)
        XCTAssertTrue(SlackAccount.isExpected(state: "s", pending: pending, now: clock.addingTimeInterval(9 * 60)))
        XCTAssertFalse(SlackAccount.isExpected(state: "s", pending: pending, now: clock.addingTimeInterval(10 * 60)))
        XCTAssertFalse(SlackAccount.isExpected(state: "t", pending: pending, now: clock))
        XCTAssertFalse(SlackAccount.isExpected(state: nil, pending: pending, now: clock))
    }

    // MARK: Tokens

    func testRefreshesShortlyBeforeTheAccessTokenRunsOutOrOnceTheRefreshTokenAges() {
        XCTAssertFalse(SlackAccount.needsRefresh(sampleTokens(expiresIn: 3600), now: clock))
        XCTAssertTrue(SlackAccount.needsRefresh(sampleTokens(expiresIn: 4 * 60), now: clock))
        XCTAssertTrue(SlackAccount.needsRefresh(sampleTokens(expiresIn: -60), now: clock))
        XCTAssertTrue(SlackAccount.needsRefresh(sampleTokens(refreshedAgo: 20 * 86_400), now: clock))
        XCTAssertFalse(SlackAccount.needsRefresh(sampleTokens(refreshedAgo: 19 * 86_400), now: clock))
        var fixed = sampleTokens(expiresIn: -60)
        fixed.refresh = nil
        XCTAssertFalse(SlackAccount.needsRefresh(fixed, now: clock))
    }

    func testTokensComeFromAuthedUserOnSignInAndFromTheTopOnRefresh() throws {
        let signIn = try JSONDecoder().decode(SlackAccount.OAuthAnswer.self, from: Data(#"""
            {"ok":true,"team":{"id":"T1","name":"Acme"},
             "authed_user":{"id":"U1","access_token":"xoxe.xoxp-1","expires_in":43200,"refresh_token":"xoxe-1-a","token_type":"user"}}
            """#.utf8))
        XCTAssertEqual(SlackAccount.parseTokens(from: signIn, now: clock),
                       SlackAccount.Tokens(access: "xoxe.xoxp-1", refresh: "xoxe-1-a",
                                           expiresAt: clock.addingTimeInterval(43200), refreshedAt: clock))

        let refresh = try JSONDecoder().decode(SlackAccount.OAuthAnswer.self, from: Data(#"""
            {"ok":true,"access_token":"xoxe.xoxp-2","token_type":"user","expires_in":43200,"refresh_token":"xoxe-1-b"}
            """#.utf8))
        XCTAssertEqual(SlackAccount.parseTokens(from: refresh, now: clock)?.access, "xoxe.xoxp-2")
        XCTAssertEqual(SlackAccount.parseTokens(from: refresh, now: clock)?.refresh, "xoxe-1-b")

        let bot = try JSONDecoder().decode(SlackAccount.OAuthAnswer.self, from: Data(#"""
            {"ok":true,"access_token":"xoxb-1","token_type":"bot"}
            """#.utf8))
        XCTAssertNil(SlackAccount.parseTokens(from: bot, now: clock))
    }

    func testAnOldAccessTokenIsRefreshedWithoutASecretBeforeTheCall() async throws {
        let (account, store) = make(tokens: sampleTokens(expiresIn: 60))
        slack.answers["oauth.v2.access"] = [#"{"ok":true,"access_token":"xoxe.xoxp-new","token_type":"user","expires_in":43200,"refresh_token":"xoxe-1-new"}"#]
        let set = await account.setStatus("Focusing", emoji: ":headphones:", expires: clock.addingTimeInterval(1500))
        XCTAssertTrue(set)
        XCTAssertEqual(slack.methods, ["oauth.v2.access", "users.profile.set"])
        XCTAssertEqual(form(slack.requests[0]), ["client_id": "123.456", "grant_type": "refresh_token", "refresh_token": "xoxe-1-old"])
        XCTAssertEqual(slack.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer xoxe.xoxp-new")
        XCTAssertEqual(store.decoded?.refresh, "xoxe-1-new")
        XCTAssertEqual(store.decoded?.refreshedAt, clock)
    }

    func testAnExpiredTokenAnswerRefreshesAndTriesOnceMore() async {
        let (account, _) = make(tokens: sampleTokens())
        slack.answers["users.profile.set"] = [#"{"ok":false,"error":"token_expired"}"#, #"{"ok":true}"#]
        slack.answers["oauth.v2.access"] = [#"{"ok":true,"access_token":"xoxe.xoxp-new","token_type":"user","expires_in":43200,"refresh_token":"xoxe-1-new"}"#]
        let cleared = await account.clearStatus()
        XCTAssertTrue(cleared)
        XCTAssertEqual(slack.methods, ["users.profile.set", "oauth.v2.access", "users.profile.set"])
    }

    func testARejectedRefreshSignsOut() async {
        let (account, store) = make(tokens: sampleTokens(expiresIn: -60))
        slack.answers["oauth.v2.access"] = [#"{"ok":false,"error":"invalid_refresh_token"}"#]
        let snoozed = await account.snooze(minutes: 25)
        XCTAssertFalse(snoozed)
        XCTAssertFalse(account.isConnected)
        XCTAssertEqual(account.problem, .signedOut)
        XCTAssertNil(store.token)
        XCTAssertEqual(slack.methods, ["oauth.v2.access"])
    }

    func testOfflineKeepsTheSignIn() async {
        let (account, store) = make(tokens: sampleTokens(expiresIn: 60))
        slack.offline = true
        let set = await account.setStatus("Focusing", emoji: "", expires: clock)
        XCTAssertFalse(set)
        XCTAssertTrue(account.isConnected)
        XCTAssertNotNil(store.token)
        XCTAssertNil(account.problem)
    }

    // MARK: Requests

    func testStatusRequestSetsTextEmojiAndExpiry() throws {
        let request = try XCTUnwrap(SlackAccount.profileRequest(text: "Focusing until 19:32", emoji: ":headphones:",
                                                                expires: Date(timeIntervalSince1970: 1_800_001_500), token: "xoxp-1"))
        XCTAssertEqual(request.url?.absoluteString, "https://slack.com/api/users.profile.set")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer xoxp-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        XCTAssertEqual(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self),
                       #"{"profile":{"status_emoji":":headphones:","status_expiration":1800001500,"status_text":"Focusing until 19:32"}}"#)

        let clear = try XCTUnwrap(SlackAccount.profileRequest(text: "", emoji: "", expires: nil, token: "xoxp-1"))
        XCTAssertEqual(String(decoding: try XCTUnwrap(clear.httpBody), as: UTF8.self),
                       #"{"profile":{"status_emoji":"","status_expiration":0,"status_text":""}}"#)
    }

    func testSnoozeRequestsAreFormsWithTheUserToken() {
        let snooze = SlackAccount.formRequest("dnd.setSnooze", ["num_minutes": "25"], token: "xoxp-1")
        XCTAssertEqual(snooze.url?.absoluteString, "https://slack.com/api/dnd.setSnooze")
        XCTAssertEqual(snooze.value(forHTTPHeaderField: "Authorization"), "Bearer xoxp-1")
        XCTAssertEqual(snooze.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(snooze.httpBody, Data("num_minutes=25".utf8))
        XCTAssertEqual(SlackAccount.formRequest("dnd.endSnooze", [:], token: "t").url?.absoluteString,
                       "https://slack.com/api/dnd.endSnooze")
    }

    func testDisconnectForgetsAndRevokes() async {
        let (account, store) = make(tokens: sampleTokens())
        defaults.set("Acme", forKey: SlackAccount.teamKey)
        await account.disconnect()
        XCTAssertFalse(account.isConnected)
        XCTAssertNil(account.teamName)
        XCTAssertNil(store.token)
        XCTAssertEqual(slack.methods, ["auth.revoke"])
        XCTAssertEqual(slack.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer xoxe.xoxp-old")
    }

    func testWithoutAClientIDSlackIsHidden() {
        let account = SlackAccount(clientID: nil, keychain: MemoryTokenStore(MemoryTokenStore.encode(sampleTokens())), defaults: defaults)
        XCTAssertFalse(account.isConfigured)
        XCTAssertFalse(account.isConnected)
        XCTAssertNil(StatusSync.infoValue("FGNoSuchKey"))
    }

    // MARK: The redirect

    func testTheRedirectLinkCarriesCodeAndState() throws {
        let link = try XCTUnwrap(URL(string: "focusguard://slack-auth?code=1.2.abc&state=xyz"))
        XCTAssertEqual(FocusGuardURL(link), .slackAuth(code: "1.2.abc", state: "xyz", error: nil))
        let denied = try XCTUnwrap(URL(string: "focusguard://slack-auth?error=access_denied&state=xyz"))
        XCTAssertEqual(FocusGuardURL(denied), .slackAuth(code: nil, state: "xyz", error: "access_denied"))
        XCTAssertNil(FocusGuardURL(try XCTUnwrap(URL(string: "focusguard://slack-auth?code=abc"))))
        let route = FocusGuardURL.slackAuth(code: "abc", state: "xyz", error: nil)
        XCTAssertEqual(FocusGuardURL(route.url), route)
    }

    // MARK: Helpers

    private func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
    }

    private func form(_ request: URLRequest) -> [String: String] {
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return Dictionary(uniqueKeysWithValues: (URLComponents(string: "x:/?" + body)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
    }
}

// MARK: - Following sessions

@MainActor
final class StatusSyncTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var container: ModelContainer!
    private var context: ModelContext!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var slack: FakeSlack!
    private var current: Session?

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "StatusSyncTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self, DailyLimit.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = ModelContext(container)
        slack = FakeSlack()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        current = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    private func make(pro: Bool = true, connected: Bool = true) -> StatusSync {
        let entitlements = Entitlements(defaults: defaults)
        if pro { entitlements.startTrialIfNeeded(for: .statusSync) }
        let tokens = SlackAccount.Tokens(access: "xoxp-1", refresh: "xoxe-1", expiresAt: clock.addingTimeInterval(12 * 3600),
                                         refreshedAt: clock)
        let account = SlackAccount(clientID: "123.456", keychain: MemoryTokenStore(connected ? MemoryTokenStore.encode(tokens) : nil),
                                   defaults: defaults, now: { [unowned self] in self.clock })
        account.send = { [slack] in try await slack!.send($0) }
        let sync = StatusSync(slack: account, discord: DiscordPresence(applicationID: nil, directories: []),
                              entitlements: entitlements, defaults: defaults, now: { [unowned self] in self.clock })
        sync.isShipped = true
        sync.currentSession = { [unowned self] in self.current }
        return sync
    }

    private func startSession(minutes: Int? = 25) -> Session {
        let session = Session(startedAt: clock, plannedDurationMinutes: minutes)
        context.insert(session)
        current = session
        return session
    }

    private func endSession(_ session: Session) {
        session.endedAt = clock
        current = nil
    }

    func testAStartedSessionSetsTheStatusAndSnoozesUntilItsEnd() async throws {
        let sync = make()
        let session = startSession()
        sync.update()
        await sync.settle()

        XCTAssertEqual(slack.methods, ["users.profile.set", "dnd.setSnooze"])
        let profile = try XCTUnwrap(slack.json(0)?["profile"] as? [String: Any])
        let end = clock.addingTimeInterval(25 * 60)
        XCTAssertEqual(profile["status_text"] as? String, StatusText.render(StatusSettings.defaultText, end: end))
        XCTAssertEqual(profile["status_emoji"] as? String, ":headphones:")
        XCTAssertEqual(profile["status_expiration"] as? Int, Int(end.timeIntervalSince1970))
        XCTAssertEqual(slack.form(1), ["num_minutes": "25"])
        XCTAssertEqual(sync.posted?.sessionID, session.id)
        XCTAssertEqual(sync.posted?.end, end)
        XCTAssertNotNil(sync.posted?.statusText)
        XCTAssertEqual(sync.posted?.snoozed, true)
    }

    func testNothingIsSentOnFreeOrWithoutSlack() async {
        let free = make(pro: false)
        _ = startSession()
        free.update()
        await free.settle()
        XCTAssertTrue(slack.requests.isEmpty)

        let notConnected = make(connected: false)
        notConnected.update()
        await notConnected.settle()
        XCTAssertTrue(slack.requests.isEmpty)
    }

    func testFiveMoreMinutesMovesTheStatusAndTheSnooze() async throws {
        let sync = make()
        let session = startSession()
        sync.update()
        await sync.settle()
        slack.requests = []

        clock = clock.addingTimeInterval(20 * 60)
        session.plannedDurationMinutes = 30
        sync.update()
        await sync.settle()
        XCTAssertEqual(slack.methods, ["users.profile.set", "dnd.setSnooze"])
        let profile = try XCTUnwrap(slack.json(0)?["profile"] as? [String: Any])
        XCTAssertEqual(profile["status_expiration"] as? Int, Int(session.startedAt.timeIntervalSince1970) + 30 * 60)
        XCTAssertEqual(slack.form(1), ["num_minutes": "10"])

        // Nothing changed: nothing is sent.
        slack.requests = []
        sync.update()
        await sync.settle()
        XCTAssertTrue(slack.requests.isEmpty)
    }

    func testEndingEarlyTakesOffWhatWasSet() async throws {
        let sync = make()
        let session = startSession()
        sync.update()
        await sync.settle()
        slack.requests = []

        clock = clock.addingTimeInterval(10 * 60)
        endSession(session)
        sync.update()
        await sync.settle()
        XCTAssertEqual(slack.methods, ["users.profile.set", "dnd.endSnooze"])
        let profile = try XCTUnwrap(slack.json(0)?["profile"] as? [String: Any])
        XCTAssertEqual(profile["status_text"] as? String, "")
        XCTAssertEqual(profile["status_emoji"] as? String, "")
        XCTAssertNil(sync.posted)
        XCTAssertNil(defaults.data(forKey: StatusSync.postedKey))
    }

    func testASessionThatRanToItsEndLeavesSlackToClearItself() async {
        let sync = make()
        let session = startSession()
        sync.update()
        await sync.settle()
        slack.requests = []

        clock = clock.addingTimeInterval(25 * 60)
        endSession(session)
        sync.update()
        await sync.settle()
        XCTAssertTrue(slack.requests.isEmpty)
        XCTAssertNil(sync.posted)
    }

    func testAStatusThatWasNeverSetIsNeverCleared() async {
        let sync = make()
        let session = startSession()
        slack.answers["users.profile.set"] = [#"{"ok":false,"error":"ratelimited"}"#]
        slack.answers["dnd.setSnooze"] = [#"{"ok":false,"error":"snooze_failed"}"#]
        sync.update()
        await sync.settle()
        XCTAssertNil(sync.posted)
        slack.requests = []

        clock = clock.addingTimeInterval(5 * 60)
        endSession(session)
        sync.update()
        await sync.settle()
        XCTAssertTrue(slack.requests.isEmpty)
    }

    func testTurningSlackOffMidSessionClearsAndOnSetsAgain() async {
        let sync = make()
        _ = startSession()
        sync.update()
        await sync.settle()
        slack.requests = []

        defaults.set(false, forKey: StatusSettings.slack)
        sync.update()
        await sync.settle()
        XCTAssertEqual(slack.methods, ["users.profile.set", "dnd.endSnooze"])
        XCTAssertNil(sync.posted?.statusText)

        slack.requests = []
        defaults.set(true, forKey: StatusSettings.slack)
        defaults.set(false, forKey: StatusSettings.slackSnooze)
        sync.update()
        await sync.settle()
        XCTAssertEqual(slack.methods, ["users.profile.set"])
    }

    func testAnEditedStatusIsSentAgain() async throws {
        let sync = make()
        _ = startSession()
        sync.update()
        await sync.settle()
        slack.requests = []

        defaults.set("Heads down till {end}", forKey: StatusSettings.slackText)
        sync.update()
        await sync.settle()
        XCTAssertEqual(slack.methods, ["users.profile.set"])
        let profile = try XCTUnwrap(slack.json(0)?["profile"] as? [String: Any])
        XCTAssertTrue((profile["status_text"] as? String)?.hasPrefix("Heads down till ") == true)
    }

    func testASessionThatEndedWhileClosedIsTakenOffAtLaunch() async {
        let first = make()
        let session = startSession()
        first.update()
        await first.settle()
        slack.requests = []

        // Quit; the session ends early before FocusGuard opens again.
        clock = clock.addingTimeInterval(5 * 60)
        endSession(session)
        let relaunched = make()
        XCTAssertEqual(relaunched.posted?.sessionID, session.id)
        relaunched.update()
        await relaunched.settle()
        XCTAssertEqual(slack.methods, ["users.profile.set", "dnd.endSnooze"])
        XCTAssertNil(relaunched.posted)
    }

    func testDisconnectingTakesOffTheStatusFirst() async {
        let sync = make()
        _ = startSession()
        sync.update()
        await sync.settle()
        slack.requests = []

        sync.disconnectSlack()
        await sync.settle()
        XCTAssertEqual(slack.methods, ["users.profile.set", "dnd.endSnooze", "auth.revoke"])
        XCTAssertFalse(sync.slack.isConnected)
    }

    func testOpenEndedSessionsHoldTheUsualLength() throws {
        let session = startSession(minutes: nil)
        session.pausedSeconds = 120
        let focus = try XCTUnwrap(StatusSync.sessionFocus(session, usualMinutes: 40))
        XCTAssertTrue(focus.isOpenEnded)
        XCTAssertEqual(focus.end, clock.addingTimeInterval(42 * 60))
        XCTAssertEqual(StatusSync.activity(for: focus), DiscordIPC.Activity(details: "Focusing", start: clock))

        let planned = try XCTUnwrap(StatusSync.sessionFocus(startSession(minutes: 25), usualMinutes: 40))
        XCTAssertEqual(StatusSync.activity(for: planned), DiscordIPC.Activity(details: "Focusing", end: clock.addingTimeInterval(25 * 60)))

        session.endedAt = clock
        XCTAssertNil(StatusSync.sessionFocus(session, usualMinutes: 40))
    }

    func testSnoozeMinutesRoundToTheEnd() {
        XCTAssertEqual(StatusSync.snoozeMinutes(until: clock.addingTimeInterval(25 * 60), now: clock), 25)
        XCTAssertEqual(StatusSync.snoozeMinutes(until: clock.addingTimeInterval(20), now: clock), 1)
        XCTAssertEqual(StatusSync.snoozeMinutes(until: clock.addingTimeInterval(90 * 60 + 20), now: clock), 90)
        XCTAssertNil(StatusSync.snoozeMinutes(until: clock, now: clock))
    }

    func testStatusTextPutsInTheEndTimeAndKeepsToSlacksLimit() {
        let end = Date(timeIntervalSince1970: 1_800_000_000 + 41_520)   // 19:32 UTC
        let gb = Locale(identifier: "en_GB")
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        XCTAssertEqual(StatusText.render("Focusing until {end}", end: end, locale: gb, timeZone: utc), "Focusing until 19:32")
        XCTAssertEqual(StatusText.render("  ", end: end, locale: gb, timeZone: utc), "Focusing until 19:32")
        XCTAssertEqual(StatusText.render("Deep work", end: end, locale: gb, timeZone: utc), "Deep work")
        XCTAssertEqual(StatusText.render(String(repeating: "a", count: 150), end: end).count, 100)
    }

    func testDefaultsSlackOnDiscordOff() {
        XCTAssertTrue(StatusSettings.isOn(StatusSettings.slack, defaults))
        XCTAssertTrue(StatusSettings.isOn(StatusSettings.slackStatus, defaults))
        XCTAssertTrue(StatusSettings.isOn(StatusSettings.slackSnooze, defaults))
        XCTAssertFalse(StatusSettings.isOn(StatusSettings.discord, defaults))
        XCTAssertEqual(StatusSettings.text(defaults), "Focusing until {end}")
    }

    func testPrivacyStatementNamesSlackOnceItsBuiltIn() {
        XCTAssertTrue(PrivacyStatement.networkStatement(slack: true).contains("Jira and Slack"))
        XCTAssertFalse(PrivacyStatement.networkStatement(slack: false).contains("Slack"))
    }
}

// MARK: - Discord's IPC

final class DiscordPresenceTests: XCTestCase {
    func testFramesAreLittleEndianOpcodeAndLengthThenJSON() throws {
        let frame = DiscordIPC.Frame(opcode: .frame, payload: Data(#"{"a":1}"#.utf8))
        let bytes = [UInt8](DiscordIPC.encode(frame))
        XCTAssertEqual(Array(bytes.prefix(8)), [1, 0, 0, 0, 7, 0, 0, 0])
        XCTAssertEqual(Array(bytes.dropFirst(8)), Array(#"{"a":1}"#.utf8))

        // Two frames back to back, then half of a third.
        var stream = DiscordIPC.encode(frame) + DiscordIPC.encode(DiscordIPC.Frame(opcode: .ping, payload: Data("{}".utf8)))
        stream += Data([3, 0, 0, 0, 9, 0])
        let first = try XCTUnwrap(try DiscordIPC.decode(stream))
        XCTAssertEqual(first.frame, frame)
        XCTAssertEqual(first.length, 15)
        stream.removeFirst(first.length)
        let second = try XCTUnwrap(try DiscordIPC.decode(stream))
        XCTAssertEqual(second.frame.opcode, .ping)
        stream.removeFirst(second.length)
        XCTAssertNil(try DiscordIPC.decode(stream))
    }

    func testAFrameFromAFixtureDecodes() throws {
        // A READY dispatch as Discord sends it: opcode 1, length 0x2F.
        let json = #"{"cmd":"DISPATCH","data":{"v":1},"evt":"READY"}"#
        XCTAssertEqual(json.utf8.count, 0x2F)
        let fixture = Data([0x01, 0x00, 0x00, 0x00, 0x2F, 0x00, 0x00, 0x00]) + Data(json.utf8)
        let decoded = try XCTUnwrap(try DiscordIPC.decode(fixture))
        XCTAssertEqual(decoded.frame.opcode, .frame)
        XCTAssertTrue(DiscordIPC.isReady(decoded.frame))
        XCTAssertFalse(DiscordIPC.isError(decoded.frame))
    }

    func testUnknownOpcodesAndHugeFramesAreRejected() {
        XCTAssertThrowsError(try DiscordIPC.decode(Data([9, 0, 0, 0, 0, 0, 0, 0])))
        XCTAssertThrowsError(try DiscordIPC.decode(Data([1, 0, 0, 0, 0, 0, 2, 0])))
    }

    func testHandshakeAndActivityPayloads() throws {
        XCTAssertEqual(String(decoding: DiscordIPC.handshake(applicationID: "1234"), as: UTF8.self),
                       #"{"client_id":"1234","v":1}"#)

        let activity = DiscordIPC.Activity(details: "Focusing", end: Date(timeIntervalSince1970: 1_800_001_500))
        let set = try object(DiscordIPC.setActivity(activity, pid: 42, nonce: "n1"))
        XCTAssertEqual(set["cmd"] as? String, "SET_ACTIVITY")
        XCTAssertEqual(set["nonce"] as? String, "n1")
        let args = try XCTUnwrap(set["args"] as? [String: Any])
        XCTAssertEqual(args["pid"] as? Int, 42)
        let shown = try XCTUnwrap(args["activity"] as? [String: Any])
        XCTAssertEqual(shown["details"] as? String, "Focusing")
        XCTAssertEqual(shown["timestamps"] as? [String: Int], ["end": 1_800_001_500])

        let clear = try object(DiscordIPC.setActivity(nil, pid: 42, nonce: "n2"))
        XCTAssertTrue((clear["args"] as? [String: Any])?["activity"] is NSNull)
    }

    func testSocketsAreLookedForWhereDiscordPutsThem() {
        let folders = DiscordIPC.directories(["TMPDIR": "/var/folders/ab/T/", "XDG_RUNTIME_DIR": "/run/user/501", "TEMP": "/var/folders/ab/T"])
        XCTAssertEqual(Array(folders.prefix(2)), ["/run/user/501", "/var/folders/ab/T"])
        XCTAssertEqual(folders.last, "/tmp")
        XCTAssertEqual(Set(folders).count, folders.count)
        XCTAssertEqual(DiscordIPC.socketPaths(in: "/tmp"), (0..<10).map { "/tmp/discord-ipc-\($0)" })
    }

    func testShowsAndClearsTheActivityOverDiscordsSocket() async throws {
        let discord = try FakeDiscord()
        defer { discord.stop() }
        let presence = DiscordPresence(applicationID: "1234", directories: [discord.directory], retryInterval: 60)
        presence.show(DiscordIPC.Activity(details: "Focusing", end: Date(timeIntervalSince1970: 1_800_001_500)))
        await presence.settle()
        presence.show(nil)
        await presence.settle()

        let frames = await discord.frames(count: 3)
        XCTAssertEqual(frames.map(\.opcode), [.handshake, .frame, .frame])
        XCTAssertEqual(try object(frames[0].payload)["client_id"] as? String, "1234")
        let set = try XCTUnwrap(try object(frames[1].payload)["args"] as? [String: Any])
        XCTAssertEqual(set["pid"] as? Int, Int(getpid()))
        XCTAssertEqual((set["activity"] as? [String: Any])?["details"] as? String, "Focusing")
        XCTAssertTrue((try object(frames[2].payload)["args"] as? [String: Any])?["activity"] is NSNull)
    }

    func testWithoutDiscordNothingHappens() async {
        let empty = NSTemporaryDirectory() + "fg-none-\(UUID().uuidString.prefix(8))"
        let presence = DiscordPresence(applicationID: "1234", directories: [empty], retryInterval: 60)
        presence.show(DiscordIPC.Activity(details: "Focusing"))
        await presence.settle()
        presence.show(nil)
        await presence.settle()
        XCTAssertFalse(DiscordPresence(applicationID: nil, directories: []).isConfigured)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

// MARK: - Fakes

/// Slack's Web API as the tests have it: every call is kept, and answered
/// from `answers` (by method, in order) or with `{"ok": true}`.
final class FakeSlack: @unchecked Sendable {
    var requests: [URLRequest] = []
    var answers: [String: [String]] = [:]
    var opened: [URL] = []
    var offline = false

    var methods: [String] { requests.compactMap { $0.url?.lastPathComponent } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if offline { throw URLError(.notConnectedToInternet) }
        let method = request.url?.lastPathComponent ?? ""
        let answer = answers[method]?.isEmpty == false ? answers[method]?.removeFirst() : nil
        let url = request.url ?? URL(fileURLWithPath: "/")
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) ?? URLResponse()
        return (Data((answer ?? #"{"ok":true}"#).utf8), response)
    }

    func json(_ index: Int) -> [String: Any]? {
        guard index < requests.count, let body = requests[index].httpBody else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    func form(_ index: Int) -> [String: String] {
        guard index < requests.count else { return [:] }
        let body = requests[index].httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return Dictionary(uniqueKeysWithValues: (URLComponents(string: "x:/?" + body)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
    }
}

final class MemoryTokenStore: TokenStore {
    var token: String?
    init(_ token: String? = nil) { self.token = token }
    func read() -> String? { token }
    func write(_ token: String) { self.token = token }
    func delete() { token = nil }

    var decoded: SlackAccount.Tokens? {
        token.flatMap { try? JSONDecoder().decode(SlackAccount.Tokens.self, from: Data($0.utf8)) }
    }

    static func encode(_ tokens: SlackAccount.Tokens) -> String {
        (try? JSONEncoder().encode(tokens)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// The Discord app as far as its IPC goes: listens on `discord-ipc-0` in a
/// folder of its own, answers the handshake with READY and every command
/// with a reply, and keeps the frames it got.
final class FakeDiscord: @unchecked Sendable {
    let directory: String
    private let listener: Int32
    private let lock = NSLock()
    private var received: [DiscordIPC.Frame] = []
    private var stopped = false

    init() throws {
        directory = NSTemporaryDirectory() + "fgd-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/discord-ipc-0"
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard listener >= 0, bound == 0, listen(listener, 1) == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        Thread.detachNewThread { [self] in serve() }
    }

    func stop() {
        lock.withLock { stopped = true }
        close(listener)
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// The first `count` frames, waiting up to five seconds for them.
    func frames(count: Int) async -> [DiscordIPC.Frame] {
        for _ in 0..<100 {
            let got = lock.withLock { received }
            if got.count >= count { return got }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return lock.withLock { received }
    }

    private func serve() {
        var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, 5000) > 0 else { return }
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        // FocusGuard closes right after clearing; a reply then must not kill the tests.
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !lock.withLock({ stopped }) {
            var waiting = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 5000) > 0 else { return }
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
            while let decoded = try? DiscordIPC.decode(buffer) {
                buffer.removeFirst(decoded.length)
                lock.withLock { received.append(decoded.frame) }
                let answer = decoded.frame.opcode == .handshake
                    ? #"{"cmd":"DISPATCH","data":{"v":1},"evt":"READY"}"#
                    : #"{"cmd":"SET_ACTIVITY","data":null,"evt":null,"nonce":"n"}"#
                let reply = DiscordIPC.encode(DiscordIPC.Frame(opcode: .frame, payload: Data(answer.utf8)))
                _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            }
        }
    }
}
