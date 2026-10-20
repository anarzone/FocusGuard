import AppKit
import SwiftUI

// MARK: - Header button

/// Opens the music pane on the menu's left. Shows a moving waveform while
/// music plays, so it's visible without taking room in the column, and
/// hovering it shows what's playing.
struct MusicButton: View {
    @Binding var isOpen: Bool
    let track: NowPlaying?

    @State private var showingTrack = false
    @State private var hoverTask: Task<Void, Never>?

    private var isPlaying: Bool { track?.isPlaying == true }

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
        .help(track == nil ? (isOpen ? "Close music" : "Music") : "")
        .onHover(perform: hover)
        .overlay(alignment: .topLeading) {
            // With the pane open the track is already on screen.
            if showingTrack, !isOpen, let track {
                NowPlayingBubble(track: track)
                    .offset(y: 34)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy(duration: 0.18), value: showingTrack)
        .accessibilityLabel("Music")
        .accessibilityValue(track.map { "\($0.isPlaying ? "Playing" : "Paused"): \($0.summary)" } ?? "")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }

    /// A short pause before showing, so passing over the button doesn't flash it.
    private func hover(_ inside: Bool) {
        hoverTask?.cancel()
        guard inside else {
            showingTrack = false
            return
        }
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            showingTrack = true
        }
    }
}

/// What's playing, under the header's music button on hover: artwork,
/// song and artist, and whether it's paused.
struct NowPlayingBubble: View {
    let track: NowPlaying

    var body: some View {
        HStack(spacing: 9) {
            PlaylistCover(url: track.artworkURL, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 190, alignment: .leading)
                HStack(spacing: 4) {
                    if !track.isPlaying {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 8))
                    }
                    Text(track.artist)
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 190, alignment: .leading)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.windowCard))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
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
                ServiceSwitch(services: music.availableServices, selected: music.service) { music.show($0) }
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
                Text("Pick a playlist below, or search for one.")
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

/// The music app's volume, 0–100, drawn like the timeline: a thin bar
/// that thickens under the pointer. Drag or click to set it.
struct VolumeSlider: View {
    let volume: Int
    let onChange: (Int) -> Void

    @State private var dragging: Int?
    @State private var hovering = false

    var body: some View {
        let shown = Double(dragging ?? volume) / 100
        let active = hovering || dragging != nil

        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.control)
                    Capsule().fill(Theme.focus.opacity(active ? 1 : 0.75)).frame(width: width * shown)
                }
                .frame(height: active ? 6 : 4)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(.white)
                        .overlay(Circle().strokeBorder(Theme.focus, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .offset(x: width * shown - 6)
                        .opacity(active ? 1 : 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let level = Int((min(1, max(0, value.location.x / max(1, width))) * 100).rounded())
                            dragging = level
                            onChange(level)
                        }
                        .onEnded { _ in dragging = nil }
                )
            }
            .frame(height: 14)
            .takesActivatingClick()
            .onHover { hovering = $0 }
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .animation(.snappy(duration: 0.15), value: active)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(volume) percent")
        .accessibilityAdjustableAction { direction in
            onChange(min(100, max(0, volume + (direction == .increment ? 10 : -10))))
        }
    }
}

/// Spotify / Apple Music, full width, the picked one raised off the track.
struct ServiceSwitch: View {
    let services: [MusicService]
    let selected: MusicService
    let pick: (MusicService) -> Void

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(services) { service in
                let isSelected = service == selected
                Button {
                    withAnimation(.snappy(duration: 0.22)) { pick(service) }
                } label: {
                    Text(service.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Theme.segment)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                                    .matchedGeometryEffect(id: "selected", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.control))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Music app")
    }
}

// MARK: - Playlists

/// Pinned playlists on top, then — with an empty search — the user's own:
/// their Spotify playlists (once signed in) or their Music library. Typing
/// searches Spotify or the library right there; pin a result to keep it.
/// Click any row to play it; "Sessions" marks the one sessions start with.
struct PlaylistList: View {
    @Bindable var music: FocusMusic
    let inSession: Bool

    @State private var query = ""
    @State private var adding = false
    @State private var link = ""
    @State private var problem: String?
    @State private var saving = false
    @State private var library: [AppleMusicLibrary.Playlist]?
    @State private var libraryState: LibraryState = .idle
    @State private var spotifyMine: [SpotifyAccount.Item]?
    @State private var spotifyResults: [SpotifyAccount.Item]?
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @FocusState private var linkFocused: Bool

    enum LibraryState { case idle, loading, loaded, notAuthorized, failed }

