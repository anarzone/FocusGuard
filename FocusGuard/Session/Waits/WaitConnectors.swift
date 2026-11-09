import Foundation

/// Tools that can tell FocusGuard exactly when they start and finish, by
/// opening a `focusguard://wait/…` link from their own hooks. Each is set up
/// only when the user presses Connect, and Disconnect takes out only what
/// FocusGuard put in. The links carry the tool's name and the project's
/// folder name, nothing else.
enum WaitConnector: String, CaseIterable, Identifiable {
    case claudeCode, codex

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        }
    }

    enum State: Equatable {
        /// The tool isn't on this Mac (no settings folder).
        case notInstalled
        case notConnected
        case connected
        /// Codex already runs another notify command, which FocusGuard won't replace.
        case hasOwnNotify
    }

    enum Problem: Error, Equatable {
        case unreadable
        case hasOwnNotify
    }

    /// Marks every line FocusGuard adds, so Disconnect finds them.
    static let marker = "focusguard://wait"

    /// "$(basename …)" with spaces made safe for a link. No single quotes:
    /// Codex's line keeps the command in a literal TOML string.
    private static func folder(_ variable: String) -> String {
        "$(basename \"\(variable)\" | sed \"s/ /%20/g\")"
    }

    static func command(started: Bool, tool: String, folderVariable: String, needsInput: Bool = false) -> String {
        let name = tool.replacingOccurrences(of: " ", with: "%20")
        let input = needsInput ? "&input=1" : ""
        return "open -g \"\(marker)/\(started ? "start" : "done")?tool=\(name)\(input)&project=\(folder(folderVariable))\""
    }

    /// The shell function for the user's own scripts: `fgwait ./agent.sh`.
    static let shellFunction = """
    fgwait() { local t; t=$(basename "$1" | sed "s/ /%20/g"); open -g "\(marker)/start?tool=$t&project=\(folder("$PWD"))"; "$@"; local s=$?; open -g "\(marker)/done?tool=$t"; return $s; }
    """
}

/// Reads and changes the tools' own settings files.
struct WaitConnectorFiles {
    var home: URL = URL(fileURLWithPath: NSHomeDirectory())
    var fileManager: FileManager = .default

    var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }

    func state(_ connector: WaitConnector) -> WaitConnector.State {
        switch connector {
        case .claudeCode:
            guard fileManager.fileExists(atPath: claudeSettings.deletingLastPathComponent().path) else { return .notInstalled }
            return claudeCommands().contains { $0.contains(WaitConnector.marker) } ? .connected : .notConnected
        case .codex:
            guard fileManager.fileExists(atPath: codexConfig.deletingLastPathComponent().path) else { return .notInstalled }
            let text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
            if text.contains(WaitConnector.marker) { return .connected }
            return Self.topLevelNotify(in: text) ? .hasOwnNotify : .notConnected
        }
    }

    /// Connected with an older set of FocusGuard's lines: put the current
    /// ones in, as the user already said yes to.
    func upgradeIfConnected() {
        let ours = claudeCommands().filter { $0.contains(WaitConnector.marker) }
        if !ours.isEmpty, !ours.contains(where: { $0.contains("input=1") }) { try? connect(.claudeCode) }
    }

    /// Every hook command in Claude Code's settings, read as JSON: however
    /// the file was written (escaped slashes and all).
    func claudeCommands() -> [String] {
        guard let data = try? Data(contentsOf: claudeSettings),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return [] }
        return hooks.values.compactMap { $0 as? [[String: Any]] }.flatMap { $0 }
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
    }

    func connect(_ connector: WaitConnector) throws {
        switch connector {
        case .claudeCode: try writeClaude(connect: true)
        case .codex:      try writeCodex(connect: true)
        }
    }

    func disconnect(_ connector: WaitConnector) throws {
        switch connector {
        case .claudeCode: try writeClaude(connect: false)
        case .codex:      try writeCodex(connect: false)
        }
    }

    // MARK: - Claude Code: two hooks in ~/.claude/settings.json

    private func writeClaude(connect: Bool) throws {
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: claudeSettings), !data.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WaitConnector.Problem.unreadable
            }
            settings = object
        }
        settings["hooks"] = Self.claudeHooks(settings["hooks"] as? [String: Any] ?? [:], connect: connect)
        if (settings["hooks"] as? [String: Any])?.isEmpty == true { settings["hooks"] = nil }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try fileManager.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: claudeSettings, options: .atomic)
    }

    /// The hooks with FocusGuard's taken out, and put back in when connecting:
    /// a prompt sent starts the wait, Claude stopping ends it, and Claude
    /// asking for permission or an answer ends it too: it can't go on alone.
    static func claudeHooks(_ hooks: [String: Any], connect: Bool) -> [String: Any] {
        var hooks = hooks
        for (event, started, needsInput) in [("UserPromptSubmit", true, false), ("Stop", false, false), ("Notification", false, true)] {
            var groups = (hooks[event] as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
                var group = group
                let kept = (group["hooks"] as? [[String: Any]] ?? []).filter {
                    !(($0["command"] as? String)?.contains(WaitConnector.marker) ?? false)
                }
                guard !kept.isEmpty else { return nil }
                group["hooks"] = kept
                return group
            }
            if connect {
                let command = WaitConnector.command(started: started, tool: WaitConnector.claudeCode.name,
                                                    folderVariable: "$CLAUDE_PROJECT_DIR", needsInput: needsInput)
                groups.append(["hooks": [["type": "command", "command": command]]])
            }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        return hooks
    }

    // MARK: - Codex: its notify command in ~/.codex/config.toml

    static let codexComment = "# Added by FocusGuard: tells it when a Codex turn ends. Disconnect in FocusGuard's Settings to take it out."

    static var codexNotify: String {
        let command = WaitConnector.command(started: false, tool: WaitConnector.codex.name, folderVariable: "$PWD")
        // A literal TOML string: the command has no single quotes. Codex adds
        // its own JSON after the last item; the shell ignores it.
        return "notify = [\"sh\", \"-c\", '\(command)', \"focusguard\"]"
    }

    private func writeCodex(connect: Bool) throws {
        let text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        var lines = text.components(separatedBy: "\n").filter { $0 != Self.codexComment && !$0.contains(WaitConnector.marker) }
        if connect {
            guard !Self.topLevelNotify(in: lines.joined(separator: "\n")) else { throw WaitConnector.Problem.hasOwnNotify }
            // Top-level keys go before the first table.
            lines.insert(contentsOf: [Self.codexComment, Self.codexNotify], at: 0)
        }
        try fileManager.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    /// A `notify = …` before the first `[table]`.
    static func topLevelNotify(in text: String) -> Bool {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return false }
            if trimmed.range(of: #"^notify\s*="#, options: .regularExpression) != nil { return true }
        }
        return false
    }
}
