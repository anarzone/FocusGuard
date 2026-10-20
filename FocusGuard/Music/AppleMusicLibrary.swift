import AppKit
import CryptoKit
import Foundation

/// The user's Apple Music library, read from the Music app over AppleScript:
/// their playlists to browse, search and pin, and artwork, which Music only
/// hands out as image data, so it's cached to files the views can load.
enum AppleMusicLibrary {
    /// Saved playlists from Apple Music use `applemusic:playlist:<persistent ID>`.
    static let uriPrefix = "applemusic:playlist:"

    struct Playlist: Equatable, Identifiable {
        let persistentID: String
        let name: String
        var id: String { persistentID }
        var uri: String { AppleMusicLibrary.uriPrefix + persistentID }
    }

    static func uri(for persistentID: String) -> String { uriPrefix + persistentID }

    static func isPersistentID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32 && id.allSatisfy(\.isHexDigit)
    }

    /// The persistent ID in a saved playlist's id, if it's a well-formed one
    /// (hex only, so it can't break out of a script).
    static func persistentID(from uri: String) -> String? {
        guard uri.hasPrefix(uriPrefix) else { return nil }
        let id = String(uri.dropFirst(uriPrefix.count))
        return isPersistentID(id) ? id : nil
    }

    // MARK: - Playlists

    enum LoadResult: Equatable {
        case playlists([Playlist])
        case notAuthorized
        case failed
    }

    /// Every playlist the user made or added (not folders, not the built-in
    /// lists like Library or Music Videos), opening Music in the background
    /// if needed.
    @MainActor
    static func playlists(using player: MusicPlayer) async -> LoadResult {
        if !player.isRunning {
            await player.launchInBackground()
            try? await Task.sleep(for: .seconds(2))
        }
        switch await AppleScript.run(listScript) {
        case .output(let text): return .playlists(parsePlaylists(text))
        case .notAuthorized: return .notAuthorized
        case .data, .failed: return .failed
        }
    }

    /// Persistent ID and name per line, tab-separated.
    static let listScript = """
        tell application "Music"
            set ps to every user playlist whose special kind is none
            set out to {}
            repeat with p in ps
                set end of out to (persistent ID of p) & tab & (name of p)
            end repeat
            set AppleScript's text item delimiters to linefeed
            return out as text
        end tell
        """

    static func parsePlaylists(_ text: String) -> [Playlist] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, persistentID(from: uriPrefix + parts[0]) != nil,
                  !parts[1].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return Playlist(persistentID: parts[0], name: parts[1])
        }
    }

    /// Playlists whose name contains every word typed, in any order and case.
    static func filter(_ playlists: [Playlist], by query: String) -> [Playlist] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return playlists }
        return playlists.filter { playlist in
            let name = playlist.name.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
    }

    // MARK: - Songs

    /// Persistent ID, name, artist and seconds per line, tab-separated. Each
    /// property comes back for every song in one Apple event.
    static func tracksScript(persistentID: String) -> String {
        """
        tell application "Music"
            set p to (first user playlist whose persistent ID is "\(persistentID)")
            set ids to persistent ID of tracks of p
            set nms to name of tracks of p
            set ars to artist of tracks of p
            set durs to duration of tracks of p
        end tell
        set out to {}
        repeat with i from 1 to count of ids
            set end of out to (item i of ids) & tab & (item i of nms) & tab & (item i of ars) & tab & ((item i of durs) as text)
        end repeat
        set AppleScript's text item delimiters to linefeed
        return out as text
        """
    }

    @MainActor
    static func tracks(persistentID: String, using player: MusicPlayer) async -> TrackList {
        guard isPersistentID(persistentID) else { return .failed }
        if !player.isRunning {
            await player.launchInBackground()
            try? await Task.sleep(for: .seconds(2))
        }
        switch await AppleScript.run(tracksScript(persistentID: persistentID)) {
        case .output(let text): return .tracks(parseTracks(text))
        case .notAuthorized: return .notAuthorized
        case .data, .failed: return .failed
        }
    }

    static func parseTracks(_ text: String) -> [PlaylistTrack] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4, isPersistentID(parts[0]), !parts[1].isEmpty else { return nil }
            let seconds = Double(parts[3].replacingOccurrences(of: ",", with: ".")) ?? 0
            return PlaylistTrack(id: parts[0], title: parts[1], artist: parts[2], duration: seconds)
        }
    }

    // MARK: - Artwork

    /// The current track's artwork as a cached file.
    static func currentArtwork(key: String) async -> URL? {
        await artwork(key: "track-" + key,
                      script: "tell application \"Music\" to return raw data of artwork 1 of current track")
    }

    /// A pinned playlist's cover: its first track's artwork.
    static func playlistArtwork(persistentID: String) async -> URL? {
        guard self.persistentID(from: uri(for: persistentID)) != nil else { return nil }
        return await artwork(key: "playlist-" + persistentID, script: """
            tell application "Music"
                return raw data of artwork 1 of track 1 of (first user playlist whose persistent ID is "\(persistentID)")
            end tell
            """)
    }

    private static func artwork(key: String, script: String) async -> URL? {
        let name = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let file = cacheDirectory.appendingPathComponent(name + ".img")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard case .data(let data) = await AppleScript.run("try\n\(script)\non error\nreturn \"\"\nend try"),
              NSImage(data: data) != nil else { return nil }
        try? data.write(to: file)
        return file
    }

    private static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("music-artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
