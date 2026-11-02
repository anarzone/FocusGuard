import XCTest
@testable import FocusGuard

// Signing in to GitHub (device flow) and Linear (PKCE). Nothing here talks to
// the real services or the Keychain: answers come from fixtures through the
// stub URL protocol, tokens sit in a fake store, and time is a fake clock.

// MARK: - Fakes

final class SignInClock: @unchecked Sendable {
    var date: Date
    /// Whether the clock was read on the main thread.
    var readOnMain = false
    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.date = date }

    func read() -> Date {
        if Thread.isMainThread { readOnMain = true }
        return date
    }
}

/// Answers in turn, the last one for good, and keeps what was asked.
private final class Renewals: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [TokenRenewal]
    private var seen: [String] = []
    /// Runs while the refresh is on its way.
    var during: @Sendable () async -> Void = {}

    init(_ answers: TokenRenewal...) { self.answers = answers }

    var asked: [String] { lock.withLock { seen } }

    func renew(_ token: String) async -> TokenRenewal {
        lock.withLock { seen.append(token) }
        await during()
        return lock.withLock { answers.count > 1 ? answers.removeFirst() : answers[0] }
    }
}

private func stored(_ tokens: SignInTokens) -> FakeTokens {
    let store = FakeTokens()
    if let data = try? JSONEncoder().encode(tokens) { store.write(String(decoding: data, as: UTF8.self)) }
    return store
}

private func form(_ request: URLRequest?) -> [String: String] {
    let body = request?.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
    var fields: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        fields[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
    }
    return fields
}

private func json(_ tokens: (access: String, refresh: String)) -> String {
    #"{"access_token":"\#(tokens.access)","refresh_token":"\#(tokens.refresh)","expires_in":28800,"token_type":"bearer"}"#
}

/// Stub protocol state is shared, so every suite starts clean.
class SignInTestCase: XCTestCase {
    let clock = SignInClock()

    override func tearDown() {
        StubProtocol.handler = nil
        StubProtocol.headers = nil
        StubProtocol.requests = []
        super.tearDown()
    }

    /// Answers in turn, the last one for good.
    func stubAnswers(_ answers: [(Int, String)]) {
        let lock = NSLock()
        var left = answers
        StubProtocol.handler = { _ in lock.withLock { left.count > 1 ? left.removeFirst() : left[0] } }
    }

    func expiring(in seconds: TimeInterval, access: String = "old", refresh: String? = "r1") -> SignInTokens {
        SignInTokens(access: access, refresh: refresh, expiresAt: clock.date.addingTimeInterval(seconds))
    }
}

// MARK: - Rotating tokens

final class RotatingTokensTests: SignInTestCase {
    private let fresh = SignInTokens(access: "new", refresh: "r2", expiresAt: nil)

    private func make(_ store: FakeTokens, _ renewals: Renewals) -> RotatingTokens {
        let clock = clock
        return RotatingTokens(store: store, now: { clock.date }, renew: { await renewals.renew($0) })
    }

    func testAFreshTokenIsUsedAsItIs() async throws {
        let renewals = Renewals(.unreachable)
        let token = try await make(stored(expiring(in: 3600)), renewals).token()
        XCTAssertEqual(token, "old")
        XCTAssertTrue(renewals.asked.isEmpty)
    }

    func testRefreshingIsDecidedByTheTimeLeft() {
        XCTAssertFalse(RotatingTokens.needsRefresh(expiring(in: RotatingTokens.refreshLead + 1), now: clock.date))
        XCTAssertTrue(RotatingTokens.needsRefresh(expiring(in: RotatingTokens.refreshLead - 1), now: clock.date))
        XCTAssertTrue(RotatingTokens.needsRefresh(expiring(in: -10), now: clock.date))
        XCTAssertFalse(RotatingTokens.needsRefresh(expiring(in: -10, refresh: nil), now: clock.date), "Nothing to refresh with")
        XCTAssertFalse(RotatingTokens.needsRefresh(SignInTokens(access: "a", refresh: "r", expiresAt: nil), now: clock.date))
    }

    func testARefreshKeepsTheRotatedTokens() async throws {
        let store = stored(expiring(in: 60))
        let renewals = Renewals(.renewed(fresh))
        let tokens = make(store, renewals)
        let token = try await tokens.token()
        XCTAssertEqual(token, "new")
        XCTAssertEqual(renewals.asked, ["r1"])
        XCTAssertEqual(tokens.read(), fresh, "The new refresh token replaces the old one")
    }

    func testAnAnswerWithoutARefreshTokenKeepsTheOldOne() async throws {
        let tokens = make(stored(expiring(in: 60)), Renewals(.renewed(SignInTokens(access: "new", refresh: nil, expiresAt: nil))))
        _ = try await tokens.token()
        XCTAssertEqual(tokens.read()?.refresh, "r1")
    }

