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
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: music.service.bundleID) {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    }
                } label: {
                    Label("Open \(music.service.name)", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11))
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(Theme.control))
                }
                .buttonStyle(.plain)
            }

            if music.availableServices.count > 1 {
                Picker("Music app", selection: Binding(get: { music.service }, set: { music.show($0) })) {
                    ForEach(music.availableServices) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if music.player.notAuthorized {
                permissionNote
            }

            if let track = music.player.nowPlaying {
                PlayerSection(track: track, context: context, now: now, player: music.player)
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
        music.playlists.first { $0.uri == music.player.lastStartedURI }?.title
    }

    private var idleSection: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.control)
                .frame(width: 160, height: 160)
                .overlay(Image(systemName: "music.note")
                    .font(.system(size: 44))
                    .foregroundStyle(.tertiary))
            Text(music.player.isRunning ? "Nothing playing" : "\(music.service.name) isn't open")
                .font(.system(size: 13, weight: .semibold))
            if let focus = music.selected, focus.service == music.service {
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
            Text("FocusGuard isn't allowed to control \(music.service.name).")
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
    let player: MusicPlayer

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

/// The pinned playlists for the app on show. Click one to play it now; the
/// target button marks the one sessions start with; right-click for more.
/// Spotify playlists are added from a share link; Apple Music ones are
/// browsed and searched from the library and pinned in one click.
struct PlaylistList: View {
    @Bindable var music: FocusMusic
    let inSession: Bool

    @State private var browsing = false
    @State private var adding = false
    @State private var link = ""
    @State private var problem: String?
    @State private var saving = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        if browsing {
            let done = { withAnimation(.snappy(duration: 0.2)) { browsing = false } }
            if music.service == .appleMusic {
                LibraryBrowser(music: music, done: done)
            } else {
                SpotifyBrowser(music: music, account: music.spotifyAccount, done: done)
            }
        } else {
            pinnedList
        }
    }

    private var pinnedList: some View {
        let pinned = music.playlists(for: music.service)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Playlists")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if music.service == .appleMusic {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { browsing = true }
                    } label: {
                        Label("Browse library", systemImage: "magnifyingglass")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.focus)
                } else {
                    if music.spotifyAccount.isConfigured && !adding {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { browsing = true }
                        } label: {
                            Label("Search", systemImage: "magnifyingglass")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.focus)
                    }
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { adding.toggle() }
                        problem = nil
                        if adding { focusField() }
                    } label: {
                        Label(adding ? "Cancel" : "Link", systemImage: adding ? "xmark" : "link")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.focus)
                    .help("Add a playlist from its share link")
                }
            }

            if adding && music.service == .spotify {
                addRow
            }

            if pinned.isEmpty && !adding {
                Text(music.service == .appleMusic
                     ? "Browse your library and pin playlists to play them here and with your sessions."
                     : "Add a Spotify playlist to play it here and with your sessions.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(pinned) { playlist in
                        PlaylistRow(
                            playlist: playlist,
                            isFocus: music.selectedURI == playlist.uri,
                            isPlaying: music.player.lastStartedURI == playlist.uri && music.player.nowPlaying?.isPlaying == true,
                            play: { music.play(playlist.uri, inSession: inSession) },
                            toggleFocus: {
                                let picking = music.selectedURI != playlist.uri
                                withAnimation(.snappy(duration: 0.2)) { music.select(picking ? playlist.uri : nil) }
                                if picking { music.player(for: playlist.service).requestPermission() }
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

/// Apple Music: the user's library playlists with a search field. The pin
/// button adds one to the pinned list (or takes it off); clicking a row
/// plays it.
struct LibraryBrowser: View {
    @Bindable var music: FocusMusic
    let done: () -> Void

    @State private var library: [AppleMusicLibrary.Playlist] = []
    @State private var state: LoadState = .loading
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    enum LoadState { case loading, loaded, notAuthorized, failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your library")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Done", action: done)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.focus)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Search playlists", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.control))
            .onTapGesture { focusSearch() }

            switch state {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 8)
            case .notAuthorized:
                note("FocusGuard isn't allowed to control Music. Allow it in Privacy & Security › Automation.")
            case .failed:
                note("Couldn't read your Music library. Is the Music app signed in?")
            case .loaded:
                let results = AppleMusicLibrary.filter(library, by: query)
                if results.isEmpty {
                    note(library.isEmpty ? "No playlists in your library yet." : "No playlists match “\(query)”.")
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(results) { playlist in
                            row(playlist)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .transition(.opacity)
        .task { await load() }
    }

    private func row(_ playlist: AppleMusicLibrary.Playlist) -> some View {
        let pinned = music.isPinned(playlist.uri)
        return BrowseRow(title: playlist.name, subtitle: nil, imageURL: nil, pinned: pinned,
                         play: { music.play(playlist.uri, inSession: false) },
                         togglePin: { if pinned { music.remove(playlist.uri) } else { music.pin(playlist) } })
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func load() async {
        state = .loading
        switch await AppleMusicLibrary.playlists(using: music.appleMusic) {
        case .playlists(let playlists):
            library = playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            state = .loaded
        case .notAuthorized: state = .notAuthorized
        case .failed: state = .failed
        }
    }

    /// The menu opens without activating FocusGuard; typing needs it active
    /// and the menu's window key.
    private func focusSearch() {
        NSApp.activate()
        NSApp.windows.first { $0.isVisible && $0.level == .popUpMenu }?.makeKey()
        DispatchQueue.main.async { searchFocused = true }
    }
}

/// A browse or search result: click to play, pin to keep it in the list.
struct BrowseRow: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?
    let pinned: Bool
    let play: () -> Void
    let togglePin: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                HStack(spacing: 10) {
                    if let imageURL {
                        PlaylistCover(url: imageURL, size: 32)
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.control)
                            .frame(width: 32, height: 32)
                            .overlay(Image(systemName: "music.note.list")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Play \(title)")

            Button {
                withAnimation(.snappy(duration: 0.2)) { togglePin() }
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(pinned ? Theme.focus : Color.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pinned ? "Unpin" : "Pin to your playlists")
            .accessibilityLabel(pinned ? "Unpin \(title)" : "Pin \(title)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }
}

/// Spotify: sign in once, then search Spotify for playlists and albums, or
/// (with an empty search) see the playlists you made or follow. Pin to keep
/// one, click to play it.
struct SpotifyBrowser: View {
    @Bindable var music: FocusMusic
    @Bindable var account: SpotifyAccount
    let done: () -> Void

    @State private var query = ""
    @State private var results: [SpotifyAccount.Item]?
    @State private var loading = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Spotify")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if account.isSignedIn {
                    Menu {
                        Button("Sign out of Spotify", role: .destructive) {
                            account.signOut()
                            results = nil
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Spotify account")
                }
                Button("Done", action: done)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.focus)
            }

            if account.isSignedIn {
                searchField
                content
            } else {
                signIn
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .transition(.opacity)
        .task(id: "\(account.isSignedIn)|\(query)") { await load() }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in to search Spotify and see your own playlists. Playing music doesn't need it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if account.signingIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…")
                        .font(.system(size: 11))
                    Spacer()
                    Button("Cancel") { account.cancelSignIn() }
                        .font(.system(size: 11))
                }
            } else {
                Button {
                    Task { await account.signIn() }
                } label: {
                    Text("Sign in with Spotify")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(Capsule().fill(Theme.focusFill))
                }
                .buttonStyle(.plain)
            }
            if account.problem == .signInFailed {
                problemNote("Signing in didn't work. Try again.")
            }
            Text("Search runs through FocusGuard's Spotify developer app, which Spotify only opens to a few approved accounts. Adding playlists by link works for everyone.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search Spotify", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if loading {
                ProgressView().controlSize(.mini)
            } else if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.control))
        .onTapGesture { focusSearch() }
    }

    @ViewBuilder private var content: some View {
        if account.problem == .notAllowed {
            problemNote("Spotify hasn't approved this account for FocusGuard's search. You can still add playlists by link.")
        } else if account.problem == .requestFailed && results == nil {
            problemNote("Couldn't reach Spotify. Check your connection.")
        }
        if let results {
            Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? "Your playlists" : "Playlists and albums")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if results.isEmpty && !loading {
                problemNote(query.isEmpty ? "You haven't made or followed any playlists yet." : "Nothing on Spotify matches “\(query)”.")
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(results) { item in
                        let pinned = music.isPinned(item.uri)
                        BrowseRow(title: item.name, subtitle: item.subtitle, imageURL: item.imageURL, pinned: pinned,
                                  play: { music.play(item.uri, inSession: false) },
                                  togglePin: { if pinned { music.remove(item.uri) } else { music.pin(item) } })
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func problemNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Typing pauses briefly before searching, so each keystroke isn't a request.
    private func load() async {
        guard account.isSignedIn else { return }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
        }
        loading = true
        let found = trimmed.isEmpty ? await account.myPlaylists() : await account.search(trimmed)
        guard !Task.isCancelled else { return }
        loading = false
        if let found { results = found }
    }

    private func focusSearch() {
        NSApp.activate()
        NSApp.windows.first { $0.isVisible && $0.level == .popUpMenu }?.makeKey()
        DispatchQueue.main.async { searchFocused = true }
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
