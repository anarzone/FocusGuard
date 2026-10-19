import AppKit
import SwiftUI

// MARK: - Header button

/// Opens the music pane on the menu's left. Shows a moving waveform while
/// Spotify plays, so music is visible without taking room in the column.
struct MusicButton: View {
    @Binding var isOpen: Bool
    let isPlaying: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { isOpen.toggle() }
        } label: {
            Image(systemName: isPlaying ? "waveform" : "music.note")
                .font(.system(size: 12, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: isPlaying && !isOpen)
                .foregroundStyle(isOpen ? Color.white : (isPlaying ? Theme.focus : Color.primary.opacity(0.75)))
                .frame(width: 28, height: 28)
                .background(Circle().fill(isOpen ? Theme.focusFill : Theme.control))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Close music" : "Music")
        .accessibilityLabel("Music")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}

// MARK: - Pane

/// The music pane, slid out on the menu's left: what Spotify is playing with
/// a timeline you can drag through, the controls and volume, and the saved
/// playlists — click one to play it, mark the one sessions start with.
struct MusicPane: View {
    @Bindable var music: FocusMusic
    let now: Date
    let inSession: Bool
    let close: () -> Void

    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaneTitle(title: "Music", close: close) {
                Button {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyPlayer.bundleID) {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    }
                } label: {
                    Label("Open Spotify", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11))
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(Theme.control))
                }
                .buttonStyle(.plain)
            }

            if music.spotify.notAuthorized {
                permissionNote
            }

            if let track = music.spotify.nowPlaying {
                PlayerSection(track: track, context: context, now: now, player: music.spotify)
            } else {
                idleSection
            }

            PlaylistList(music: music, inSession: inSession)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(width: Self.width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.module))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
    }

    /// The saved playlist FocusGuard started, if that's what's playing.
    private var context: String? {
        music.playlists.first { $0.uri == music.spotify.lastStartedURI }?.title
    }

    private var idleSection: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.control)
                .frame(width: 160, height: 160)
                .overlay(Image(systemName: "music.note")
                    .font(.system(size: 44))
                    .foregroundStyle(.tertiary))
            Text(music.spotify.isRunning ? "Nothing playing" : "Spotify isn't open")
                .font(.system(size: 13, weight: .semibold))
            if let focus = music.selected {
                Button {
                    music.play(focus.uri, inSession: inSession)
                } label: {
                    Label("Play \(focus.title)", systemImage: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(Capsule().fill(Theme.focusFill))
                }
                .buttonStyle(.plain)
            } else {
                Text("Pick a playlist below to play it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
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
}

// MARK: - Player

/// Artwork, title, the timeline, the transport controls and volume.
struct PlayerSection: View {
    let track: NowPlaying
    let context: String?
    let now: Date
    let player: SpotifyPlayer

    var body: some View {
        VStack(spacing: 12) {
            PlaylistCover(url: track.artworkURL, size: 168)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)

            VStack(spacing: 2) {
                Text(track.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(context.map { "from \($0)" } ?? track.album)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)

            SeekBar(position: track.position(at: now), duration: track.duration) { player.seek(to: $0) }

            HStack(spacing: 0) {
                toggle("shuffle", "Shuffle", on: track.shuffling, action: player.toggleShuffle)
                Spacer()
                transport("backward.fill", "Previous track", action: player.previous)
                Spacer()
                Button(action: player.togglePlayPause) {
                    Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(Theme.focusFill))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(track.isPlaying ? "Pause" : "Play")
                Spacer()
                transport("forward.fill", "Next track", action: player.next)
                Spacer()
                toggle("repeat", "Repeat", on: track.repeating, action: player.toggleRepeat)
            }
            .padding(.horizontal, 4)

            VolumeSlider(volume: track.volume) { player.setVolume($0) }
        }
    }

    private func transport(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func toggle(_ symbol: String, _ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? Theme.focus : Color.secondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(on ? Theme.focusTint : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The track's timeline. Drag or click anywhere on it to jump there; the
/// time under the pointer shows while dragging and the jump happens on
/// release. It thickens under the pointer, like the system's players.
struct SeekBar: View {
    let position: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @State private var scrub: TimeInterval?
    @State private var hovering = false

    var body: some View {
        let shown = scrub ?? position
        let fraction = duration > 0 ? min(1, max(0, shown / duration)) : 0
        let active = hovering || scrub != nil

        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.control)
                    Capsule().fill(Theme.focus).frame(width: width * fraction)
                }
                .frame(height: active ? 6 : 4)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(.white)
                        .overlay(Circle().strokeBorder(Theme.focus, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .offset(x: width * fraction - 6)
                        .opacity(active ? 1 : 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            scrub = SeekMath.time(at: value.location.x, width: width, duration: duration)
                        }
                        .onEnded { value in
                            onSeek(SeekMath.time(at: value.location.x, width: width, duration: duration))
                            scrub = nil
                        }
                )
            }
            .frame(height: 14)
            .takesActivatingClick()
            .onHover { hovering = $0 }

            HStack {
                Text(SeekMath.label(shown))
                Spacer()
                Text("-" + SeekMath.label(max(0, duration - shown)))
            }
            .font(.system(size: 10, weight: scrub == nil ? .regular : .semibold).monospacedDigit())
            .foregroundStyle(scrub == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.focus))
        }
        .animation(.snappy(duration: 0.15), value: active)
        .accessibilityElement()
        .accessibilityLabel("Track position")
        .accessibilityValue("\(SeekMath.label(position)) of \(SeekMath.label(duration))")
        .accessibilityAdjustableAction { direction in
            onSeek(position + (direction == .increment ? 15 : -15))
        }
    }
}

enum SeekMath {
    static func time(at x: CGFloat, width: CGFloat, duration: TimeInterval) -> TimeInterval {
        guard width > 0 else { return 0 }
        return Double(min(1, max(0, x / width))) * duration
    }

    /// "2:51", "1:02:05" past an hour.
    static func label(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Spotify's volume, 0–100.
struct VolumeSlider: View {
    let volume: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(volume) }, set: { onChange(Int($0.rounded())) }), in: 0...100)
                .controlSize(.small)
                .tint(Theme.focus)
                .accessibilityLabel("Spotify volume")
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Playlists

/// The saved playlists. Click one to play it now; the target button marks
/// the one sessions start with. Add from a share link; right-click for more.
struct PlaylistList: View {
    @Bindable var music: FocusMusic
    let inSession: Bool

    @State private var adding = false
    @State private var link = ""
    @State private var problem: String?
    @State private var saving = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Playlists")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    withAnimation(.snappy(duration: 0.2)) { adding.toggle() }
                    problem = nil
                    if adding { focusField() }
                } label: {
                    Label(adding ? "Cancel" : "Add", systemImage: adding ? "xmark" : "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.focus)
            }

            if adding {
                addRow
            }

            if music.playlists.isEmpty && !adding {
                Text("Add a Spotify playlist to play it here and with your sessions.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(music.playlists) { playlist in
                        PlaylistRow(
                            playlist: playlist,
                            isFocus: music.selectedURI == playlist.uri,
                            isPlaying: music.spotify.lastStartedURI == playlist.uri && music.spotify.nowPlaying?.isPlaying == true,
                            play: { music.play(playlist.uri, inSession: inSession) },
                            toggleFocus: {
                                let picking = music.selectedURI != playlist.uri
                                withAnimation(.snappy(duration: 0.2)) { music.select(picking ? playlist.uri : nil) }
                                if picking { music.spotify.requestPermission() }
                            },
                            remove: { withAnimation(.snappy(duration: 0.2)) { music.remove(playlist.uri) } }
                        )
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
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
                withAnimation(.snappy(duration: 0.2)) { adding = false }
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

struct PlaylistRow: View {
    let playlist: SavedPlaylist
    let isFocus: Bool
    let isPlaying: Bool
    let play: () -> Void
    let toggleFocus: () -> Void
    let remove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                HStack(spacing: 10) {
                    PlaylistCover(url: playlist.imageURL, size: 38)
                        .overlay {
                            if hovering || isPlaying {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.black.opacity(0.35))
                                Image(systemName: isPlaying ? "waveform" : "play.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                            }
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(playlist.title)
                            .font(.system(size: 13, weight: isPlaying ? .semibold : .regular))
                            .foregroundStyle(isPlaying ? Theme.focus : Color.primary)
                            .lineLimit(1)
                        Text(isFocus ? "Plays with sessions" : (playlist.uri.contains(":album:") ? "Album" : "Playlist"))
                            .font(.system(size: 11))
                            .foregroundStyle(isFocus ? AnyShapeStyle(Theme.focus) : AnyShapeStyle(.secondary))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(playlist.title)")

            Button(action: toggleFocus) {
                Image(systemName: isFocus ? "target" : "scope")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isFocus ? Theme.focus : Color.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isFocus || hovering ? 1 : 0.35)
            .help(isFocus ? "Stop playing it with sessions" : "Play it when a session starts")
            .accessibilityLabel(isFocus ? "Plays with sessions" : "Play with sessions")
            .accessibilityAddTraits(isFocus ? .isSelected : [])
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.control : .clear))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Play now", action: play)
            Button(isFocus ? "Don't play with sessions" : "Play with sessions", action: toggleFocus)
            Divider()
            Button("Remove \(playlist.title)", role: .destructive, action: remove)
        }
    }
}

// MARK: - Cover

/// A playlist cover or album artwork from Spotify, with a quiet placeholder
/// while it loads or when there isn't one.
struct PlaylistCover: View {
    let url: URL?
    var size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size > 100 ? 12 : (size > 40 ? 8 : 6), style: .continuous)
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
