import AppKit
import Foundation
import Observation

/// The music apps FocusGuard can drive. Both are controlled over AppleScript:
/// free, no account or API key, and they play whatever the user's own app
/// can play. macOS asks once per app for permission to control it.
enum MusicService: String, Codable, CaseIterable, Identifiable {
    case spotify
    case appleMusic

    var id: String { rawValue }

    var name: String {
        switch self {
        case .spotify:    return "Spotify"
        case .appleMusic: return "Apple Music"
        }
    }

    /// The app's name in AppleScript.
    var scriptName: String {
        switch self {
        case .spotify:    return "Spotify"
        case .appleMusic: return "Music"
        }
    }

    var bundleID: String {
        switch self {
        case .spotify:    return "com.spotify.client"
        case .appleMusic: return "com.apple.Music"
        }
    }

    /// The service a saved playlist's id belongs to.
    static func of(uri: String) -> MusicService {
        uri.hasPrefix(AppleMusicLibrary.uriPrefix) ? .appleMusic : .spotify
    }
}

/// What's playing, read from the music app.
struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var album: String
    var artworkURL: URL?
    var duration: TimeInterval
    var position: TimeInterval
    var isPlaying: Bool
    var shuffling = false
    var repeating = false
    /// 0–100.
    var volume = 50
    /// Spotify's `spotify:track:…` or Music's persistent ID, to mark the
    /// playing song in a list.
    var trackID = ""
    var readAt: Date

    /// Where the track is now, counting on from the last read while playing.
    func position(at now: Date) -> TimeInterval {
        guard isPlaying else { return position }
        return min(duration, position + max(0, now.timeIntervalSince(readAt)))
    }

    /// "Awake by Tycho", for VoiceOver and anywhere a line will do.
    var summary: String { artist.isEmpty ? title : "\(title) by \(artist)" }

    /// Same track, for knowing when to fetch new artwork.
    var trackKey: String { "\(title)\t\(artist)\t\(album)" }
}

/// Reads and drives one music app. Scripts run on the shared AppleScript
/// queue, never the main thread, and reads never launch the app; only
/// starting a playlist does.
@MainActor
@Observable
final class MusicPlayer {
    let service: MusicService

    private(set) var nowPlaying: NowPlaying?
    /// The user turned down controlling this app in Privacy & Security.
    private(set) var notAuthorized = false
    /// The saved playlist FocusGuard last started, to mark it in the list.
    private(set) var lastStartedURI: String?

    @ObservationIgnored private var lastRefresh: Date = .distantPast
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var pendingVolume: Int?
    @ObservationIgnored private var sendingVolume = false
    /// Apple Music artwork for the current track, written to a cache file.
    @ObservationIgnored private var artwork: (key: String, url: URL?)?

