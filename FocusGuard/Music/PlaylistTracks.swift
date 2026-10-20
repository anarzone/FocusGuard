import Foundation

/// One song in a playlist or album, as listed in the music pane.
struct PlaylistTrack: Equatable, Identifiable {
    /// Spotify's `spotify:track:…` (or `spotify:episode:…`), or Music's
    /// persistent ID.
    let id: String
    let title: String
    let artist: String
    let duration: TimeInterval
}

/// A playlist's songs, or why they can't be shown.
enum TrackList: Equatable {
    case tracks([PlaylistTrack])
    /// Spotify only lists the songs of playlists the user made or
    /// collaborates on (development-mode apps, since February 2026).
    case notShared
    /// Spotify songs need the Web API sign-in.
    case needsSignIn
    case notAuthorized
    case failed
}
