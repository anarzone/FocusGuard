import AppKit
import SwiftUI

// MARK: - Shelf

/// Focus music before a session: covers of the saved Spotify playlists to
/// pick from (click the picked one again for no music), and a tile to add
/// one from a share link.
struct MusicShelf: View {
    @Bindable var music: FocusMusic

    @State private var adding = false
    @State private var link = ""
    @State private var problem: String?
    @State private var saving = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Focus music")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if music.spotify.notAuthorized {
                permissionNote
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(music.playlists) { playlist in
                        coverTile(playlist)
                    }
                    addTile
                }
                .padding(3)
            }
            .padding(-3)

            if adding {
                addRow
            }
        }
        .menuModule()
        .animation(.snappy(duration: 0.22), value: adding)
    }

    private var caption: String {
        if let selected = music.selected { return "\(selected.title) plays when you start" }
        return music.playlists.isEmpty ? "Add a Spotify playlist" : "Pick one to play in sessions"
    }

    private func coverTile(_ playlist: SavedPlaylist) -> some View {
        let picked = music.selectedURI == playlist.uri
        return Button {
            withAnimation(.snappy(duration: 0.2)) { music.select(picked ? nil : playlist.uri) }
            // Ask to control Spotify now, not when the session starts.
            if !picked { music.spotify.requestPermission() }
        } label: {
            VStack(spacing: 5) {
                PlaylistCover(url: playlist.imageURL, size: 52)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.focus, lineWidth: 2)
                            .padding(-3)
                            .opacity(picked ? 1 : 0)
                    )
                Text(playlist.title)
                    .font(.system(size: 11, weight: picked ? .semibold : .regular))
                    .foregroundStyle(picked ? Theme.focus : Color.primary)
                    .lineLimit(1)
                    .frame(width: 58)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove \(playlist.title)", role: .destructive) {
                withAnimation(.snappy(duration: 0.2)) { music.remove(playlist.uri) }
            }
        }
        .help(picked ? "Click for no music" : "Play \(playlist.title) in sessions")
        .accessibilityLabel(playlist.title)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityHint(picked ? "Plays when a session starts. Activate for no music." : "Activate to play it in sessions.")
    }

    private var addTile: some View {
        Button {
            adding.toggle()
            problem = nil
            if adding { focusField() }
        } label: {
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.separator, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 52, height: 52)
                    .overlay(Image(systemName: adding ? "xmark" : "plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary))
                Text(adding ? "Cancel" : "Add")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add a Spotify playlist from its share link")
        .accessibilityLabel(adding ? "Cancel adding a playlist" : "Add a Spotify playlist")
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                TextField("Paste a playlist link", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($fieldFocused)
                    .onSubmit(save)
                Button(saving ? "Adding…" : "Add", action: save)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
            Text(problem ?? "In Spotify: ··· › Share › Copy link to playlist")
                .font(.system(size: 11))
                .foregroundStyle(problem == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.distractionInk))
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var permissionNote: some View {
        HStack(spacing: 8) {
            Text("FocusGuard isn't allowed to control Spotify.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.distractionInk)
            Spacer(minLength: 0)
            Button("Allow…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.system(size: 11))
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            let result = await music.add(link: link)
            saving = false
            if result == .notALink {
                problem = "That isn't a Spotify playlist or album link."
            } else {
                link = ""
                problem = nil
                adding = false
                music.spotify.requestPermission()
            }
        }
    }

    /// The menu opens without activating FocusGuard; typing needs it active
    /// and the menu's window key.
    private func focusField() {
        NSApp.activate()
        NSApp.windows.first { $0.isVisible && $0.level == .popUpMenu }?.makeKey()
        DispatchQueue.main.async { fieldFocused = true }
    }
}

// MARK: - Now playing

/// During a session: the track Spotify is playing, how far in, and
/// previous / play-pause / next. With nothing playing, a button to start the
/// focus playlist instead.
struct NowPlayingCard: View {
    let music: FocusMusic
    let now: Date

    var body: some View {
        if let track = music.spotify.nowPlaying {
            TrackCard(track: track, context: music.sessionOwnsPlayback ? music.selected?.title : nil, now: now,
                      onPrevious: music.spotify.previous, onPlayPause: music.spotify.togglePlayPause,
                      onNext: music.spotify.next)
        } else if let playlist = music.selected {
            startRow(playlist)
        }
    }

    private func startRow(_ playlist: SavedPlaylist) -> some View {
        HStack(spacing: 10) {
            PlaylistCover(url: playlist.imageURL, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(playlist.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text("Focus music")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                music.playSelected()
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Capsule().fill(Theme.control))
            }
            .buttonStyle(.plain)
        }
        .menuModule()
    }
}

/// A track with its artwork, progress and controls.
struct TrackCard: View {
    let track: NowPlaying
    /// The focus playlist's name when the session started the music.
    let context: String?
    let now: Date
    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void

    var body: some View {
        let position = track.position(at: now)
        let progress = track.duration > 0 ? position / track.duration : 0

        VStack(spacing: 8) {
            HStack(spacing: 12) {
                PlaylistCover(url: track.artworkURL, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(context ?? track.album)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            VStack(spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.control)
                        Capsule().fill(Theme.focus)
                            .frame(width: geo.size.width * CGFloat(min(1, max(0, progress))))
                    }
                }
                .frame(height: 3)
                HStack {
                    Text(Self.time(position))
                    Spacer()
                    Text(Self.time(track.duration))
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            .accessibilityHidden(true)

            HStack(spacing: 28) {
                control("backward.fill", "Previous track", size: 13, action: onPrevious)
                control(track.isPlaying ? "pause.fill" : "play.fill", track.isPlaying ? "Pause" : "Play", size: 18,
                        action: onPlayPause)
                control("forward.fill", "Next track", size: 13, action: onNext)
            }
        }
        .menuModule()
    }

    private func control(_ symbol: String, _ label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// "2:51"
    static func time(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Cover

/// A playlist cover or album artwork from Spotify, with a quiet placeholder
/// while it loads or when there isn't one.
struct PlaylistCover: View {
    let url: URL?
    var size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size > 40 ? 8 : 6, style: .continuous)
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Theme.control.overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.32))
                        .foregroundStyle(.tertiary)
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
