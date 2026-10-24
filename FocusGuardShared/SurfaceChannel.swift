import Foundation

/// A tap on a widget or the Control Center control, for the app to carry
/// out. The widget extension runs sandboxed in its own process, so it
/// can't touch the session itself: it drops a command in the shared
/// folder and pings the app.
struct SurfaceCommand: Codable, Equatable, Identifiable {
    enum Action: Codable, Equatable {
        case start(minutes: Int)
        case end
        case togglePause
        case endBreak
        case extendBreak(minutes: Int)
    }

    var id = UUID()
    var action: Action
    var issuedAt: Date
}

/// The folder the app and the widget extension share (the App Group
/// container), and what goes in it: the snapshot, and commands waiting
/// for the app.
struct SurfaceStore {
    /// Must match both targets' entitlements. A Team-ID prefixed group needs
    /// no provisioning profile on macOS, so the free signing team works.
    static let appGroup = "JVK43S5CGA.com.anar.focusguard"
    /// Darwin notification the extension posts after leaving a command.
    static let commandPosted = "com.anar.focusguard.surfaces.command"
    /// Commands older than this are dropped: the moment has passed.
    static let commandShelfLife: TimeInterval = 60

    let folder: URL

    /// The shared container, or nil if the system won't give it out.
    static var shared: SurfaceStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { SurfaceStore(folder: $0.appendingPathComponent("Surfaces", isDirectory: true)) }
    }

    var snapshotURL: URL { folder.appendingPathComponent("snapshot.json") }
    var commandsFolder: URL { folder.appendingPathComponent("Commands", isDirectory: true) }

    // MARK: - Snapshot

    func readSnapshot() -> SurfaceSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(SurfaceSnapshot.self, from: data),
              snapshot.version == SurfaceSnapshot.currentVersion else { return nil }
        return snapshot
    }

    func write(_ snapshot: SurfaceSnapshot) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
    }

    // MARK: - Commands

    /// Leaves `command` for the app and pings it.
    func post(_ command: SurfaceCommand) throws {
        try FileManager.default.createDirectory(at: commandsFolder, withIntermediateDirectories: true)
        let url = commandsFolder.appendingPathComponent("\(command.id.uuidString).json")
        try JSONEncoder().encode(command).write(to: url, options: .atomic)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(Self.commandPosted as CFString), nil, nil, true)
    }

    /// Takes every waiting command, oldest first, and clears the folder.
    /// Stale ones are dropped unread.
    func takeCommands(now: Date = .now) -> [SurfaceCommand] {
        let files = (try? FileManager.default.contentsOfDirectory(at: commandsFolder, includingPropertiesForKeys: nil)) ?? []
        var commands: [SurfaceCommand] = []
        for file in files where file.pathExtension == "json" {
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let command = try? JSONDecoder().decode(SurfaceCommand.self, from: data),
                  now.timeIntervalSince(command.issuedAt) < Self.commandShelfLife else { continue }
            commands.append(command)
        }
        return commands.sorted { $0.issuedAt < $1.issuedAt }
    }

    /// Whether the app has carried out `id` (it lists it in the snapshot).
    func isHandled(_ id: UUID) -> Bool {
        readSnapshot()?.handled.contains(id) ?? false
    }
}