    init(service: MusicService) {
        self.service = service
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: service.bundleID) != nil
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: service.bundleID).isEmpty
    }

    // MARK: - Reading

    /// Re-reads the player at most every `interval` seconds, while the app runs.
    func refresh(every interval: TimeInterval = 2) {
        guard Date().timeIntervalSince(lastRefresh) >= interval, !refreshing else { return }
        guard isRunning else {
            nowPlaying = nil
            return
        }
        lastRefresh = .now
        refreshing = true
        Task {
            let result = await AppleScript.run(MusicScripts.read(service))
            apply(result)
            if case .output(let text) = result {
                var track = MusicScripts.parse(text, readAt: .now)
                // Don't snap the volume slider back mid-drag.
                if sendingVolume || pendingVolume != nil, let volume = nowPlaying?.volume { track?.volume = volume }
                if service == .appleMusic, var current = track {
                    current.artworkURL = await appleMusicArtwork(for: current)
                    track = current
                }
                nowPlaying = track
            }
            refreshing = false
        }
    }

    /// Triggers the macOS permission prompt now, if the app is open to ask.
    func requestPermission() {
        guard isRunning else { return }
        lastRefresh = .distantPast
        refresh()
    }

    private func appleMusicArtwork(for track: NowPlaying) async -> URL? {
        if let artwork, artwork.key == track.trackKey { return artwork.url }
        let url = await AppleMusicLibrary.currentArtwork(key: track.trackKey)
        artwork = (track.trackKey, url)
        return url
    }

    // MARK: - Controls

    /// Plays a saved playlist, opening the app in the background first if it
    /// isn't running. A freshly launched app can ignore commands until it has
    /// loaded, so this keeps asking for a few seconds.
    func play(_ uri: String) {
        guard let script = MusicScripts.play(uri, on: service) else { return }
        lastStartedURI = uri
        Task {
            if !isRunning {
                await launchInBackground()
                for _ in 0..<8 {
                    try? await Task.sleep(for: .seconds(1))
                    apply(await AppleScript.run(script))
                    try? await Task.sleep(for: .milliseconds(500))
                    if case .output(let state) = await AppleScript.run(MusicScripts.state(service)), state == "playing" { break }
                }
            } else {
                apply(await AppleScript.run(script))
            }
            settle()
        }
    }

    /// Plays one song of a saved playlist or album, then the rest of it.
    func play(track trackID: String, in contextURI: String) {
        guard let script = MusicScripts.play(track: trackID, in: contextURI, on: service) else { return }
        lastStartedURI = contextURI
        Task {
            if !isRunning {
                await launchInBackground()
                try? await Task.sleep(for: .seconds(2))
            }
            apply(await AppleScript.run(script))
            settle()
        }
    }

    func pause() { command("pause") }
    func resume() { command("play") }
    func togglePlayPause() {
        nowPlaying?.isPlaying.toggle()
        command("playpause")
    }
    func next() { command("next track") }
    func previous() { command("previous track") }

    /// Jumps to `seconds` into the track.
    func seek(to seconds: TimeInterval) {
        guard var track = nowPlaying else { return }
        let target = min(max(0, seconds), track.duration)
        track.position = target
        track.readAt = .now
        nowPlaying = track
        command(String(format: "set player position to %.1f", target))
    }

    func toggleShuffle() {
        nowPlaying?.shuffling.toggle()
        command(MusicScripts.toggleShuffle(service))
    }

    func toggleRepeat() {
        let on = !(nowPlaying?.repeating ?? false)
        nowPlaying?.repeating = on
        command(MusicScripts.setRepeat(on, service))
    }

    /// Sets the volume (0–100). Slider drags send many values; only the
    /// latest one is sent once the previous change has gone through.
    func setVolume(_ volume: Int) {
        let clamped = min(100, max(0, volume))
        nowPlaying?.volume = clamped
        pendingVolume = clamped
        guard !sendingVolume, isRunning else { return }
        sendingVolume = true
        Task {
            while let next = pendingVolume {
                pendingVolume = nil
                apply(await AppleScript.run(MusicScripts.tell(service, "set sound volume to \(next)")))
            }
            sendingVolume = false
        }
    }

    private func command(_ verb: String) {
        guard isRunning else { return }
        Task {
            apply(await AppleScript.run(MusicScripts.tell(service, verb)))
            settle()
        }
    }

    /// Re-read shortly after a command so the player catches up.
    private func settle() {
        lastRefresh = .distantPast
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            refresh()
        }
    }

    func launchInBackground() async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: service.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private func apply(_ result: AppleScript.Result) {
        switch result {
        case .notAuthorized: notAuthorized = true
        case .output, .data: notAuthorized = false
        case .failed: break
        }
    }
}

/// The AppleScript for each app. Both answer the same read in the same
/// shape, so one parser serves both.
enum MusicScripts {
    static func tell(_ service: MusicService, _ body: String) -> String {
        "tell application \"\(service.scriptName)\" to \(body)"
    }

    /// Fields joined by tabs: state, name, artist, album, artwork URL,
    /// duration, position, shuffling, repeating, volume, track id. Apple Music has no
    /// artwork URL (it's fetched as data separately) and reports duration in
    /// seconds; Spotify in milliseconds.
    static func read(_ service: MusicService) -> String {
        let app = service.scriptName
        let fields: String
        switch service {
        case .spotify:
            fields = """
                (player state as text) & tab & (name of t) & tab & (artist of t) & tab & (album of t) ¬
                    & tab & (artwork url of t) & tab & (duration of t) & tab & (player position as text) ¬
                    & tab & (shuffling as text) & tab & (repeating as text) & tab & (sound volume as text) ¬
                    & tab & (id of t)
                """
        case .appleMusic:
            fields = """
                (player state as text) & tab & (name of t) & tab & (artist of t) & tab & (album of t) ¬
                    & tab & "" & tab & (duration of t as text) & tab & (player position as text) ¬
                    & tab & (shuffle enabled as text) & tab & ((song repeat is not off) as text) ¬
                    & tab & (sound volume as text) & tab & (persistent ID of t)
                """
        }
        return """
            if application "\(app)" is running then
                tell application "\(app)"
                    try
                        if player state is stopped then return "stopped"
                        set t to current track
                        return \(fields)
                    on error
                        return "stopped"
                    end try
                end tell
            end if
            return "stopped"
            """
    }