    private var account: SpotifyAccount { music.spotifyAccount }
    private var service: MusicService { music.service }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSearch: Bool { service == .appleMusic || account.isConfigured }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Playlists")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if service == .spotify {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { adding.toggle() }
                        problem = nil
                        if adding { focus($linkFocused) }
                    } label: {
                        Label(adding ? "Cancel" : "Add link", systemImage: adding ? "xmark" : "link")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.focus)
                    .help("Add a playlist from its share link")
                }
            }

            if adding && service == .spotify {
                addRow
            }

            if canSearch {
                searchField
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    if trimmedQuery.isEmpty {
                        pinnedSection
                        librarySection
                    } else {
                        resultsSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A modest ideal height so a long library doesn't stretch the
            // menu; the list fills whatever height the menu has.
            .frame(minHeight: 120, idealHeight: 150, maxHeight: .infinity, alignment: .top)
        }
        .task(id: "\(service.rawValue)|\(account.isSignedIn)") { await loadLibrary() }
        .task(id: "\(service.rawValue)|\(trimmedQuery)") { await searchSpotify() }
        .onChange(of: service) {
            query = ""
            adding = false
        }
    }

    // MARK: Sections

    @ViewBuilder private var pinnedSection: some View {
        let pinned = music.playlists(for: service)
        if pinned.isEmpty {
            note(service == .appleMusic
                 ? "Pin playlists from your library below to keep them here."
                 : "Pin playlists from your own or from search, or add one by link.")
        } else {
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
            if music.selectedURI == nil {
                note("Nothing plays with your sessions yet. Choose Sessions on a playlist.")
            }
        }
    }

    @ViewBuilder private var librarySection: some View {
        switch service {
        case .appleMusic:
            sectionHeader("Your library")
            switch libraryState {
            case .idle:
                actionRow("Show your Music library", systemImage: "music.note.list") {
                    Task { await loadLibrary(launching: true) }
                }
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 6)
            case .notAuthorized:
                note("FocusGuard isn't allowed to control Music. Allow it in Privacy & Security › Automation.")
            case .failed:
                note("Couldn't read your Music library. Is the Music app signed in?")
            case .loaded:
                let rest = (library ?? []).filter { !music.isPinned($0.uri) }
                if rest.isEmpty {
                    note(library?.isEmpty == true ? "No playlists in your library yet." : "Everything in your library is pinned.")
                }
                ForEach(rest) { appleRow($0) }
            }
        case .spotify:
            if account.isConfigured {
                sectionHeader("Your Spotify playlists") { accountMenu }
                if account.isSignedIn {
                    spotifyProblems
                    let rest = (spotifyMine ?? []).filter { !music.isPinned($0.uri) }
                    if spotifyMine == nil && account.problem == nil {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 6)
                    } else if rest.isEmpty && account.problem == nil {
                        note(spotifyMine?.isEmpty == true ? "You haven't made or followed any playlists yet." : "All your playlists are pinned.")
                    }
                    ForEach(rest) { spotifyRow($0) }
                } else {
                    signInCard
                }
            }
        }
    }

    @ViewBuilder private var resultsSection: some View {
        switch service {
        case .appleMusic:
            if library == nil {
                actionRow("Show your Music library to search it", systemImage: "music.note.list") {
                    Task { await loadLibrary(launching: true) }
                }
            } else {
                let results = AppleMusicLibrary.filter(library ?? [], by: trimmedQuery)
                if results.isEmpty { note("No playlists match “\(trimmedQuery)”.") }
                ForEach(results) { appleRow($0) }
            }
        case .spotify:
            if account.isSignedIn {
                spotifyProblems
                if let results = spotifyResults {
                    if results.isEmpty && !searching { note("Nothing on Spotify matches “\(trimmedQuery)”.") }
                    ForEach(results) { spotifyRow($0) }
                }
            } else {
                signInCard
            }
        }
    }

    // MARK: Rows

    private func appleRow(_ playlist: AppleMusicLibrary.Playlist) -> some View {
        let pinned = music.isPinned(playlist.uri)
        return BrowseRow(title: playlist.name, subtitle: nil, imageURL: nil, pinned: pinned,
                         play: { music.play(playlist.uri, inSession: inSession) },
                         togglePin: { if pinned { music.remove(playlist.uri) } else { music.pin(playlist) } })
    }

    private func spotifyRow(_ item: SpotifyAccount.Item) -> some View {
        let pinned = music.isPinned(item.uri)
        return BrowseRow(title: item.name, subtitle: item.subtitle, imageURL: item.imageURL, pinned: pinned,
                         play: { music.play(item.uri, inSession: inSession) },
                         togglePin: { if pinned { music.remove(item.uri) } else { music.pin(item) } })
    }

    // MARK: Pieces

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(service == .appleMusic ? "Search your library" : "Search Spotify", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if searching {
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
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.control))
        .onTapGesture { focus($searchFocused) }
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                TextField("Paste a playlist link", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($linkFocused)
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

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                note("Signing in didn't work. Try again.")
            }
            Text("Spotify only opens search to a few approved accounts. Adding playlists by link works for everyone.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var spotifyProblems: some View {
        if account.problem == .notAllowed {
            note("Spotify hasn't approved this account for FocusGuard's search. You can still add playlists by link.")
        } else if account.problem == .requestFailed {
            note("Couldn't reach Spotify. Check your connection.")
        }
    }

    private var accountMenu: some View {
        Menu {
            Button("Sign out of Spotify", role: .destructive) {
                account.signOut()
                spotifyMine = nil
                spotifyResults = nil
            }
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(account.isSignedIn ? 1 : 0)
        .disabled(!account.isSignedIn)
        .help("Spotify account")
    }

    private func sectionHeader(_ title: String) -> some View {
        sectionHeader(title) { EmptyView() }
    }

    private func sectionHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
        .padding(.horizontal, 6)
    }

    private func actionRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(Theme.focus)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }

    // MARK: Loading

    /// Reads the user's own playlists. Music is only opened for it when the
    /// user asks (`launching`); otherwise the library loads if Music is open.
    private func loadLibrary(launching: Bool = false) async {
        switch service {
        case .appleMusic:
            guard launching || music.appleMusic.isRunning else {
                if library == nil { libraryState = .idle }
                return
            }
            libraryState = .loading
            switch await AppleMusicLibrary.playlists(using: music.appleMusic) {
            case .playlists(let playlists):
                library = playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                libraryState = .loaded
            case .notAuthorized: libraryState = .notAuthorized
            case .failed: libraryState = .failed
            }
        case .spotify:
            guard account.isSignedIn else {
                spotifyMine = nil
                return
            }
            if let mine = await account.myPlaylists() { spotifyMine = mine }
        }
    }

    /// Typing pauses briefly before searching, so each keystroke isn't a request.
    private func searchSpotify() async {
        guard service == .spotify, account.isSignedIn, !trimmedQuery.isEmpty else {
            searching = false
            spotifyResults = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        searching = true
        let found = await account.search(trimmedQuery)
        guard !Task.isCancelled else { return }
        searching = false
        if let found { spotifyResults = found }
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
    private func focus(_ field: FocusState<Bool>.Binding) {
        NSApp.activate()
        NSApp.windows.first { $0.isVisible && $0.level == .popUpMenu }?.makeKey()
        DispatchQueue.main.async { field.wrappedValue = true }
    }
}

/// A library or search result: click to play, pin to keep it in the list.
struct BrowseRow: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?
    let pinned: Bool
    let play: () -> Void
    let togglePin: () -> Void

    @State private var hovering = false

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
            .opacity(pinned || hovering ? 1 : 0.5)
            .help(pinned ? "Unpin" : "Pin to your playlists")
            .accessibilityLabel(pinned ? "Unpin \(title)" : "Pin \(title)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.control : .clear))
        .onHover { hovering = $0 }
    }
}

