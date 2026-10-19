import AppKit
import Foundation
import Observation

/// What Spotify is playing, read from the desktop app.
struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var album: String
    var artworkURL: URL?
    var duration: TimeInterval
    var position: TimeInterval
    var isPlaying: Bool
    var readAt: Date

    /// Where the track is now, counting on from the last read while playing.
    func position(at now: Date) -> TimeInterval {
        guard isPlaying else { return position }
        return min(duration, position + max(0, now.timeIntervalSince(readAt)))
    }
}

/// Talks to the Spotify desktop app over AppleScript: free, no account or
/// API key, and it plays whatever the user's own Spotify can play. macOS asks
/// once for permission ("FocusGuard wants to control Spotify").
///
/// Scripts run on the shared AppleScript queue, never the main thread, and
/// reads never launch Spotify; only starting a session's playlist does.
@MainActor
@Observable
final class SpotifyPlayer {
    static let bundleID = "com.spotify.client"

    private(set) var nowPlaying: NowPlaying?
    /// The user turned down "control Spotify" in Privacy & Security.
    private(set) var notAuthorized = false

    @ObservationIgnored private var lastRefresh: Date = .distantPast
    @ObservationIgnored private var refreshing = false

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    // MARK: - Reading

    /// Re-reads the player at most every `interval` seconds, while Spotify runs.
    func refresh(every interval: TimeInterval = 2) {
        guard Date().timeIntervalSince(lastRefresh) >= interval, !refreshing else { return }
        guard isRunning else {
            nowPlaying = nil
            return
        }
        lastRefresh = .now
        refreshing = true
        Task {
            let result = await Self.run(Self.readScript)
            refreshing = false
            apply(result)
            if case .output(let text) = result {
                nowPlaying = Self.parse(text, readAt: .now)
            }
        }
    }

    /// Triggers the macOS permission prompt now, if Spotify is open to ask.
    func requestPermission() {
        guard isRunning else { return }
        lastRefresh = .distantPast
        refresh()
    }

    // MARK: - Controls

    /// Plays a playlist or album, opening Spotify in the background first if
    /// it isn't running. A freshly launched Spotify ignores commands until
    /// it has loaded, so this keeps asking for a few seconds.
    func play(_ uri: String) {
        guard SpotifyLink.webURL(for: uri) != nil else { return }
        let script = "tell application \"Spotify\" to play track \"\(uri)\""
        Task {
            if !isRunning {
                await launchInBackground()
                for _ in 0..<8 {
                    try? await Task.sleep(for: .seconds(1))
                    apply(await Self.run(script))
                    try? await Task.sleep(for: .milliseconds(500))
                    if case .output(let state) = await Self.run(Self.stateScript), state == "playing" { break }
                }
            } else {
                apply(await Self.run(script))
            }
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

    private func command(_ verb: String) {
        guard isRunning else { return }
        Task {
            apply(await Self.run("tell application \"Spotify\" to \(verb)"))
            settle()
        }
    }

    /// Re-read shortly after a command so the card catches up.
    private func settle() {
        lastRefresh = .distantPast
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            refresh()
        }
    }

    private func launchInBackground() async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private func apply(_ result: ScriptResult) {
        switch result {
        case .notAuthorized: notAuthorized = true
        case .output: notAuthorized = false
        case .failed: break
        }
    }

    // MARK: - Scripts

    enum ScriptResult: Equatable {
        case output(String)
        case notAuthorized
        case failed
    }

    /// Fields joined by tabs: state, name, artist, album, artwork, duration, position.
    static let readScript = """
        if application "Spotify" is running then
            tell application "Spotify"
                if player state is stopped then return "stopped"
                set t to current track
                return (player state as text) & tab & (name of t) & tab & (artist of t) & tab & (album of t) ¬
                    & tab & (artwork url of t) & tab & (duration of t) & tab & (player position as text)
            end tell
        end if
        return "stopped"
        """

    static let stateScript = """
        if application "Spotify" is running then
            tell application "Spotify" to return player state as text
        end if
        return "stopped"
        """

    static func parse(_ output: String, readAt: Date) -> NowPlaying? {
        let fields = output.components(separatedBy: "\t")
        guard fields.count >= 7, fields[0] == "playing" || fields[0] == "paused", !fields[1].isEmpty else { return nil }
        // Spotify reports duration in milliseconds despite its dictionary
        // saying seconds; position really is seconds, in the local format.
        let rawDuration = Double(fields[5].replacingOccurrences(of: ",", with: ".")) ?? 0
        let duration = rawDuration > 20_000 ? rawDuration / 1000 : rawDuration
        let position = Double(fields[6].replacingOccurrences(of: ",", with: ".")) ?? 0
        return NowPlaying(title: fields[1], artist: fields[2], album: fields[3],
                          artworkURL: URL(string: fields[4]), duration: duration,
                          position: min(position, duration), isPlaying: fields[0] == "playing",
                          readAt: readAt)
    }

    private static func run(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            AppleScriptQueue.shared.async {
                continuation.resume(returning: execute(source))
            }
        }
    }

    nonisolated private static func execute(_ source: String) -> ScriptResult {
        guard let script = NSAppleScript(source: source) else { return .failed }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            // -1743/-1744: not allowed to send Apple events to Spotify.
            return code == -1743 || code == -1744 ? .notAuthorized : .failed
        }
        return .output(descriptor.stringValue ?? "")
    }
}

/// One serial queue for every AppleScript FocusGuard runs (browser tabs,
/// Spotify): NSAppleScript isn't safe to run on two threads at once, and it
/// blocks for up to a few hundred milliseconds, so never on the main thread.
enum AppleScriptQueue {
    static let shared = DispatchQueue(label: "com.anar.focusguard.applescript", qos: .userInitiated)
}