    func testARejectedRefreshSignsOut() async {
        let store = stored(expiring(in: 60))
        let tokens = make(store, Renewals(.turnedDown))
        do {
            _ = try await tokens.token()
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .rejected)
        }
        XCTAssertNil(store.token, "The Keychain is cleared")
        XCTAssertFalse(tokens.isSignedIn)
        XCTAssertTrue(tokens.wasSignedOut)
    }

    func testOfflineKeepsTheSignInAndTheTokenStillGood() async throws {
        let store = stored(expiring(in: 60))
        let tokens = make(store, Renewals(.unreachable))
        let token = try await tokens.token()
        XCTAssertEqual(token, "old", "It has a minute left")
        XCTAssertTrue(tokens.isSignedIn)
        XCTAssertFalse(tokens.wasSignedOut)
    }

    func testOfflineWithARunOutTokenIsNotASignOut() async {
        let store = stored(expiring(in: -60))
        let tokens = make(store, Renewals(.unreachable))
        do {
            _ = try await tokens.token()
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .unreachable)
        }
        XCTAssertTrue(tokens.isSignedIn)
        XCTAssertFalse(tokens.wasSignedOut)
    }

    func testTwoReadsSpendTheRefreshTokenOnce() async throws {
        let renewals = Renewals(.renewed(fresh))
        renewals.during = { try? await Task.sleep(for: .milliseconds(50)) }
        let tokens = make(stored(expiring(in: 60)), renewals)
        async let first = tokens.token()
        async let second = tokens.token()
        let both = try await [first, second]
        XCTAssertEqual(both, ["new", "new"])
        XCTAssertEqual(renewals.asked, ["r1"])
    }

    func testAStaleCallerUsesTheTokensAlreadyRenewed() async throws {
        let renewals = Renewals(.renewed(fresh))
        let tokens = make(stored(expiring(in: 3600)), renewals)
        let first = try await tokens.renewed(after: "old")
        XCTAssertEqual(first, "new")
        let second = try await tokens.renewed(after: "old")
        XCTAssertEqual(second, "new")
        XCTAssertEqual(renewals.asked, ["r1"], "The second caller's token had already been replaced")
    }

    func testATokenThatDoesntRotateEndsTheSignInWhenTurnedDown() async {
        let renewals = Renewals(.unreachable)
        let tokens = make(stored(expiring(in: 3600, refresh: nil)), renewals)
        do {
            _ = try await tokens.renewed(after: "old")
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .rejected)
        }
        XCTAssertTrue(renewals.asked.isEmpty)
        XCTAssertTrue(tokens.wasSignedOut)
    }

    func testDisconnectingDuringARefreshKeepsNothing() async throws {
        final class Holder: @unchecked Sendable { var tokens: RotatingTokens? }
        let holder = Holder()
        let store = stored(expiring(in: 60))
        let renewals = Renewals(.renewed(fresh))
        renewals.during = { holder.tokens?.forget() }
        let tokens = make(store, renewals)
        holder.tokens = tokens
        let token = try await tokens.token()
        XCTAssertNil(token)
        XCTAssertNil(store.token, "The refresh's answer doesn't bring the sign-in back")
        XCTAssertFalse(tokens.wasSignedOut, "Disconnecting isn't being signed out")
    }

    func testSigningInClearsTheSignedOutState() async {
        let tokens = make(stored(expiring(in: 60)), Renewals(.turnedDown))
        _ = try? await tokens.token()
        XCTAssertTrue(tokens.wasSignedOut)
        tokens.save(fresh)
        XCTAssertFalse(tokens.wasSignedOut)
        XCTAssertTrue(tokens.isSignedIn)
    }

    func testWhatEndsASignInAndWhatDoesnt() {
        let now = clock.date
        func renewal(_ status: Int, _ body: String) -> TokenRenewal {
            TokenRenewal(data: Data(body.utf8), status: status, now: now)
        }
        XCTAssertEqual(renewal(200, json(("a", "b"))),
                       .renewed(SignInTokens(access: "a", refresh: "b", expiresAt: now.addingTimeInterval(28_800))))
        XCTAssertEqual(renewal(200, #"{"error":"bad_refresh_token"}"#), .turnedDown, "GitHub says it with a 200")
        XCTAssertEqual(renewal(400, #"{"error":"invalid_grant"}"#), .turnedDown, "Linear with a 400")
        XCTAssertEqual(renewal(401, ""), .turnedDown)
        XCTAssertEqual(renewal(500, ""), .unreachable)
        XCTAssertEqual(renewal(429, #"{"error":"rate_limited"}"#), .unreachable)
        XCTAssertEqual(renewal(200, "<html>"), .unreachable)
        XCTAssertEqual(renewal(200, #"{"error":"slow_down"}"#), .unreachable)
    }
}

// MARK: - GitHub's device flow

final class GitHubDeviceFlowTests: SignInTestCase {
    private let code = GitHubDeviceFlow.Code(deviceCode: "dev123", userCode: "WDJB-MJHT", verificationUri: "https://github.com/login/device",
                                             expiresIn: 900, interval: 5)

    private func wait(_ code: GitHubDeviceFlow.Code? = nil, slept: SleepLog = SleepLog()) async throws -> GitHubDeviceFlow.Poll {
        let clock = clock
        return try await GitHubDeviceFlow.waitForTokens(clientID: "Iv1.abc", code: code ?? self.code, session: StubProtocol.session(),
                                                        now: { clock.read() }, sleep: { interval in
                                                            slept.add(interval)
                                                            clock.date = clock.date.addingTimeInterval(interval)
                                                        })
    }

    private final class SleepLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [TimeInterval] = []
        var intervals: [TimeInterval] { lock.withLock { seen } }
        func add(_ interval: TimeInterval) { lock.withLock { seen.append(interval) } }
    }

    func testAskingForACodeSendsOnlyTheClientID() {
        let request = GitHubDeviceFlow.codeRequest(clientID: "Iv1.abc")
        XCTAssertEqual(request.url?.absoluteString, "https://github.com/login/device/code")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(form(request), ["client_id": "Iv1.abc"])
    }

    func testPollingSendsNoSecret() {
        let request = GitHubDeviceFlow.pollRequest(clientID: "Iv1.abc", deviceCode: "dev123")
        XCTAssertEqual(request.url?.absoluteString, "https://github.com/login/oauth/access_token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(form(request), ["client_id": "Iv1.abc", "device_code": "dev123",
                                       "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
    }

    func testRefreshingSendsNoSecret() {
        let request = GitHubDeviceFlow.refreshRequest(clientID: "Iv1.abc", refreshToken: "ghr_1")
        XCTAssertEqual(request.url?.absoluteString, "https://github.com/login/oauth/access_token")
        XCTAssertEqual(form(request), ["client_id": "Iv1.abc", "grant_type": "refresh_token", "refresh_token": "ghr_1"])
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testACodeIsReadFromItsAnswer() async throws {
        StubProtocol.handler = { _ in
            (200, #"{"device_code":"dev123","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":7}"#)
        }
        let code = try await GitHubDeviceFlow.requestCode(clientID: "Iv1.abc", session: StubProtocol.session())
        XCTAssertEqual(code.userCode, "WDJB-MJHT")
        XCTAssertEqual(code.deviceCode, "dev123")
        XCTAssertEqual(code.pollInterval, 7)
        XCTAssertEqual(code.lifetime, 900)
    }

    func testACodeWithoutTimesGetsGitHubsDefaults() {
        let bare = GitHubDeviceFlow.Code(deviceCode: "d", userCode: "u", verificationUri: nil, expiresIn: nil, interval: nil)
        XCTAssertEqual(bare.lifetime, 900)
        XCTAssertEqual(bare.pollInterval, 5)
    }

    func testOnlyGitHubsOwnPageIsOpened() {
        func page(_ uri: String?) -> String {
            GitHubDeviceFlow.Code(deviceCode: "d", userCode: "u", verificationUri: uri, expiresIn: nil, interval: nil).pageURL.absoluteString
        }
        XCTAssertEqual(page("https://github.com/login/device"), "https://github.com/login/device")
        XCTAssertEqual(page("https://evil.example/login/device"), "https://github.com/login/device")
        XCTAssertEqual(page("http://github.com/login/device"), "https://github.com/login/device")
        XCTAssertEqual(page(nil), "https://github.com/login/device")
    }

    func testEveryPollingAnswerIsUnderstood() {
        let now = clock.date
        func poll(_ body: String) -> GitHubDeviceFlow.Poll { GitHubDeviceFlow.poll(data: Data(body.utf8), now: now) }
        XCTAssertEqual(poll(#"{"error":"authorization_pending"}"#), .pending)
        XCTAssertEqual(poll(#"{"error":"slow_down"}"#), .slowDown(nil))
        XCTAssertEqual(poll(#"{"error":"slow_down","interval":10}"#), .slowDown(10))
        XCTAssertEqual(poll(#"{"error":"expired_token"}"#), .expired)
        XCTAssertEqual(poll(#"{"error":"access_denied"}"#), .denied)
        XCTAssertEqual(poll(#"{"error":"device_flow_disabled"}"#), .disabled)
        XCTAssertEqual(poll(#"{"error":"incorrect_client_credentials"}"#), .badClient)
        XCTAssertEqual(poll(#"{"error":"incorrect_device_code"}"#), .failed)
        XCTAssertEqual(poll("<html>"), .pending, "May be better next time")
        XCTAssertEqual(poll(json(("ghu_1", "ghr_1"))),
                       .signedIn(SignInTokens(access: "ghu_1", refresh: "ghr_1", expiresAt: now.addingTimeInterval(28_800))))
    }

    func testPollingWaitsTheIntervalUntilTheUserSaysYes() async throws {
        stubAnswers([(200, #"{"error":"authorization_pending"}"#), (200, #"{"error":"authorization_pending"}"#), (200, json(("ghu_1", "ghr_1")))])
        let slept = SleepLog()
        let answer = try await wait(slept: slept)
        guard case .signedIn(let tokens) = answer else { return XCTFail("\(answer)") }
        XCTAssertEqual(tokens.access, "ghu_1")
        XCTAssertEqual(slept.intervals, [5, 5, 5], "It waits before the first poll too")
        XCTAssertEqual(StubProtocol.requests.count, 3)
    }

    func testSlowDownAddsFiveSeconds() async throws {
        stubAnswers([(200, #"{"error":"slow_down"}"#), (200, #"{"error":"authorization_pending"}"#), (200, json(("a", "b")))])
        let slept = SleepLog()
        _ = try await wait(slept: slept)
        XCTAssertEqual(slept.intervals, [5, 10, 10])
    }

    func testSlowDownTakesALongerIntervalFromTheAnswer() async throws {
        stubAnswers([(200, #"{"error":"slow_down","interval":30}"#), (200, json(("a", "b")))])
        let slept = SleepLog()
        _ = try await wait(slept: slept)
        XCTAssertEqual(slept.intervals, [5, 30])
    }

    func testPollingStopsWhenTheCodeRunsOut() async throws {
        stubAnswers([(200, #"{"error":"authorization_pending"}"#)])
        let short = GitHubDeviceFlow.Code(deviceCode: "d", userCode: "u", verificationUri: nil, expiresIn: 10, interval: 5)
        let answer = try await wait(short)
        XCTAssertEqual(answer, .expired)
        XCTAssertEqual(StubProtocol.requests.count, 1, "No poll at or after the deadline")
    }

    func testAnEndingAnswerStopsPolling() async throws {
        for (error, expected) in [("expired_token", GitHubDeviceFlow.Poll.expired), ("access_denied", .denied),
                                  ("device_flow_disabled", .disabled), ("incorrect_client_credentials", .badClient)] {
            StubProtocol.requests = []
            stubAnswers([(200, #"{"error":"\#(error)"}"#)])
            let answer = try await wait()
            XCTAssertEqual(answer, expected)
            XCTAssertEqual(StubProtocol.requests.count, 1)
        }
    }

    func testAServerHiccupKeepsPolling() async throws {
        stubAnswers([(502, "<html>Bad gateway</html>"), (200, json(("a", "b")))])
        let answer = try await wait()
        guard case .signedIn = answer else { return XCTFail("\(answer)") }
    }

    func testCancellingStopsPolling() async {
        stubAnswers([(200, #"{"error":"authorization_pending"}"#)])
        let code = code
        let session = StubProtocol.session()
        let task = Task {
            try await GitHubDeviceFlow.waitForTokens(clientID: "Iv1.abc", code: code, session: session,
                                                     sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    @MainActor
    func testPollingIsOffTheMainThread() async throws {
        stubAnswers([(200, #"{"error":"authorization_pending"}"#), (200, json(("a", "b")))])
        _ = try await wait()
        XCTAssertFalse(clock.readOnMain)
    }

    func testCodesAndTokensOnlyGoToGitHub() async {
        XCTAssertTrue(GitHubDeviceFlow.isLogin(GitHubDeviceFlow.tokenURL))
        XCTAssertTrue(GitHubDeviceFlow.isLogin(GitHubDeviceFlow.codeURL))
        for address in ["http://github.com/login", "https://github.com.evil.example/login", "https://github.com:8443/login", "https://evil.example/"] {
            XCTAssertFalse(GitHubDeviceFlow.isLogin(URL(string: address)!), address)
        }

        StubProtocol.handler = { request in
            request.url?.host == "github.com" ? (302, "") : (200, json(("stolen", "stolen")))
        }
        StubProtocol.headers = { _ in ["Location": "https://evil.example/token"] }
        let renewal = await TokenRenewal.fetch(GitHubDeviceFlow.refreshRequest(clientID: "Iv1.abc", refreshToken: "ghr_1"),
                                               session: StubProtocol.session(), staysOn: GitHubDeviceFlow.isLogin, now: clock.date)
        XCTAssertEqual(renewal, .unreachable)
        XCTAssertEqual(StubProtocol.requests.compactMap { $0.url?.host }, ["github.com"])
    }
}

// MARK: - Connecting GitHub

@MainActor
final class GitHubSignInTests: SignInTestCase {
    private let codeAnswer = (200, #"{"device_code":"dev123","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#)
    private var opened: [URL] = []

    private func make(_ store: FakeTokens = FakeTokens(),
                      sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }) -> GitHubSignIn {
        let clock = clock
        let signIn = GitHubSignIn(clientID: "Iv1.abc", appSlug: "focusguard", store: store, session: StubProtocol.session(),
                                  now: { clock.date }, sleep: sleep)
        signIn.openURL = { [weak self] in self?.opened.append($0) }
        return signIn
    }

    func testConnectingShowsTheCodeOpensThePageAndKeepsTheTokens() async {
        stubAnswers([codeAnswer, (200, json(("ghu_1", "ghr_1")))])
        let store = FakeTokens()
        let signIn = make(store)
        var connected = false
        signIn.onConnected = { connected = true }
        signIn.start()
        XCTAssertEqual(signIn.phase, .asking)
        await signIn.running?.value
        XCTAssertEqual(signIn.phase, .idle)
        XCTAssertTrue(connected)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/login/device"])
        XCTAssertEqual(signIn.tokens.read()?.access, "ghu_1")
        XCTAssertEqual(signIn.tokens.read()?.refresh, "ghr_1")
        XCTAssertEqual(signIn.tokens.read()?.expiresAt, clock.date.addingTimeInterval(28_800))
        XCTAssertFalse(StubProtocol.requests.contains { form($0).keys.contains("client_secret") })
    }

    func testTheCodeShowsWhilePollingAndCancellingStopsIt() async throws {
        stubAnswers([codeAnswer, (200, #"{"error":"authorization_pending"}"#)])
        let signIn = make(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        signIn.start()
        let running = signIn.running
        while signIn.phase == .asking { try await Task.sleep(for: .milliseconds(5)) }
        guard case .showing(let code) = signIn.phase else { return XCTFail("\(signIn.phase)") }
        XCTAssertEqual(code.userCode, "WDJB-MJHT")
        signIn.cancel()
        XCTAssertEqual(signIn.phase, .idle)
        await running?.value
        XCTAssertEqual(signIn.phase, .idle)
        XCTAssertEqual(StubProtocol.requests.count, 1, "It never polled")
        XCTAssertFalse(signIn.tokens.isSignedIn)
    }

    func testARunOutCodeSaysSo() async {
        stubAnswers([codeAnswer, (200, #"{"error":"expired_token"}"#)])
        let signIn = make()
        signIn.start()
        await signIn.running?.value
        XCTAssertEqual(signIn.phase, .failed(.expired))
    }

    func testSayingNoOnGitHubIsNotAProblem() async {
        stubAnswers([codeAnswer, (200, #"{"error":"access_denied"}"#)])
        let signIn = make()
        signIn.start()
        await signIn.running?.value
        XCTAssertEqual(signIn.phase, .idle)
        XCTAssertFalse(signIn.tokens.isSignedIn)
    }

    func testADisabledOrWrongAppIsUnavailable() async {
        for answers in [[codeAnswer, (200, #"{"error":"device_flow_disabled"}"#)],
                        [codeAnswer, (200, #"{"error":"incorrect_client_credentials"}"#)],
                        [(200, #"{"error":"device_flow_disabled"}"#)]] {
            stubAnswers(answers)
            let signIn = make()
            signIn.start()
            await signIn.running?.value
            XCTAssertEqual(signIn.phase, .failed(.unavailable))
        }
    }

    func testNoAnswerForACodeIsUnreachable() async {
        stubAnswers([(503, "")])
        let signIn = make()
        signIn.start()
        await signIn.running?.value
        XCTAssertEqual(signIn.phase, .failed(.unreachable))
        XCTAssertTrue(opened.isEmpty)
    }

    func testTheInstallPageComesFromTheSlug() {
        XCTAssertEqual(make().installURL?.absoluteString, "https://github.com/apps/focusguard/installations/new")
        let noSlug = GitHubSignIn(clientID: "Iv1.abc", appSlug: nil, store: FakeTokens(), session: StubProtocol.session())
        XCTAssertNil(noSlug.installURL)
    }
}

// MARK: - GitHub's tasks with a sign-in

final class GitHubSignedInTasksTests: SignInTestCase {
    private let issues = #"[{"number":1,"title":"Fix it","state":"open","repository":{"name":"app","full_name":"acme/app"}}]"#

    private func make(_ tokens: SignInTokens, personal: FakeTokens = FakeTokens()) -> (GitHubTasks, RotatingTokens, FakeTokens) {
        let store = stored(tokens)
        let session = StubProtocol.session()
        let clock = clock
        let rotating = RotatingTokens(store: store, now: { clock.date }) {
            await TokenRenewal.fetch(GitHubDeviceFlow.refreshRequest(clientID: "Iv1.abc", refreshToken: $0), session: session,
                                     staysOn: GitHubDeviceFlow.isLogin, now: clock.date)
        }
        return (GitHubTasks(tokens: personal, signIn: rotating, session: session), rotating, store)
    }

    func testASignInGoesAsBearerToTheAPI() async throws {
        StubProtocol.handler = { [issues] _ in (200, issues) }
        let (github, _, _) = make(expiring(in: 3600, access: "ghu_ok"))
        XCTAssertTrue(github.hasToken)
        XCTAssertTrue(github.isSignedIn)
        let tasks = try await github.openTasks()
        XCTAssertEqual(tasks.map(\.id), ["acme/app#1"])
        XCTAssertEqual(StubProtocol.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer ghu_ok"])
    }

    func testATokenAboutToRunOutIsRefreshedFirst() async throws {
        StubProtocol.handler = { [issues] request in
            request.url?.host == "github.com" ? (200, json(("ghu_new", "ghr_new"))) : (200, issues)
        }
        let (github, rotating, _) = make(expiring(in: 60, access: "ghu_old", refresh: "ghr_old"))
        _ = try await github.openTasks()
        XCTAssertEqual(StubProtocol.requests.map { $0.url?.host }, ["github.com", "api.github.com"])
        XCTAssertEqual(form(StubProtocol.requests.first)["refresh_token"], "ghr_old")
        XCTAssertEqual(StubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer ghu_new")
        XCTAssertEqual(rotating.read()?.refresh, "ghr_new")
    }

    func testATokenTurnedDownIsRefreshedAndTriedOnce() async throws {
        StubProtocol.handler = { [issues] request in
            if request.url?.host == "github.com" { return (200, json(("ghu_new", "ghr_new"))) }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_new" ? (200, issues) : (401, "")
        }
        let (github, _, _) = make(expiring(in: 3600, access: "ghu_old"))
        let tasks = try await github.openTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(StubProtocol.requests.count, 3)
    }

    func testAToken401AgainAfterTheRefreshIsRejectedWithoutALoop() async {
        StubProtocol.handler = { request in
            request.url?.host == "github.com" ? (200, json(("ghu_new", "ghr_new"))) : (401, "")
        }
        let (github, _, _) = make(expiring(in: 3600, access: "ghu_old"))
        do {
            _ = try await github.openTasks()
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .rejected)
        }
        XCTAssertEqual(StubProtocol.requests.count, 3)
        XCTAssertTrue(github.isSignedIn, "The refresh worked, so the sign-in stands")
    }

    func testARejectedRefreshSignsOutAndAsksToConnectAgain() async throws {
        StubProtocol.handler = { _ in (200, #"{"error":"bad_refresh_token"}"#) }
        let (github, _, store) = make(expiring(in: 60))
        do {
            _ = try await github.openTasks()
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .rejected)
        }
        XCTAssertFalse(github.hasToken)
        XCTAssertTrue(github.wasSignedOut)
        XCTAssertNil(store.token)
        let after = try await github.openTasks()
        XCTAssertEqual(after, [], "Signed out reads as not connected")
    }

    func testOfflineKeepsTheSignIn() async {
        StubProtocol.handler = { _ in (503, "") }
        let (github, _, store) = make(expiring(in: -60))
        do {
            _ = try await github.openTasks()
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .unreachable)
        }
        XCTAssertTrue(github.hasToken)
        XCTAssertFalse(github.wasSignedOut)
        XCTAssertNotNil(store.token)
    }

    func testClosingAnIssueUsesTheSignIn() async {
        StubProtocol.handler = { _ in (200, #"{"number":1,"state":"closed"}"#) }
        let (github, _, _) = make(expiring(in: 3600, access: "ghu_ok"))
        let task = TaskItem(source: .github, id: "acme/app#1", title: "app#1 Fix it", list: "app", due: nil, created: nil)
        let change = await github.change(task, completed: true)
        XCTAssertEqual(change, .saved)
        XCTAssertEqual(StubProtocol.requests.first?.httpMethod, "PATCH")
        XCTAssertEqual(StubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer ghu_ok")
    }

    func testARefusedChangeBlamesTheRightThing() async {
        StubProtocol.handler = { _ in (403, #"{"message":"Resource not accessible by integration"}"#) }
        let task = TaskItem(source: .github, id: "acme/app#1", title: "t", list: "app", due: nil, created: nil)
        let signedIn = await make(expiring(in: 3600)).0.change(task, completed: true)
        guard case .refused(let line) = signedIn else { return XCTFail("\(signedIn)") }
        XCTAssertTrue(line.contains("GitHub app"), line)
        let pasted = await GitHubTasks(tokens: FakeTokens("ghp"), session: StubProtocol.session()).change(task, completed: true)
        guard case .refused(let tokenLine) = pasted else { return XCTFail("\(pasted)") }
        XCTAssertTrue(tokenLine.contains("token"), tokenLine)
    }

    func testDisconnectClearsTheKeychainAndCallsNobody() {
        let personal = FakeTokens("ghp_left")
        let (github, _, store) = make(expiring(in: 3600), personal: personal)
        github.disconnect()
        XCTAssertNil(store.token)
        XCTAssertNil(personal.token)
        XCTAssertFalse(github.hasToken)
        XCTAssertFalse(github.wasSignedOut)
        XCTAssertTrue(StubProtocol.requests.isEmpty, "GitHub can't revoke without the app's secret")
    }

    // MARK: Installation

    private let installed = #"{"total_count":1,"installations":[{"id":42,"suspended_at":null}]}"#

    func testNoInstallationMeansNoRepositories() async {
        StubProtocol.handler = { _ in (200, #"{"total_count":0,"installations":[]}"#) }
        let access = await make(expiring(in: 3600)).0.repositoryAccess()
        XCTAssertEqual(access, .noRepositories)
        XCTAssertEqual(StubProtocol.requests.first?.url?.path, "/user/installations")
        XCTAssertEqual(StubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer old")
    }

    func testAnInstallationWithRepositoriesIsReachable() async {
        StubProtocol.handler = { [installed] request in
            request.url?.path == "/user/installations" ? (200, installed) : (200, #"{"total_count":3,"repositories":[{}]}"#)
        }
        let access = await make(expiring(in: 3600)).0.repositoryAccess()
        XCTAssertEqual(access, .reachable)
        XCTAssertEqual(StubProtocol.requests.last?.url?.path, "/user/installations/42/repositories")
    }

    func testAnInstallationWithNoRepositoriesIsntEnough() async {
        StubProtocol.handler = { [installed] request in
            request.url?.path == "/user/installations" ? (200, installed) : (200, #"{"total_count":0,"repositories":[]}"#)
        }
        let access = await make(expiring(in: 3600)).0.repositoryAccess()
        XCTAssertEqual(access, .noRepositories)
    }

    func testASuspendedInstallationDoesntCount() async {
        StubProtocol.handler = { _ in (200, #"{"total_count":1,"installations":[{"id":42,"suspended_at":"2026-10-01T00:00:00Z"}]}"#) }
        let access = await make(expiring(in: 3600)).0.repositoryAccess()
        XCTAssertEqual(access, .noRepositories)
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    func testTroubleAskingIsntReportedAsNoRepositories() async {
        StubProtocol.handler = { _ in (500, "") }
        let access = await make(expiring(in: 3600)).0.repositoryAccess()
        XCTAssertEqual(access, .unknown)
    }

    func testAPastedTokenIsntAskedAboutInstallations() async {
        let access = await GitHubTasks(tokens: FakeTokens("ghp"), session: StubProtocol.session()).repositoryAccess()
        XCTAssertEqual(access, .unknown)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testAPastedTokenWorksAsBefore() async throws {
        StubProtocol.handler = { [issues] _ in (200, issues) }
        let personal = FakeTokens("ghp_pasted")
        let session = StubProtocol.session()
        let empty = RotatingTokens(store: FakeTokens(), renew: { _ in .turnedDown })
        let github = GitHubTasks(tokens: personal, signIn: empty, session: session)
        XCTAssertTrue(github.hasToken)
        XCTAssertFalse(github.isSignedIn)
        _ = try await github.openTasks()
        XCTAssertEqual(StubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer ghp_pasted")

        StubProtocol.requests = []
        StubProtocol.handler = { _ in (401, "") }
        do {
            _ = try await github.openTasks()
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .rejected)
        }
        XCTAssertEqual(StubProtocol.requests.count, 1, "A pasted token isn't refreshed or tried again")
        XCTAssertEqual(personal.token, "ghp_pasted", "It stays until the user disconnects")
    }
}

// MARK: - Linear's OAuth

final class LinearOAuthTests: SignInTestCase {
    func testPKCEIsS256() {
        // RFC 7636's own example.
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testTheAuthorizeURLAsksForLittle() throws {
        let url = try XCTUnwrap(LinearOAuth.authorizeURL(clientID: "lin_client", verifier: "verifier", state: "state1"))
        XCTAssertEqual(url.host, "linear.app")
        XCTAssertEqual(url.path, "/oauth/authorize")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, [
            "client_id": "lin_client",
            "redirect_uri": "http://127.0.0.1:47182/callback",
            "response_type": "code",
            "scope": "read,issues:create",
            "state": "state1",
            "code_challenge": PKCE.challenge(for: "verifier"),
            "code_challenge_method": "S256",
        ])
    }

    @MainActor
    func testItsPortIsntSpotifys() {
        XCTAssertNotEqual(LinearOAuth.redirectPort, SpotifyAccount.redirectPort)
    }

    func testAWrongStateIsntTrusted() {
        XCTAssertEqual(LinearOAuth.read(["code": "abc", "state": "theirs"], state: "ours"), .failed)
        XCTAssertEqual(LinearOAuth.read(["code": "abc"], state: "ours"), .failed)
        XCTAssertEqual(LinearOAuth.read(["error": "access_denied", "state": "theirs"], state: "ours"), .failed)
    }

    func testTheCallbackIsRead() {
        XCTAssertEqual(LinearOAuth.read(["code": "abc", "state": "ours"], state: "ours"), .code("abc"))
        XCTAssertEqual(LinearOAuth.read(["error": "access_denied", "state": "ours"], state: "ours"), .denied)
        XCTAssertEqual(LinearOAuth.read(["error": "server_error", "state": "ours"], state: "ours"), .failed)
        XCTAssertEqual(LinearOAuth.read(["code": "", "state": "ours"], state: "ours"), .failed)
    }

    func testExchangingTheCodeSendsTheVerifierAndNoSecret() {
        let request = LinearOAuth.exchangeRequest(clientID: "lin_client", code: "abc", verifier: "verifier")
        XCTAssertEqual(request.url?.absoluteString, "https://api.linear.app/oauth/token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(form(request), ["client_id": "lin_client", "code": "abc", "code_verifier": "verifier",
                                       "grant_type": "authorization_code", "redirect_uri": "http://127.0.0.1:47182/callback"])
    }

    func testRefreshingNeedsOnlyTheClientID() {
        let request = LinearOAuth.refreshRequest(clientID: "lin_client", refreshToken: "r1")
        XCTAssertEqual(form(request), ["client_id": "lin_client", "grant_type": "refresh_token", "refresh_token": "r1"])
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testOAuthTokensGoAsBearerAndPersonalKeysDont() {
        XCTAssertEqual(LinearTasks.request("q", credential: .signedIn("oauth")).value(forHTTPHeaderField: "Authorization"), "Bearer oauth")
        XCTAssertEqual(LinearTasks.request("q", credential: .personal("lin_api_1")).value(forHTTPHeaderField: "Authorization"), "lin_api_1")
        XCTAssertEqual(LinearTasks.request("q", key: "lin_api_1").value(forHTTPHeaderField: "Authorization"), "lin_api_1")
    }

    func testTheListenerSaysWhichServiceSignedIn() async throws {
        let receiver = LoopbackReceiver(signedIn: "Signed in to Linear", refused: "Linear said no")
        let port = try await receiver.start()
        async let callback = receiver.waitForCallback()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/callback?code=abc&state=s"))
        let (data, _) = try await URLSession.shared.data(from: url)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Signed in to Linear"))
        let parameters = try await callback
        XCTAssertEqual(parameters["code"], "abc")
    }

    func testCredentialsOnlyGoToLinearsAPI() {
        XCTAssertTrue(LinearTasks.isLinear(LinearTasks.endpoint))
        XCTAssertTrue(LinearTasks.isLinear(LinearOAuth.tokenURL))
        XCTAssertTrue(LinearTasks.isLinear(LinearOAuth.revokeURL))
        for address in ["http://api.linear.app/graphql", "https://api.linear.app.evil.example/", "https://linear.app/graphql", "https://api.linear.app:8443/"] {
            XCTAssertFalse(LinearTasks.isLinear(URL(string: address)!), address)
        }
    }
}

// MARK: - Connecting Linear

/// The browser, already answered.
private final class FakeReceiver: RedirectReceiver {
    /// What comes back, given the page that was opened.
    var respond: (URL?) throws -> [String: String]
    var opened: URL?
    var port: UInt16?
    var stopped = false
    var startError: Error?

    init(respond: @escaping (URL?) throws -> [String: String]) { self.respond = respond }

    func start(port: UInt16?) async throws -> UInt16 {
        if let startError { throw startError }
        self.port = port
        return port ?? 0
    }

    func waitForCallback() async throws -> [String: String] { try respond(opened) }
    func stop() { stopped = true }

    /// The state and challenge on the page opened.
    static func query(_ url: URL?) -> [String: String] {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
}

@MainActor
final class LinearSignInTests: SignInTestCase {
    private func make(_ receiver: FakeReceiver) -> LinearSignIn {
        let clock = clock
        let signIn = LinearSignIn(clientID: "lin_client", store: FakeTokens(), session: StubProtocol.session(), now: { clock.date })
        signIn.makeReceiver = { receiver }
        signIn.openURL = { receiver.opened = $0 }
        return signIn
    }

    func testConnectingExchangesTheCodeAndKeepsTheTokens() async throws {
        StubProtocol.handler = { _ in (200, json(("lin_oauth", "lin_refresh"))) }
        let receiver = FakeReceiver { ["code": "abc", "state": FakeReceiver.query($0)["state"] ?? ""] }
        let signIn = make(receiver)
        var connected = false
        signIn.onConnected = { connected = true }
        signIn.start()
        XCTAssertEqual(signIn.phase, .waiting)
        await signIn.running?.value
        XCTAssertEqual(signIn.phase, .idle)
        XCTAssertTrue(connected)
        XCTAssertEqual(receiver.port, 47182)
        XCTAssertEqual(signIn.tokens.read()?.access, "lin_oauth")
        XCTAssertEqual(signIn.tokens.read()?.refresh, "lin_refresh")

        let exchange = try XCTUnwrap(StubProtocol.requests.first)
        let fields = form(exchange)
        XCTAssertEqual(fields["code"], "abc")
        XCTAssertEqual(fields["grant_type"], "authorization_code")
        XCTAssertNil(fields["client_secret"])
        XCTAssertEqual(PKCE.challenge(for: fields["code_verifier"] ?? ""), FakeReceiver.query(receiver.opened)["code_challenge"],
                       "The verifier goes with the challenge on the page")
    }

    func testAWrongStateNeverReachesLinear() async {
        let receiver = FakeReceiver { _ in ["code": "abc", "state": "not-ours"] }
        let signIn = make(receiver)
        signIn.start()
        await signIn.running?.value
        XCTAssertEqual(signIn.phase, .failed)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
        XCTAssertFalse(signIn.tokens.isSignedIn)
    }

    func testSayingNoOnLinearIsNotAProblem() async {
        let signIn = make(FakeReceiver { ["error": "access_denied", "state": FakeReceiver.query($0)["state"] ?? ""] })
        signIn.start()
        await signIn.running?.value
        XCTAssertEqual(signIn.phase, .idle)
    }

    func testAnExchangeLinearTurnsDownFails() async {
        StubProtocol.handler = { _ in (400, #"{"error":"invalid_grant"}"#) }
        let signIn = make(FakeReceiver { ["code": "abc", "state": FakeReceiver.query($0)["state"] ?? ""] })
        signIn.start()
        await signIn.running?.value
        XCTAssertEqual(signIn.phase, .failed)
        XCTAssertFalse(signIn.tokens.isSignedIn)
    }

    func testAPortInUseFailsWithoutOpeningTheBrowser() async {
        let receiver = FakeReceiver { _ in [:] }
        receiver.startError = URLError(.cannotConnectToHost)
        let signIn = make(receiver)
        signIn.start()
        await signIn.running?.value
        XCTAssertEqual(signIn.phase, .failed)
        XCTAssertNil(receiver.opened)
    }

    func testCancellingStopsTheListener() async {
        let receiver = FakeReceiver { _ in throw CancellationError() }
        let signIn = make(receiver)
        signIn.start()
        let running = signIn.running
        signIn.cancel()
        XCTAssertEqual(signIn.phase, .idle)
        await running?.value
        XCTAssertEqual(signIn.phase, .idle)
        XCTAssertFalse(signIn.tokens.isSignedIn)
    }
}

// MARK: - Linear's tasks with a sign-in

final class LinearSignedInTasksTests: SignInTestCase {
    private let issues = #"{"data":{"viewer":{"assignedIssues":{"nodes":[{"id":"abc","identifier":"ENG-1","title":"Fix it"}]}}}}"#
    private let authError = #"{"errors":[{"message":"Authentication required","extensions":{"type":"authentication error"}}]}"#

    private func make(_ tokens: SignInTokens, personal: FakeTokens = FakeTokens()) -> (LinearTasks, RotatingTokens, FakeTokens) {
        let store = stored(tokens)
        let session = StubProtocol.session()
        let clock = clock
        let rotating = RotatingTokens(store: store, now: { clock.date }) {
            await TokenRenewal.fetch(LinearOAuth.refreshRequest(clientID: "lin_client", refreshToken: $0), session: session,
                                     staysOn: LinearTasks.isLinear, now: clock.date)
        }
        return (LinearTasks(tokens: personal, signIn: rotating, session: session), rotating, store)
    }

    func testASignInGoesAsBearer() async throws {
        StubProtocol.handler = { [issues] _ in (200, issues) }
        let (linear, _, _) = make(expiring(in: 3600, access: "lin_oauth"))
        let tasks = try await linear.openTasks()
        XCTAssertEqual(tasks.map(\.id), ["abc"])
        XCTAssertEqual(StubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer lin_oauth")
    }

    func testAPersonalKeyGoesWithoutBearerAsBefore() async throws {
        StubProtocol.handler = { [issues] _ in (200, issues) }
        let empty = RotatingTokens(store: FakeTokens(), renew: { _ in .turnedDown })
        let linear = LinearTasks(tokens: FakeTokens("lin_api_1"), signIn: empty, session: StubProtocol.session())
        XCTAssertFalse(linear.isSignedIn)
        _ = try await linear.openTasks()
        XCTAssertEqual(StubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "lin_api_1")
    }

    func testAPastedKeyIsCheckedAndKeptAsBefore() async {
        StubProtocol.handler = { _ in (200, #"{"data":{"viewer":{"id":"me"}}}"#) }
        let personal = FakeTokens()
        let linear = LinearTasks(tokens: personal, session: StubProtocol.session())
        let check = await linear.connect(token: " lin_api_1\n")
        XCTAssertEqual(check, .accepted)
        XCTAssertEqual(personal.token, "lin_api_1")
        XCTAssertEqual(StubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "lin_api_1")
    }

    func testRefreshingKeepsTheRotatedTokens() async throws {
        StubProtocol.handler = { [issues] request in
            request.url?.path == "/oauth/token" ? (200, json(("lin_new", "r2"))) : (200, issues)
        }
        let (linear, rotating, _) = make(expiring(in: 60))
        _ = try await linear.openTasks()
        XCTAssertEqual(form(StubProtocol.requests.first)["refresh_token"], "r1")
        XCTAssertEqual(StubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer lin_new")
        XCTAssertEqual(rotating.read()?.refresh, "r2")
    }

    func testAnAuthenticationErrorIsRefreshedAndTriedOnce() async throws {
        StubProtocol.handler = { [issues, authError] request in
            if request.url?.path == "/oauth/token" { return (200, json(("lin_new", "r2"))) }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer lin_new" ? (200, issues) : (400, authError)
        }
        let (linear, _, _) = make(expiring(in: 3600))
        let tasks = try await linear.openTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(StubProtocol.requests.count, 3)
    }

    func testAPersonalKeyTurnedDownIsntRefreshed() async {
        StubProtocol.handler = { [authError] _ in (400, authError) }
        let personal = FakeTokens("revoked")
        let linear = LinearTasks(tokens: personal, session: StubProtocol.session())
        do {
            _ = try await linear.openTasks()
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .rejected)
        }
        XCTAssertEqual(StubProtocol.requests.count, 1)
        XCTAssertEqual(personal.token, "revoked")
    }

    func testARejectedRefreshSignsOut() async {
        StubProtocol.handler = { _ in (400, #"{"error":"invalid_grant"}"#) }
        let (linear, _, store) = make(expiring(in: 60))
        do {
            _ = try await linear.openTasks()
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .rejected)
        }
        XCTAssertNil(store.token)
        XCTAssertFalse(linear.hasToken)
        XCTAssertTrue(linear.wasSignedOut)
    }

    func testOfflineKeepsTheSignIn() async {
        StubProtocol.handler = { _ in (503, "") }
        let (linear, _, store) = make(expiring(in: -60))
        do {
            _ = try await linear.openTasks()
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .unreachable)
        }
        XCTAssertNotNil(store.token)
        XCTAssertFalse(linear.wasSignedOut)
    }

    func testATokenDoesntFollowARedirectOffLinear() async {
        StubProtocol.handler = { request in request.url?.host == "api.linear.app" ? (302, "") : (200, "{}") }
        StubProtocol.headers = { _ in ["Location": "https://evil.example/graphql"] }
        let (linear, _, _) = make(expiring(in: 3600))
        do {
            _ = try await linear.openTasks()
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(error as? TaskSourceProblem, .unreachable)
        }
        XCTAssertEqual(StubProtocol.requests.compactMap { $0.url?.host }, ["api.linear.app"])
    }

    func testDisconnectRevokesTheSignInAndClearsTheKeychain() async {
        StubProtocol.handler = { _ in (200, "") }
        let (linear, _, store) = make(expiring(in: 3600, access: "lin_oauth", refresh: "lin_refresh"))
        linear.disconnect()
        XCTAssertNil(store.token)
        XCTAssertFalse(linear.hasToken)
        await linear.revoking?.value
        XCTAssertEqual(StubProtocol.requests.map { $0.url?.absoluteString }, ["https://api.linear.app/oauth/revoke", "https://api.linear.app/oauth/revoke"])
        XCTAssertEqual(StubProtocol.requests.map { form($0) }, [
            ["token": "lin_refresh", "token_type_hint": "refresh_token"],
            ["token": "lin_oauth", "token_type_hint": "access_token"],
        ])
    }

    func testDisconnectingAPersonalKeyCallsNobody() async {
        let personal = FakeTokens("lin_api_1")
        let linear = LinearTasks(tokens: personal, session: StubProtocol.session())
        linear.disconnect()
        XCTAssertNil(personal.token)
        XCTAssertNil(linear.revoking)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }
}

// MARK: - Fallback

@MainActor
final class TaskSignInFallbackTests: SignInTestCase {
    func testWithoutAClientIDOnlyTheTokenIsOffered() {
        let coordinator = IntegrationsCoordinator(calendar: NoCalendar(), reminders: NoReminders(),
                                                  tasks: [GitHubTasks(tokens: FakeTokens("ghp"), session: StubProtocol.session()),
                                                          LinearTasks(tokens: FakeTokens(), session: StubProtocol.session())])
        XCTAssertFalse(coordinator.offersSignIn(.github))
        XCTAssertFalse(coordinator.offersSignIn(.linear))
        XCTAssertNil(coordinator.githubSignIn)
        XCTAssertNil(coordinator.linearSignIn)
        XCTAssertTrue(coordinator.isConnected(.github), "A pasted token stays connected")
        XCTAssertFalse(coordinator.isSignedIn(.github))
        XCTAssertFalse(coordinator.isConnected(.linear))
    }

    func testAnEmptyOrUnsetClientIDCountsAsNone() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plist: [String: String] = ["FGGitHubClientID": "", "FGLinearClientID": "$(LINEAR_CLIENT_ID)", "FGGitHubAppSlug": " focusguard "]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: folder.appending(path: "Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: folder))
        XCTAssertNil(StatusSync.infoValue("FGGitHubClientID", in: bundle))
        XCTAssertNil(StatusSync.infoValue("FGLinearClientID", in: bundle))
        XCTAssertEqual(StatusSync.infoValue("FGGitHubAppSlug", in: bundle), "focusguard")
    }

    func testWithAClientIDSigningInIsOffered() {
        let github = GitHubSignIn(clientID: "Iv1.abc", appSlug: nil, store: FakeTokens(), session: StubProtocol.session())
        let linear = LinearSignIn(clientID: "lin_client", store: FakeTokens(), session: StubProtocol.session())
        let coordinator = IntegrationsCoordinator(calendar: NoCalendar(), reminders: NoReminders(),
                                                  tasks: [GitHubTasks(tokens: FakeTokens(), signIn: github.tokens, session: StubProtocol.session()),
                                                          LinearTasks(tokens: FakeTokens(), signIn: linear.tokens, session: StubProtocol.session())],
                                                  githubSignIn: github, linearSignIn: linear)
        XCTAssertTrue(coordinator.offersSignIn(.github))
        XCTAssertTrue(coordinator.offersSignIn(.linear))
        XCTAssertFalse(coordinator.offersSignIn(.todoist))
        XCTAssertFalse(coordinator.isConnected(.github))

        github.tokens.save(SignInTokens(access: "ghu", refresh: "ghr", expiresAt: nil))
        XCTAssertTrue(coordinator.isConnected(.github))
        XCTAssertTrue(coordinator.isSignedIn(.github))

        coordinator.disconnect(.github)
        XCTAssertFalse(coordinator.isConnected(.github))
        XCTAssertFalse(github.tokens.isSignedIn)
    }

    func testBeingSignedOutShowsThroughTheCoordinator() async {
        StubProtocol.handler = { _ in (200, #"{"error":"bad_refresh_token"}"#) }
        let store = FakeTokens()
        let clock = clock
        let github = GitHubSignIn(clientID: "Iv1.abc", appSlug: nil, store: store, session: StubProtocol.session(), now: { clock.date })
        github.tokens.save(SignInTokens(access: "old", refresh: "ghr", expiresAt: clock.date.addingTimeInterval(60)))
        let tasks = GitHubTasks(tokens: FakeTokens(), signIn: github.tokens, session: StubProtocol.session())
        let coordinator = IntegrationsCoordinator(calendar: NoCalendar(), reminders: NoReminders(), tasks: [tasks], githubSignIn: github)
        _ = try? await tasks.openTasks()
        XCTAssertTrue(coordinator.wasSignedOut(.github))
        XCTAssertFalse(coordinator.isConnected(.github))
    }

    func testSignInsAndPastedTokensHaveTheirOwnKeychainItems() {
        let personal = TaskTokens.keychain(for: .github) as? KeychainTokenStore
        let signIn = TaskTokens.signInKeychain(for: .github) as? KeychainTokenStore
        XCTAssertEqual(personal?.service, signIn?.service)
        XCTAssertEqual(personal?.account, "github", "Existing connections stay where they are")
        XCTAssertNotEqual(personal?.account, signIn?.account)
    }
}
