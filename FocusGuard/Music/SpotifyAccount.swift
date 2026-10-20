import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import Security

/// Sign-in to Spotify's Web API, for searching Spotify and listing the
/// user's own playlists. Playback never needs it — that goes through the
/// app over AppleScript.
///
/// Uses FocusGuard's own developer app (its Client ID is in Info.plist).
/// Spotify keeps such apps in development mode, which only lets up to five
/// accounts the developer added in Spotify's dashboard sign in; anyone else
/// gets a 403 and keeps adding playlists by link.
///
/// Sign-in is Authorization Code with PKCE (no secret in the app): the
/// browser opens Spotify's consent page and comes back to a listener on
/// 127.0.0.1:47181 that only lives for the sign-in. (Spotify's docs allow
/// registering a loopback address without a port, but its dashboard
/// rejects one, so the registered redirect has this fixed port.) The refresh token is kept in
/// the Keychain.
@MainActor
@Observable
final class SpotifyAccount {
    enum Problem: Equatable {
        /// Signed in, but this account isn't on the developer app's list.
        case notAllowed
        case signInFailed
        case requestFailed
    }

    private(set) var isSignedIn: Bool
    private(set) var problem: Problem?
    private(set) var signingIn = false

    let clientID: String?
    var isConfigured: Bool { clientID != nil }

    @ObservationIgnored private var accessToken: (value: String, expires: Date)?
    @ObservationIgnored private var receiver: LoopbackReceiver?
    @ObservationIgnored private let keychain: TokenStore
    @ObservationIgnored private let defaults: UserDefaults
    /// The permissions Spotify actually granted, from the last token.
    private(set) var grantedScopes: Set<String>

    /// Playlists for "Your playlists" and songs; playback state for what's
    /// playing, its playlist and up next; playback control for Play.
    static let scopes = "playlist-read-private playlist-read-collaborative "
        + "user-read-currently-playing user-read-playback-state user-modify-playback-state"
    static let grantedScopesKey = "spotify.grantedScopes"

    /// Can see what's playing (its playlist, up next) and start playback.
    var hasPlaybackAccess: Bool {
        grantedScopes.isSuperset(of: ["user-read-playback-state", "user-modify-playback-state"])
    }
    /// Signed in before playback access was asked for: one more sign-in adds it.
    var needsMoreAccess: Bool { isSignedIn && !hasPlaybackAccess }
    /// Must match the redirect URI registered for the Client ID.
    static let redirectPort: UInt16 = 47181

    init(clientID: String? = SpotifyAccount.bundledClientID, keychain: TokenStore = KeychainTokenStore(),
         defaults: UserDefaults = .standard) {
        self.clientID = clientID
        self.keychain = keychain
        self.defaults = defaults
        self.isSignedIn = clientID != nil && keychain.read() != nil
        self.grantedScopes = Set(defaults.stringArray(forKey: Self.grantedScopesKey) ?? [])
    }

    nonisolated static var bundledClientID: String? {
        let id = (Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return id.isEmpty || id.hasPrefix("$(") ? nil : id
    }

    // MARK: - Sign in

    func signIn() async {
        guard let clientID, !signingIn else { return }
        signingIn = true
        problem = nil
        defer { signingIn = false }

        let verifier = PKCE.verifier()
        let state = PKCE.verifier()
        let receiver = LoopbackReceiver()
        self.receiver = receiver
        defer { self.receiver = nil }
        do {
            let port = try await receiver.start(port: Self.redirectPort)
            let redirect = "http://127.0.0.1:\(port)/callback"
            guard let url = PKCE.authorizeURL(clientID: clientID, redirect: redirect, verifier: verifier,
                                              state: state, scopes: Self.scopes) else { throw URLError(.badURL) }
            NSWorkspace.shared.open(url)
            let callback = try await receiver.waitForCallback()
            guard callback["state"] == state, let code = callback["code"] else {
                problem = callback["error"] == "access_denied" ? nil : .signInFailed
                return
            }
            let tokens = try await requestTokens([
                "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
                "client_id": clientID, "code_verifier": verifier,
            ])
            store(tokens)
        } catch is CancellationError {
            receiver.stop()
        } catch {
            receiver.stop()
            problem = .signInFailed
        }
    }

    /// Gives up waiting for the browser.
    func cancelSignIn() {
        receiver?.stop()
    }

    func signOut() {
        keychain.delete()
        accessToken = nil
        isSignedIn = false
        problem = nil
        grantedScopes = []
        defaults.removeObject(forKey: Self.grantedScopesKey)
    }

    // MARK: - Requests

    struct Item: Equatable, Identifiable {
        let uri: String
        let name: String
        let subtitle: String
        let imageURL: URL?
        var id: String { uri }
    }

    /// The playlists the user made or follows.
    func myPlaylists() async -> [Item]? {
        guard let page: Page<APIPlaylist> = await get("me/playlists", query: ["limit": "50"]) else { return nil }
        return page.items.compactMap { $0?.item }
    }

    /// Playlists and albums matching `query`. Development-mode apps get at
    /// most 10 of each.
    func search(_ query: String) async -> [Item]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let result: SearchResult = await get("search", query: ["q": trimmed, "type": "playlist,album", "limit": "10"])
        else { return nil }
        let playlists = result.playlists?.items.compactMap { $0?.item } ?? []
        let albums = result.albums?.items.compactMap { $0?.item } ?? []
        return playlists + albums
    }

