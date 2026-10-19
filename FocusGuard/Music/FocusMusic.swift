import AppKit
import Foundation
import Observation

/// Focus music: the Spotify playlists the user saved, which one plays with
/// sessions, and keeping Spotify in step with the session (start, pause,
/// resume, end).
///
/// It only ever pauses or resumes music it started itself, so music the user
/// put on without a focus playlist picked is never touched.
@MainActor
@Observable
final class FocusMusic {
    let spotify = SpotifyPlayer()

    private(set) var playlists: [SavedPlaylist] = []
    /// The playlist sessions start with; nil means no music.
    private(set) var selectedURI: String?
    /// True while the music playing is the session's.
    private(set) var sessionOwnsPlayback = false

    var selected: SavedPlaylist? { playlists.first { $0.uri == selectedURI } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: SettingsKeys.Music.playlists),
           let saved = try? JSONDecoder().decode([SavedPlaylist].self, from: data) {
            playlists = saved
        }
        selectedURI = defaults.string(forKey: SettingsKeys.Music.selected)
        if selected == nil { selectedURI = nil }
    }

    // MARK: - Playlists

    enum AddResult: Equatable { case added, alreadySaved, notALink }

    /// Saves the playlist or album a share link points to, named and with
    /// its cover from Spotify's public link preview, and picks it.
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
        guard let uri = selected?.uri, spotify.isInstalled else { return }
        sessionOwnsPlayback = true
        spotify.play(uri)
    }

    /// "Play" on the session's music card when nothing is playing: the
    /// focus playlist becomes the session's, paused and stopped with it.
    func playSelected() {
        guard let uri = selected?.uri else { return }
        sessionOwnsPlayback = true
        spotify.play(uri)
    }

    /// Paused by the user or because they stepped away.
    func sessionPaused() {
        guard sessionOwnsPlayback else { return }
        spotify.pause()
    }

    func sessionResumed() {
        guard sessionOwnsPlayback else { return }
        spotify.resume()
    }

    /// Breaks are quiet: the session's music stops when it ends.
    func sessionEnded() {
        guard sessionOwnsPlayback else { return }
        sessionOwnsPlayback = false
        spotify.pause()
    }
}

/// A Spotify playlist or album saved for focus music.
struct SavedPlaylist: Codable, Equatable, Identifiable {
    /// `spotify:playlist:…` or `spotify:album:…`.
    let uri: String
    var title: String
    var imageURL: URL?

    var id: String { uri }
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
