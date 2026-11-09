import Foundation

/// Something the user hands work to and then waits on: an AI agent in a
/// terminal, an AI chat, an editor's agent, a long command, a build.
struct WaitTool: Equatable, Codable, Hashable {
    enum Kind: String, Codable {
        /// An agent in a terminal: Claude Code, Codex, Gemini CLI.
        case agent
        /// A chat in a browser tab or its own app: OpenRouter, ChatGPT, Claude.
        case chat
        /// An editor with an agent or a build: Cursor, Windsurf, Xcode.
        case editor
        /// A command still running in a terminal: the user's own script.
        case command
    }

    /// What the card calls it: "Codex", "OpenRouter", "Your script".
    let name: String
    let kind: Kind
    /// The app to go back to.
    let bundleId: String
    /// The site, for a chat in a browser: going back means that tab.
    var host: String?

    /// The same tool, in the same app and tab.
    func isSame(as other: WaitTool) -> Bool {
        name == other.name && bundleId == other.bundleId && host == other.host
    }
}

/// Recognises a tool from what's in front, and the project it's working on,
/// from the app, the site and the window's title. Nothing is read from the
/// tool itself: this is the learned way, for any tool, with no setup.
enum WaitTools {
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
        "com.raphaelamorim.rio", "dev.tabby",
    ]

    /// Agents run in a terminal, by a word their window's title carries.
    static let agentWords: [(word: String, name: String)] = [
        ("claude", "Claude Code"), ("codex", "Codex"), ("gemini", "Gemini CLI"), ("aider", "Aider"),
        ("opencode", "OpenCode"), ("goose", "Goose"), ("cursor-agent", "Cursor Agent"), ("copilot", "Copilot"),
        ("qwen", "Qwen Code"), ("crush", "Crush"), ("amp", "Amp"),
    ]

    /// Claude Code titles its terminal with what it's on, after one of these.
    static let claudeCodeMarks: Set<Character> = ["✳", "✢", "✶", "✻", "✽", "·"]

    /// A shell alone in the title means nothing's running.
    static let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "login", "nu", "tmux"]

    /// AI chats on the web, by site.
    static let chatSites: [String: String] = [
        "openrouter.ai": "OpenRouter", "chatgpt.com": "ChatGPT", "chat.openai.com": "ChatGPT",
        "claude.ai": "Claude", "gemini.google.com": "Gemini", "aistudio.google.com": "AI Studio",
        "perplexity.ai": "Perplexity", "poe.com": "Poe", "t3.chat": "T3 Chat", "chat.mistral.ai": "Le Chat",
        "grok.com": "Grok", "chat.deepseek.com": "DeepSeek", "v0.dev": "v0", "v0.app": "v0",
        "lovable.dev": "Lovable", "bolt.new": "Bolt", "replit.com": "Replit",
    ]

    /// Apps that are a chat or an agent themselves.
    static let chatApps: [String: String] = [
        "com.anthropic.claudefordesktop": "Claude", "com.openai.chat": "ChatGPT", "com.openai.codex": "Codex",
    ]

    /// Editors whose agent or build the user waits on.
    static let editors: [String: String] = [
        "com.todesktop.230313mzl4w4u92": "Cursor", "com.exafunction.windsurf": "Windsurf",
        "com.microsoft.VSCode": "VS Code", "dev.zed.Zed": "Zed", "com.apple.dt.Xcode": "Xcode",
    ]

    /// Chats and editors: leaving one used to count as a wait, guessed. Their
    /// guessed waits are dropped from the log; an agent's own name is kept.
    static var guessedOnly: Set<String> {
        Set(chatSites.values).union(chatApps.values).union(editors.values).subtracting(agentWords.map(\.name))
    }

    static func tool(for snapshot: ActivitySnapshot) -> WaitTool? {
        // A private window says nothing, and its title isn't for reading.
        guard !snapshot.isPrivateWindow else { return nil }
        let id = snapshot.bundleIdentifier
        if let host = host(of: snapshot.url), BrowserTabReader.isBrowser(bundleIdentifier: id) {
            return chatSites[host].map { WaitTool(name: $0, kind: .chat, bundleId: id, host: host) }
        }
        if let name = chatApps[id] { return WaitTool(name: name, kind: .chat, bundleId: id) }
        if let name = editors[id] { return WaitTool(name: name, kind: .editor, bundleId: id) }
        guard terminals.contains(id) else { return nil }
        let title = snapshot.windowTitle ?? ""
        if let name = agent(inTitle: title) { return WaitTool(name: name, kind: .agent, bundleId: id) }
        guard isRunningCommand(title: title) else { return nil }
        return WaitTool(name: String(localized: "Your script", comment: "A command the user runs in a terminal, waited on"),
                        kind: .command, bundleId: id)
    }

    static func agent(inTitle title: String) -> String? {
        if let first = title.trimmingCharacters(in: .whitespaces).first, claudeCodeMarks.contains(first) {
            return "Claude Code"
        }
        let words = Set(title.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init))
        return agentWords.first { words.contains($0.word) }?.name
    }

    /// Terminals name the process in front: anything but a shell is running.
    /// A title with no process in it can't tell, so it doesn't count.
    static func isRunningCommand(title: String) -> Bool {
        let parts = segments(title).map { $0.lowercased() }
        let processes = parts.filter { part in
            !part.contains("/") && !part.contains("~") && part.range(of: #"^\d+\s*[×x]\s*\d+$"#, options: .regularExpression) == nil
        }
        guard let process = processes.last?.split(separator: " ").first.map(String.init) else { return false }
        return !shells.contains(process) && parts.count > 1
    }

    /// The project: the folder in a terminal's or an editor's title, the
    /// workspace before the file in Xcode. Nil for a chat: it has none.
    static func project(for snapshot: ActivitySnapshot, tool: WaitTool) -> String? {
        guard tool.kind != .chat, let title = snapshot.windowTitle, !title.isEmpty else { return nil }
        let parts = segments(title.trimmingCharacters(in: CharacterSet(charactersIn: " ").union(.init(charactersIn: String(claudeCodeMarks)))))
        // A folder path, as terminals show it: "~/Projects/curiplay", "/Users/me/app".
        if let path = parts.first(where: { $0.hasPrefix("~") || $0.hasPrefix("/") }) {
            let folder = (path.split(separator: "/").last.map(String.init) ?? path).trimmingCharacters(in: .whitespaces)
            return folder.isEmpty || folder == "~" ? nil : folder
        }
        switch tool.kind {
        case .editor:
            // "file.swift — curiplay" in Cursor and VS Code; "Curiplay — file.swift" in Xcode.
            guard parts.count > 1 else { return nil }
            return tool.bundleId == "com.apple.dt.Xcode" ? parts.first : parts.last
        case .agent, .command:
            return nil
        case .chat:
            return nil
        }
    }

    static func host(of url: String?) -> String? {
        guard let host = url.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// "~/Projects/curiplay — claude — 80×24" into its parts.
    static func segments(_ title: String) -> [String] {
        title.components(separatedBy: " — ")
            .flatMap { $0.components(separatedBy: " – ") }
            .flatMap { $0.components(separatedBy: " - ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