    /// The songs of a playlist or album, up to 200. Spotify only lists a
    /// playlist's songs if the user made it or collaborates on it; for any
    /// other it answers 403 or leaves the songs out.
    func tracks(of uri: String) async -> TrackList {
        guard isSignedIn else { return .needsSignIn }
        let parts = uri.split(separator: ":")
        guard SpotifyLink.webURL(for: uri) != nil, parts.count == 3 else { return .failed }
        let isAlbum = parts[1] == "album"
        let path = isAlbum ? "albums/\(parts[2])/tracks" : "playlists/\(parts[2])/items"
        var tracks: [PlaylistTrack] = []
        var offset = 0
        while tracks.count < 200 {
            var query = ["limit": "50", "offset": "\(offset)"]
            if !isAlbum { query["additional_types"] = "track,episode" }
            let page: TrackPage
            if isAlbum {
                switch await fetch(path, query: query) as Fetch<Page<APITrack>> {
                case .ok(let result): page = TrackPage(tracks: result.items.compactMap { $0?.track }, more: result.next != nil)
                case .status(403), .status(404): return .notShared
                case .status, .failed: return tracks.isEmpty ? .failed : .tracks(tracks)
                }
            } else {
                switch await fetch(path, query: query) as Fetch<Page<APIPlaylistItem>> {
                case .ok(let result) where !result.hasItems: return .notShared
                case .ok(let result): page = TrackPage(tracks: result.items.compactMap { $0?.playable?.track }, more: result.next != nil)
                case .status(403), .status(404): return .notShared
                case .status, .failed: return tracks.isEmpty ? .failed : .tracks(tracks)
                }
            }
            tracks += page.tracks
            guard page.more else { break }
            offset += 50
        }
        return .tracks(tracks)
    }

    // MARK: - Playback (Premium)

    /// What Spotify is playing and from where, on any of the user's devices.
    struct Playback: Equatable {
        /// The playlist or album it's playing from; nil for a single song or radio.
        let contextURI: String?
        let trackURI: String?
        let isPlaying: Bool
    }

    struct APIPlayback: Decodable {
        struct Context: Decodable { let uri: String? }
        let is_playing: Bool?
        let context: Context?
        let item: APITrack?

        var playback: Playback {
            // Only playlists and albums: an artist page or radio isn't one the pane shows.
            Playback(contextURI: context?.uri.flatMap { SpotifyLink.uri(from: $0) },
                     trackURI: item?.uri, isPlaying: is_playing ?? false)
        }
    }

    struct APIQueue: Decodable {
        let currently_playing: APITrack?
        let queue: [APITrack?]?
    }

    /// Nil when it couldn't be read; a nil context when nothing is playing.
    func currentPlayback() async -> Playback? {
        guard hasPlaybackAccess else { return nil }
        switch await fetch("me/player/currently-playing", query: [:]) as Fetch<APIPlayback> {
        case .ok(let state): return state.playback
        case .status(204): return Playback(contextURI: nil, trackURI: nil, isPlaying: false)
        case .status, .failed: return nil
        }
    }

    /// What plays next (Spotify shares about 20), whatever the playlist.
    func upNext() async -> [PlaylistTrack]? {
        guard hasPlaybackAccess else { return nil }
        guard case .ok(let result) = await fetch("me/player/queue", query: [:]) as Fetch<APIQueue> else { return nil }
        return (result.queue ?? []).compactMap { $0?.track }
    }

