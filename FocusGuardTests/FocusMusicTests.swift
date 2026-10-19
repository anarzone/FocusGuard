import XCTest
@testable import FocusGuard

@MainActor
final class FocusMusicTests: XCTestCase {
    // MARK: - Share links

    func testShareLinksBecomeURIs() {
        XCTAssertEqual(SpotifyLink.uri(from: "https://open.spotify.com/playlist/37i9dQZF1DWWQRwui0ExPn?si=abc123"),
                       "spotify:playlist:37i9dQZF1DWWQRwui0ExPn")
        XCTAssertEqual(SpotifyLink.uri(from: "  https://open.spotify.com/intl-de/album/4aawyAB9vmqN3uQ7FjRGTy \n"),
                       "spotify:album:4aawyAB9vmqN3uQ7FjRGTy")
        XCTAssertEqual(SpotifyLink.uri(from: "spotify:playlist:37i9dQZF1DWWQRwui0ExPn"),
                       "spotify:playlist:37i9dQZF1DWWQRwui0ExPn")
    }

    func testOtherLinksAreRejected() {
        XCTAssertNil(SpotifyLink.uri(from: "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"))   // a single track
        XCTAssertNil(SpotifyLink.uri(from: "https://example.com/playlist/37i9dQZF1DWWQRwui0ExPn"))
        XCTAssertNil(SpotifyLink.uri(from: "spotify:playlist:abc\" to quit"))                          // can't reach a script
        XCTAssertNil(SpotifyLink.uri(from: "lofi beats"))
    }

    func testURIsMapBackToWebLinksForThePreview() {
        XCTAssertEqual(SpotifyLink.webURL(for: "spotify:playlist:37i9dQZF1DWWQRwui0ExPn")?.absoluteString,
                       "https://open.spotify.com/playlist/37i9dQZF1DWWQRwui0ExPn")
        XCTAssertNil(SpotifyLink.webURL(for: "lofi"))
    }

    // MARK: - Reading Spotify

    func testReadsTheCurrentTrack() throws {
        let output = ["playing", "Snowman", "WYS", "Snowman", "https://i.scdn.co/image/abc", "171000", "72,5"]
            .joined(separator: "\t")
        let track = try XCTUnwrap(SpotifyPlayer.parse(output, readAt: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(track.title, "Snowman")
        XCTAssertEqual(track.artist, "WYS")
        XCTAssertEqual(track.duration, 171)          // milliseconds from Spotify
        XCTAssertEqual(track.position, 72.5)         // comma decimal from the locale
        XCTAssertTrue(track.isPlaying)
        XCTAssertEqual(track.artworkURL?.host, "i.scdn.co")
    }

    func testReadsShuffleRepeatAndVolume() throws {
        let output = ["paused", "Snowman", "WYS", "Snowman", "", "171000", "0", "true", "false", "64"]
            .joined(separator: "\t")
        let track = try XCTUnwrap(SpotifyPlayer.parse(output, readAt: .now))
        XCTAssertFalse(track.isPlaying)
        XCTAssertTrue(track.shuffling)
        XCTAssertFalse(track.repeating)
        XCTAssertEqual(track.volume, 64)
    }

    // MARK: - Timeline

    func testDraggingTheTimelinePicksATimeAlongTheTrack() {
        XCTAssertEqual(SeekMath.time(at: 75, width: 300, duration: 200), 50)
        XCTAssertEqual(SeekMath.time(at: -20, width: 300, duration: 200), 0)     // dragged past the start
        XCTAssertEqual(SeekMath.time(at: 900, width: 300, duration: 200), 200)   // and past the end
        XCTAssertEqual(SeekMath.label(171), "2:51")
        XCTAssertEqual(SeekMath.label(3725), "1:02:05")
    }

    func testStoppedOrEmptyMeansNothingPlaying() {
        XCTAssertNil(SpotifyPlayer.parse("stopped", readAt: .now))
        XCTAssertNil(SpotifyPlayer.parse("", readAt: .now))
    }

    func testPositionRunsOnWhilePlayingAndHoldsWhilePaused() {
        let start = Date(timeIntervalSince1970: 0)
        var track = NowPlaying(title: "a", artist: "b", album: "c", artworkURL: nil,
                               duration: 100, position: 40, isPlaying: true, readAt: start)
        XCTAssertEqual(track.position(at: start.addingTimeInterval(5)), 45)
        XCTAssertEqual(track.position(at: start.addingTimeInterval(500)), 100)
        track.isPlaying = false
        XCTAssertEqual(track.position(at: start.addingTimeInterval(5)), 40)
    }

    // MARK: - Saved playlists

    private func makeDefaults() -> UserDefaults {
        let name = "FocusMusicTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func seed(_ defaults: UserDefaults, _ playlists: [SavedPlaylist]) {
        defaults.set(try? JSONEncoder().encode(playlists), forKey: SettingsKeys.Music.playlists)
    }

    func testPicksPersistAndRemovingThePickedOneMeansNoMusic() {
        let defaults = makeDefaults()
        seed(defaults, [SavedPlaylist(uri: "spotify:playlist:a1", title: "lofi beats", imageURL: nil),
                        SavedPlaylist(uri: "spotify:playlist:b2", title: "Deep focus", imageURL: nil)])
        let music = FocusMusic(defaults: defaults)
        XCTAssertEqual(music.playlists.count, 2)
        XCTAssertNil(music.selected)

        music.select("spotify:playlist:b2")
        XCTAssertEqual(FocusMusic(defaults: defaults).selected?.title, "Deep focus")

        music.remove("spotify:playlist:b2")
        XCTAssertNil(music.selected)
        XCTAssertEqual(FocusMusic(defaults: defaults).playlists.map(\.title), ["lofi beats"])
    }

    func testAddingRejectsOtherLinksAndPicksOnesAlreadySaved() async {
        let defaults = makeDefaults()
        seed(defaults, [SavedPlaylist(uri: "spotify:playlist:a1", title: "lofi beats", imageURL: nil)])
        let music = FocusMusic(defaults: defaults)

        let rejected = await music.add(link: "https://example.com")
        XCTAssertEqual(rejected, .notALink)
        let again = await music.add(link: "https://open.spotify.com/playlist/a1?si=x")
        XCTAssertEqual(again, .alreadySaved)
        XCTAssertEqual(music.selected?.title, "lofi beats")
        XCTAssertEqual(music.playlists.count, 1)
    }

    func testSessionsWithoutAFocusPlaylistLeaveMusicAlone() {
        let music = FocusMusic(defaults: makeDefaults())
        music.sessionStarted()
        XCTAssertFalse(music.sessionOwnsPlayback)
        music.sessionPaused()
        music.sessionEnded()
        XCTAssertFalse(music.sessionOwnsPlayback)
    }
}