/// A pinned playlist. Click to play it; the Sessions pill marks the one a
/// session starts with; right-click for the rest.
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
                            if hovering && !isPlaying {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.black.opacity(0.35))
                                Image(systemName: "play.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.title)
                            .font(.system(size: 13, weight: isPlaying ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        subtitle
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(playlist.title)
            .accessibilityLabel("Play \(playlist.title)")

            SessionsPill(isOn: isFocus, visible: isFocus || hovering, action: toggleFocus)
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

    @ViewBuilder private var subtitle: some View {
        if isPlaying {
            Label("Playing", systemImage: "waveform")
                .symbolEffect(.variableColor.iterative)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.focus)
        } else {
            Text(playlist.uri.contains(":album:") ? "Album" : "Playlist")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

/// "Sessions": on for the playlist a session starts with. Shown on hover
/// for the others.
struct SessionsPill: View {
    let isOn: Bool
    let visible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: isOn ? "checkmark" : "plus")
                    .font(.system(size: 8, weight: .bold))
                Text("Sessions")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(isOn ? Theme.focus : Color.secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(isOn ? Theme.focusTint : Color.clear))
            .overlay(Capsule().strokeBorder(isOn ? Color.clear : Theme.separator, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .help(isOn ? "Plays when a session starts. Click to stop." : "Play this when a session starts")
        .accessibilityLabel(isOn ? "Plays with sessions" : "Play with sessions")
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