    static func state(_ service: MusicService) -> String {
        """
        if application "\(service.scriptName)" is running then
            tell application "\(service.scriptName)" to return player state as text
        end if
        return "stopped"
        """
    }

    /// Plays a saved playlist; nil for an id that isn't one of ours, so
    /// nothing unchecked reaches a script.
    static func play(_ uri: String, on service: MusicService) -> String? {
        switch service {
        case .spotify:
            guard SpotifyLink.webURL(for: uri) != nil else { return nil }
            return tell(service, "play track \"\(uri)\"")
        case .appleMusic:
            guard let id = AppleMusicLibrary.persistentID(from: uri) else { return nil }
            return tell(service, "play (first user playlist whose persistent ID is \"\(id)\")")
        }
    }

    /// Plays one song of a saved playlist or album, carrying on through the
    /// rest of it. Nil unless both ids are well formed.
    static func play(track trackID: String, in contextURI: String, on service: MusicService) -> String? {
        switch service {
        case .spotify:
            guard SpotifyLink.isPlayableItem(trackID), SpotifyLink.webURL(for: contextURI) != nil else { return nil }
            return tell(service, "play track \"\(trackID)\" in context \"\(contextURI)\"")
        case .appleMusic:
            guard let playlist = AppleMusicLibrary.persistentID(from: contextURI),
                  AppleMusicLibrary.isPersistentID(trackID) else { return nil }
            return tell(service, "play (first track of (first user playlist whose persistent ID is \"\(playlist)\") "
                        + "whose persistent ID is \"\(trackID)\")")
        }
    }

    static func toggleShuffle(_ service: MusicService) -> String {
        service == .spotify ? "set shuffling to not shuffling" : "set shuffle enabled to not shuffle enabled"
    }

    static func setRepeat(_ on: Bool, _ service: MusicService) -> String {
        service == .spotify ? "set repeating to \(on)" : "set song repeat to \(on ? "all" : "off")"
    }

    static func parse(_ output: String, readAt: Date) -> NowPlaying? {
        let fields = output.components(separatedBy: "\t")
        guard fields.count >= 7, fields[0] == "playing" || fields[0] == "paused", !fields[1].isEmpty else { return nil }
        // Spotify reports duration in milliseconds despite its dictionary
        // saying seconds; positions really are seconds, in the local format.
        let rawDuration = Double(fields[5].replacingOccurrences(of: ",", with: ".")) ?? 0
        let duration = rawDuration > 20_000 ? rawDuration / 1000 : rawDuration
        let position = Double(fields[6].replacingOccurrences(of: ",", with: ".")) ?? 0
        var track = NowPlaying(title: fields[1], artist: fields[2], album: fields[3],
                               artworkURL: fields[4].isEmpty ? nil : URL(string: fields[4]), duration: duration,
                               position: min(position, duration), isPlaying: fields[0] == "playing",
                               readAt: readAt)
        if fields.count >= 10 {
            track.shuffling = fields[7] == "true"
            track.repeating = fields[8] == "true"
            track.volume = Int(fields[9]) ?? track.volume
        }
        if fields.count >= 11 { track.trackID = fields[10] }
        return track
    }
}

/// Runs AppleScript off the main thread, one script at a time.
enum AppleScript {
    enum Result: Equatable {
        case output(String)
        case data(Data)
        case notAuthorized
        case failed
    }

    static func run(_ source: String) async -> Result {
        await withCheckedContinuation { continuation in
            AppleScriptQueue.shared.async {
                continuation.resume(returning: execute(source))
            }
        }
    }

    nonisolated private static func execute(_ source: String) -> Result {
        guard let script = NSAppleScript(source: source) else { return .failed }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            // -1743/-1744: not allowed to send Apple events to that app.
            return code == -1743 || code == -1744 ? .notAuthorized : .failed
        }
        if let text = descriptor.stringValue { return .output(text) }
        let data = descriptor.data
        return data.isEmpty ? .output("") : .data(data)
    }
}

/// One serial queue for every AppleScript FocusGuard runs (browser tabs,
/// music apps): NSAppleScript isn't safe to run on two threads at once, and
/// it blocks for up to a few hundred milliseconds, so never on the main thread.
enum AppleScriptQueue {
    static let shared = DispatchQueue(label: "com.anar.focusguard.applescript", qos: .userInitiated)
}