    /// Starts a playlist or album on the active Spotify device, from
    /// `trackURI` if given. False when there's no active device or access,
    /// so the caller can fall back to the app.
    func play(context uri: String, startingAt trackURI: String?) async -> Bool {
        guard hasPlaybackAccess, SpotifyLink.webURL(for: uri) != nil,
              let body = SpotifyAccount.playBody(context: uri, startingAt: trackURI) else { return false }
        return await send("PUT", "me/player/play", body: body).map { (200..<300).contains($0) } ?? false
    }

    static func playBody(context uri: String, startingAt trackURI: String?) -> Data? {
        var body: [String: Any] = ["context_uri": uri]
        if let trackURI, SpotifyLink.isPlayableItem(trackURI) { body["offset"] = ["uri": trackURI] }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// A Web API write; the HTTP status, or nil if it never got an answer.
    private func send(_ method: String, _ path: String, body: Data) async -> Int? {
        guard let token = await validAccessToken(),
              let url = URL(string: "https://api.spotify.com/v1/" + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 401 { accessToken = nil }
        return status
    }

    private struct TrackPage {
        let tracks: [PlaylistTrack]
        let more: Bool
    }

    enum Fetch<T> {
        case ok(T)
        case status(Int)
        case failed
    }

    /// A Web API GET, with the HTTP status when it isn't a success.
    private func fetch<T: Decodable>(_ path: String, query: [String: String]) async -> Fetch<T> {
        guard let token = await validAccessToken(),
              var components = URLComponents(string: "https://api.spotify.com/v1/" + path) else { return .failed }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return .failed }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .failed }
        if status == 401 { accessToken = nil }
        guard status == 200 else { return .status(status) }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { return .failed }
        return .ok(decoded)
    }

    /// `fetch`, recording what went wrong for the pane to explain.
    private func get<T: Decodable>(_ path: String, query: [String: String]) async -> T? {
        switch await fetch(path, query: query) as Fetch<T> {
        case .ok(let value):
            problem = nil
            return value
        case .status(403):
            problem = .notAllowed
        case .status, .failed:
            problem = .requestFailed
        }
        return nil
    }

    private func validAccessToken() async -> String? {
        if let accessToken, accessToken.expires > .now.addingTimeInterval(30) { return accessToken.value }
        guard let clientID, let refresh = keychain.read() else {
            isSignedIn = false
            return nil
        }
        guard let tokens = try? await requestTokens([
            "grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID,
        ]) else {
            // Refresh tokens expire after six months, or the user revoked access.
            signOut()
            return nil
        }
        store(tokens)
        return tokens.accessToken
    }

    private func store(_ tokens: Tokens) {
        accessToken = (tokens.accessToken, .now.addingTimeInterval(TimeInterval(tokens.expiresIn)))
        // Spotify may rotate the refresh token; keep the newest.
        if let refresh = tokens.refreshToken { keychain.write(refresh) }
        if let scope = tokens.scope {
            grantedScopes = Set(scope.split(separator: " ").map(String.init))
            defaults.set(Array(grantedScopes).sorted(), forKey: Self.grantedScopesKey)
        }
        isSignedIn = true
    }

    private func requestTokens(_ form: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = PKCE.formEncoded(form).data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
        return try JSONDecoder().decode(Tokens.self, from: data)
    }

    // MARK: - API shapes

