import XCTest
@testable import FocusGuard

@MainActor
final class SpotifyAccountTests: XCTestCase {
    // MARK: - PKCE

    func testChallengeIsBase64URLOfSHA256WithoutPadding() {
        // Expected value computed independently (Python hashlib + urlsafe_b64encode).
        XCTAssertEqual(PKCE.challenge(for: "focusguard-pkce-test-verifier-0123456789abcdefghijklmnopqrstuvwxyz"),
                       "Kk8d-ZHp8S9Q40f4pyouhMXM6Jou6HkSwtGzXJgd5iU")
    }

    func testVerifiersAreLongRandomAndUnreserved() {
        let a = PKCE.verifier(), b = PKCE.verifier()
        XCTAssertEqual(a.count, 64)
        XCTAssertNotEqual(a, b)
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(a.unicodeScalars.allSatisfy(unreserved.contains))
    }

    func testAuthorizeURLCarriesTheLoopbackRedirectAndChallenge() throws {
        let url = try XCTUnwrap(PKCE.authorizeURL(clientID: "abc123", redirect: "http://127.0.0.1:51234/callback",
                                                  verifier: "v", state: "s", scopes: SpotifyAccount.scopes))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "accounts.spotify.com")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:51234/callback")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["code_challenge"], PKCE.challenge(for: "v"))
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["state"], "s")
    }

    func testFormEncodingEscapesEverythingButUnreserved() {
        XCTAssertEqual(PKCE.formEncoded(["redirect_uri": "http://127.0.0.1:5/callback", "a": "x y&z"]),
                       "a=x%20y%26z&redirect_uri=http%3A%2F%2F127.0.0.1%3A5%2Fcallback")
    }

    func testOnlyTheCallbackRequestIsAccepted() {
        XCTAssertEqual(PKCE.callbackParameters(fromRequestLine: "GET /callback?code=abc&state=xyz HTTP/1.1"),
                       ["code": "abc", "state": "xyz"])
        XCTAssertEqual(PKCE.callbackParameters(fromRequestLine: "GET /callback?error=access_denied&state=xyz HTTP/1.1"),
                       ["error": "access_denied", "state": "xyz"])
        XCTAssertNil(PKCE.callbackParameters(fromRequestLine: "GET /favicon.ico HTTP/1.1"))
        XCTAssertNil(PKCE.callbackParameters(fromRequestLine: "POST /callback?code=abc HTTP/1.1"))
    }

    func testLoopbackReceiverCatchesTheRedirectAndAnswersTheBrowser() async throws {
        let receiver = LoopbackReceiver()
        let port = try await receiver.start()
        XCTAssertGreaterThan(port, 0)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/callback?code=the-code&state=st"))
        async let page = URLSession.shared.data(from: url)
        let parameters = try await receiver.waitForCallback()
        XCTAssertEqual(parameters["code"], "the-code")
        XCTAssertEqual(parameters["state"], "st")
        let (data, _) = try await page
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Signed in to Spotify"))
    }

    // MARK: - API results

    func testSearchResultsSkipNullsAndUnknownURIs() throws {
        let json = """
            {"playlists":{"items":[null,
              {"uri":"spotify:playlist:37i9dQZF1DWWQRwui0ExPn","name":"lofi beats",
               "images":[{"url":"https://i.scdn.co/image/a"}],"owner":{"display_name":"Spotify"}},
              {"uri":"spotify:show:abc","name":"Not a playlist"}]},
             "albums":{"items":[{"uri":"spotify:album:4aawyAB9vmqN3uQ7FjRGTy","name":"Global Warming",
               "images":[],"artists":[{"name":"Pitbull"}]}]}}
            """
        let result = try JSONDecoder().decode(SpotifyAccount.SearchResult.self, from: Data(json.utf8))
        let playlists = result.playlists?.items.compactMap { $0?.item } ?? []
        let albums = result.albums?.items.compactMap { $0?.item } ?? []
        XCTAssertEqual(playlists.map(\.name), ["lofi beats"])
        XCTAssertEqual(playlists.first?.subtitle, "Playlist · Spotify")
        XCTAssertEqual(playlists.first?.imageURL?.absoluteString, "https://i.scdn.co/image/a")
        XCTAssertEqual(albums.first?.subtitle, "Album · Pitbull")
        XCTAssertNil(albums.first?.imageURL)
    }

    func testPlaylistSongsReadTheNewAndOldShapes() throws {
        let json = """
            {"items":[
              {"item":{"uri":"spotify:track:aaa111","name":"Awake","duration_ms":280500,"artists":[{"name":"Tycho"}]}},
              {"track":{"uri":"spotify:track:bbb222","name":"Dive","duration_ms":300000,"artists":[{"name":"Tycho"},{"name":"X"}]}},
              {"item":{"uri":"spotify:local:Artist:Album:Song:200","name":"Local file","duration_ms":200000}},
              {"item":{"uri":"spotify:episode:ccc333","name":"Deep work, episode 4","duration_ms":1800000,"show":{"name":"Focus Pod"}}},
              null],
             "next":null}
            """
        let page = try JSONDecoder().decode(SpotifyAccount.Page<SpotifyAccount.APIPlaylistItem>.self, from: Data(json.utf8))
        let tracks = page.items.compactMap { $0?.playable?.track }
        XCTAssertTrue(page.hasItems)
        XCTAssertNil(page.next)
        XCTAssertEqual(tracks.map(\.title), ["Awake", "Dive", "Deep work, episode 4"])
        XCTAssertEqual(tracks[0].duration, 280.5, accuracy: 0.01)
        XCTAssertEqual(tracks[1].artist, "Tycho, X")
        XCTAssertEqual(tracks[2].artist, "Focus Pod")
    }

    func testAPlaylistWithItsSongsLeftOutIsTold() throws {
        // Spotify leaves the songs out of playlists the user doesn't own.
        let page = try JSONDecoder().decode(SpotifyAccount.Page<SpotifyAccount.APIPlaylistItem>.self,
                                            from: Data(#"{"next":null}"#.utf8))
        XCTAssertFalse(page.hasItems)
    }

    func testSongsNeedSignInWhenSignedOut() async {
        let account = SpotifyAccount(clientID: "abc123", keychain: MemoryStore())
        let music = FocusMusic(defaults: UserDefaults(suiteName: "SpotifyAccountTests-\(UUID().uuidString)")!,
                               spotifyAccount: account)
        let list = await music.tracks(of: "spotify:playlist:37i9dQZF1DWWQRwui0ExPn")
        XCTAssertEqual(list, .needsSignIn)
    }

    // MARK: - Account state

    final class MemoryStore: TokenStore {
        var token: String?
        init(_ token: String? = nil) { self.token = token }
        func read() -> String? { token }
        func write(_ token: String) { self.token = token }
        func delete() { token = nil }
    }

    func testWithoutAClientIDSearchIsOff() {
        let account = SpotifyAccount(clientID: nil, keychain: MemoryStore("refresh"))
        XCTAssertFalse(account.isConfigured)
        XCTAssertFalse(account.isSignedIn)
    }

    func testAStoredLoginCountsAsSignedInAndSigningOutForgetsIt() {
        let store = MemoryStore("refresh")
        let account = SpotifyAccount(clientID: "abc123", keychain: store)
        XCTAssertTrue(account.isSignedIn)
        account.signOut()
        XCTAssertFalse(account.isSignedIn)
        XCTAssertNil(store.token)
    }

    func testPinningASearchResultAddsItOnce() {
        let defaults = UserDefaults(suiteName: "SpotifyAccountTests-\(UUID().uuidString)")!
        let music = FocusMusic(defaults: defaults)
        let item = SpotifyAccount.Item(uri: "spotify:playlist:37i9dQZF1DWWQRwui0ExPn", name: "lofi beats",
                                       subtitle: "Playlist", imageURL: nil)
        music.pin(item)
        music.pin(item)
        XCTAssertEqual(music.playlists.map(\.title), ["lofi beats"])
        XCTAssertEqual(music.playlists.first?.service, .spotify)
    }

    func testTheFirstPinBecomesTheSessionPlaylistButLaterOnesDont() {
        let defaults = UserDefaults(suiteName: "SpotifyAccountTests-\(UUID().uuidString)")!
        let music = FocusMusic(defaults: defaults)
        music.pin(SpotifyAccount.Item(uri: "spotify:playlist:aaa111", name: "First", subtitle: "", imageURL: nil))
        music.pin(AppleMusicLibrary.Playlist(persistentID: "ABC123", name: "Second"))
        XCTAssertEqual(music.selected?.title, "First")
        music.select(nil)
        music.pin(SpotifyAccount.Item(uri: "spotify:playlist:bbb222", name: "Third", subtitle: "", imageURL: nil))
        XCTAssertEqual(music.selected?.title, "Third")
    }
}
