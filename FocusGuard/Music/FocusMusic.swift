import AppKit
import Foundation
import Observation

/// Focus music: the playlists the user pinned (from Spotify or Apple
/// Music), which one plays with sessions, and keeping the music app in step
/// with the session (start, pause, resume, end).
///
/// It only ever pauses or resumes music it started itself, so music the user
/// put on without a focus playlist picked is never touched.
@MainActor
@Observable
final class FocusMusic {
    let spotify = MusicPlayer(service: .spotify)
    let appleMusic = MusicPlayer(service: .appleMusic)
    /// Spotify Web API sign-in, for search and the user's own playlists.
    let spotifyAccount = SpotifyAccount()

    private(set) var playlists: [SavedPlaylist] = []
    /// The playlist sessions start with; nil means no music.
    private(set) var selectedURI: String?
    /// The app whose music is the session's, while it is.
    private(set) var sessionService: MusicService?
    /// The app the music pane shows.
    private(set) var service: MusicService

    var sessionOwnsPlayback: Bool { sessionService != nil }
    var selected: SavedPlaylist? { playlists.first { $0.uri == selectedURI } }
    /// The player the music pane shows.
    var player: MusicPlayer { player(for: service) }
    /// Apps installed on this Mac, Spotify first. Apple Music ships with macOS.
    var availableServices: [MusicService] { MusicService.allCases.filter { player(for: $0).isInstalled } }

    func player(for service: MusicService) -> MusicPlayer {
        service == .spotify ? spotify : appleMusic
    }

    func playlists(for service: MusicService) -> [SavedPlaylist] {
        playlists.filter { $0.service == service }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        service = defaults.string(forKey: SettingsKeys.Music.service).flatMap(MusicService.init(rawValue:))
            ?? (NSWorkspace.shared.urlForApplication(withBundleIdentifier: MusicService.spotify.bundleID) != nil
                ? .spotify : .appleMusic)
        if let data = defaults.data(forKey: SettingsKeys.Music.playlists),
           let saved = try? JSONDecoder().decode([SavedPlaylist].self, from: data) {
            playlists = saved
        }
        selectedURI = defaults.string(forKey: SettingsKeys.Music.selected)
        if playlists.first(where: { $0.uri == selectedURI }) == nil { selectedURI = nil }
    }

    func show(_ service: MusicService) {
        self.service = service
        defaults.set(service.rawValue, forKey: SettingsKeys.Music.service)
    }

    // MARK: - Playlists

    enum AddResult: Equatable { case added, alreadySaved, notALink }

    /// Saves the Spotify playlist or album a share link points to, named and
    /// with its cover from Spotify's public link preview, and picks it.
    func add(link: String) async -> AddResult {
        guard let uri = SpotifyLink.uri(from: link) else { return .notALink }
        if playlists.contains(where: { $0.uri == uri }) {
            select(uri)
            return .alreadySaved
        }
        let preview = await SpotifyLink.preview(for: uri)
        playlists.append(SavedPlaylist(uri: uri,
                                       title: preview?.title ?? "Spotify playlist",
                                       imageURL: preview?.thumbnail))
        select(uri)
        return .added
    }

    func isPinned(_ uri: String) -> Bool { playlists.contains { $0.uri == uri } }

    /// Pins a Spotify playlist or album found by search or in the user's
    /// own playlists.
    func pin(_ item: SpotifyAccount.Item) {
        guard !isPinned(item.uri), SpotifyLink.uri(from: item.uri) != nil else { return }
        playlists.append(SavedPlaylist(uri: item.uri, title: item.name, imageURL: item.imageURL))
        save()
    }

    /// Pins an Apple Music library playlist; its cover (the first track's
    /// artwork) follows once Music hands it over.
    func pin(_ playlist: AppleMusicLibrary.Playlist) {
        guard !isPinned(playlist.uri) else { return }
        playlists.append(SavedPlaylist(uri: playlist.uri, title: playlist.name, imageURL: nil))
        save()
        Task {
            guard let cover = await AppleMusicLibrary.playlistArtwork(persistentID: playlist.persistentID),
                  let index = playlists.firstIndex(where: { $0.uri == playlist.uri }) else { return }
            playlists[index].imageURL = cover
            save()
        }
    }

    func remove(_ uri: String) {
        playlists.removeAll { $0.uri == uri }
        if selectedURI == uri { selectedURI = nil }
        save()
    }

    /// Picks the playlist sessions start with, or none.
    func select(_ uri: String?) {
        selectedURI = uri
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(playlists) {
            defaults.set(data, forKey: SettingsKeys.Music.playlists)
        }
        defaults.set(selectedURI, forKey: SettingsKeys.Music.selected)
    }

    // MARK: - Session boundaries

    func sessionStarted() {
        guard let playlist = selected, player(for: playlist.service).isInstalled else { return }
        sessionService = playlist.service
        player(for: playlist.service).play(playlist.uri)
    }

    /// Plays a saved playlist now. During a session it becomes the
    /// session's music, paused and stopped with it.
    func play(_ uri: String, inSession: Bool) {
        let service = MusicService.of(uri: uri)
        if inSession { sessionService = service }
        player(for: service).play(uri)
    }

    /// Paused by the user or because they stepped away.
    func sessionPaused() {
        guard let sessionService else { return }
        player(for: sessionService).pause()
    }

    func sessionResumed() {
        guard let sessionService else { return }
        player(for: sessionService).resume()
    }

    /// Breaks are quiet: the session's music stops when it ends.
    func sessionEnded() {
        guard let service = sessionService else { return }
        sessionService = nil
        player(for: service).pause()
    }
}

/// A playlist or album pinned for focus music.
struct SavedPlaylist: Codable, Equatable, Identifiable {
    /// `spotify:playlist:…`, `spotify:album:…` or `applemusic:playlist:…`.
    let uri: String
    var title: String
    var imageURL: URL?

    var id: String { uri }
    var service: MusicService { MusicService.of(uri: uri) }
}

/// Spotify share links ↔ URIs, and the public link preview (oEmbed) that
/// gives a playlist's name and cover without an account or API key.
enum SpotifyLink {
    static let kinds: Set<String> = ["playlist", "album"]

    /// `spotify:playlist:ID` from a share link
    /// (`https://open.spotify.com/intl-de/playlist/ID?si=…`) or a URI.
    static func uri(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts: [String]
        if trimmed.hasPrefix("spotify:") {
            parts = Array(trimmed.split(separator: ":").dropFirst().map(String.init))
        } else if let url = URL(string: trimmed), let host = url.host?.lowercased(),
                  host == "open.spotify.com" || host == "play.spotify.com" {
            parts = url.pathComponents.filter { $0 != "/" && !$0.hasPrefix("intl-") }
        } else {
            return nil
        }
        guard parts.count >= 2, kinds.contains(parts[0]) else { return nil }
        let id = parts[1]
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return "spotify:\(parts[0]):\(id)"
    }

    static func webURL(for uri: String) -> URL? {
        let parts = uri.split(separator: ":")
        guard parts.count == 3 else { return nil }
        return URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])")
    }

    struct Preview: Decodable {
        let title: String
        let thumbnail: URL?

        enum CodingKeys: String, CodingKey {
            case title
            case thumbnail = "thumbnail_url"
        }
    }

    static func preview(for uri: String) async -> Preview? {
        guard let web = webURL(for: uri),
              var components = URLComponents(string: "https://open.spotify.com/oembed") else { return nil }
        components.queryItems = [URLQueryItem(name: "url", value: web.absoluteString)]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Preview.self, from: data)
    }
}