    struct Tokens: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        /// Space-separated permissions granted.
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
        }
    }

    /// Spotify sometimes returns null entries in result lists.
    struct Page<Element: Decodable>: Decodable {
        let items: [Element?]
        let next: String?
        /// False when Spotify left the list out (a playlist it won't share).
        let hasItems: Bool

        enum CodingKeys: String, CodingKey { case items, next }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let items = try container.decodeIfPresent([Element?].self, forKey: .items)
            self.items = items ?? []
            hasItems = items != nil
            next = try container.decodeIfPresent(String.self, forKey: .next)
        }
    }

    struct APITrack: Decodable {
        let uri: String
        let name: String
        let duration_ms: Int?
        let artists: [APIArtist]?
        /// Podcast episodes in playlists carry a show instead of artists.
        let show: APIShow?

        var track: PlaylistTrack? {
            guard SpotifyLink.isPlayableItem(uri) else { return nil }   // skips local files
            let by = artists?.map(\.name).joined(separator: ", ") ?? show?.name ?? ""
            return PlaylistTrack(id: uri, title: name, artist: by, duration: Double(duration_ms ?? 0) / 1000)
        }
    }

    struct APIShow: Decodable { let name: String }

    /// A playlist entry. Spotify renamed `track` to `item` in February 2026;
    /// either is read.
    struct APIPlaylistItem: Decodable {
        let item: APITrack?
        let track: APITrack?
        var playable: APITrack? { item ?? track }
    }

    struct APIImage: Decodable { let url: URL? }
    struct APIOwner: Decodable { let display_name: String? }
    struct APIArtist: Decodable { let name: String }

    struct APIPlaylist: Decodable {
        let uri: String
        let name: String
        let images: [APIImage]?
        let owner: APIOwner?

        var item: Item? {
            guard SpotifyLink.uri(from: uri) != nil else { return nil }
            return Item(uri: uri, name: name, subtitle: owner?.display_name.map { "Playlist · \($0)" } ?? "Playlist",
                        imageURL: images?.first?.url)
        }
    }

    struct APIAlbum: Decodable {
        let uri: String
        let name: String
        let images: [APIImage]?
        let artists: [APIArtist]?

        var item: Item? {
            guard SpotifyLink.uri(from: uri) != nil else { return nil }
            let artist = artists?.map(\.name).joined(separator: ", ")
            return Item(uri: uri, name: name, subtitle: artist.map { "Album · \($0)" } ?? "Album",
                        imageURL: images?.first?.url)
        }
    }

    struct SearchResult: Decodable {
        let playlists: Page<APIPlaylist>?
        let albums: Page<APIAlbum>?
    }
}

// MARK: - PKCE

enum PKCE {
    /// 64 random characters from the unreserved set.
    static func verifier() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<64).map { _ in chars.randomElement(using: &generator)! })
    }

    /// base64url(SHA-256(verifier)) without padding.
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func authorizeURL(clientID: String, redirect: String, verifier: String, state: String, scopes: String) -> URL? {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scopes),
        ]
        return components?.url
    }

    static func formEncoded(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    /// Query parameters of a request line like `GET /callback?code=…&state=… HTTP/1.1`.
    static func callbackParameters(fromRequestLine line: String) -> [String: String]? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
              components.path == "/callback" else { return nil }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] { result[item.name] = item.value ?? "" }
        return result
    }
}

// MARK: - Loopback receiver

/// A one-shot HTTP listener on 127.0.0.1 for the sign-in redirect. Only
/// reachable from this Mac, and gone once the redirect arrives or after five
/// minutes.
final class LoopbackReceiver: @unchecked Sendable {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    /// A redirect that arrived before anyone waited for it (an account that
    /// already approved FocusGuard bounces straight back).
    private var early: Result<[String: String], Error>?
    private let queue = DispatchQueue(label: "com.anar.focusguard.spotify-signin")

    /// Listens on 127.0.0.1, on `port` or any free one if nil.
    func start(port: UInt16? = nil) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let local = port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: local)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    ready.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    ready.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let early = self.early {
                    self.early = nil
                    continuation.resume(with: early)
                    return
                }
                self.continuation = continuation
                self.queue.asyncAfter(deadline: .now() + 300) { self.finish(.failure(URLError(.timedOut))) }
            }
        }
    }

    func stop() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let line = request.components(separatedBy: "\r\n").first ?? ""
            let parameters = PKCE.callbackParameters(fromRequestLine: line)
            let body = parameters?["code"] != nil
                ? "Signed in to Spotify. You can close this tab and go back to FocusGuard."
                : "FocusGuard didn't get permission from Spotify. You can close this tab."
            let html = "<!doctype html><meta charset=utf-8><title>FocusGuard</title>"
                + "<body style=\"font:16px -apple-system;margin:4em;text-align:center\">\(body)</body>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if let parameters { self?.finish(.success(parameters)) }
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        listener?.cancel()
        listener = nil
        guard let continuation else {
            if early == nil, case .success = result { early = result }
            return
        }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

// MARK: - Keychain

protocol TokenStore {
    func read() -> String?
    func write(_ token: String)
    func delete()
}

/// The refresh token as a generic password in the login keychain.
struct KeychainTokenStore: TokenStore {
    var service = "com.anar.focusguard.spotify"
    var account = "refresh-token"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ token: String) {
        let data = Data(token.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
