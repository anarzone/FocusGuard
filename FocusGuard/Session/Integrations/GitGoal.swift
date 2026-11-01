import Foundation

/// The Git branch offered as a session goal: "Git · focusguard",
/// fix/header-clicks.
struct GitGoal: Equatable, Sendable {
    /// The repo's folder name.
    let repo: String
    let branch: String
}

/// Finds the branch being worked on. The repo is the one the editor in
/// front has open, when its window title names a repo in the chosen folder;
/// otherwise the one changed most recently there. Reads `.git/HEAD`
/// directly, so it runs no `git`.
enum GitGoalFinder {
    /// Xcode, VS Code, Cursor and Zed; JetBrains IDEs and Android Studio by prefix.
    static let editors: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "dev.zed.Zed", "dev.zed.Zed-Preview",
    ]
    static let editorPrefixes = ["com.jetbrains.", "com.google.android.studio"]

    /// Branches that say nothing about the work.
    static let mainBranches: Set<String> = ["main", "master", "develop", "dev", "trunk"]

    /// How deep under the folder repos are looked for: ~/Projects/app and
    /// ~/Projects/Own/app.
    static let depth = 2

    static func isEditor(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return editors.contains(bundleID) || editorPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// - Parameter editorTitle: the front editor's window title, if an editor is in front.
    static func goal(in folder: URL, editorTitle: String?, fileManager: FileManager = .default) -> GitGoal? {
        let repos = repos(in: folder, fileManager: fileManager)
        let picked = editorTitle.flatMap { repo(namedIn: $0, among: repos) }
            ?? repos.max { (lastChanged($0, fileManager) ?? .distantPast) < (lastChanged($1, fileManager) ?? .distantPast) }
        guard let picked, let branch = branch(of: picked, fileManager: fileManager),
              !mainBranches.contains(branch) else { return nil }
        return GitGoal(repo: picked.lastPathComponent, branch: branch)
    }

    /// Folders with a `.git` under `folder`, up to `depth` deep. A repo's
    /// own folders aren't looked into.
    static func repos(in folder: URL, depth: Int = depth, fileManager: FileManager = .default) -> [URL] {
        guard depth > 0, let children = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if gitDirectory(of: child, fileManager: fileManager) != nil {
                out.append(child)
            } else if depth > 1, child.lastPathComponent != "node_modules" {
                out += repos(in: child, depth: depth - 1, fileManager: fileManager)
            }
        }
        return out
    }

    /// The repo's git folder: `.git`, or where a worktree's `.git` file
    /// points.
    static func gitDirectory(of repo: URL, fileManager: FileManager = .default) -> URL? {
        let dotGit = repo.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : repo.appendingPathComponent(path).standardizedFileURL
    }

    /// The checked-out branch; nil when HEAD is detached.
    static func branch(of repo: URL, fileManager: FileManager = .default) -> String? {
        guard let git = gitDirectory(of: repo, fileManager: fileManager),
              let head = try? String(contentsOf: git.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        guard line.hasPrefix(prefix) else { return nil }
        let name = String(line.dropFirst(prefix.count))
        return name.isEmpty ? nil : name
    }

    /// When the repo last changed in Git: a checkout, a commit, staging.
    static func lastChanged(_ repo: URL, _ fileManager: FileManager = .default) -> Date? {
        guard let git = gitDirectory(of: repo, fileManager: fileManager) else { return nil }
        return ["HEAD", "index", "logs/HEAD"]
            .compactMap { try? fileManager.attributesOfItem(atPath: git.appendingPathComponent($0).path)[.modificationDate] as? Date }
            .max()
    }

    /// The repo whose folder name is in the window title as a whole name:
    /// "SessionGoal.swift — FocusGuard" names FocusGuard, not Focus. The
    /// longest name wins.
    static func repo(namedIn title: String, among repos: [URL]) -> URL? {
        repos
            .filter { names(title, $0.lastPathComponent) }
            .max { $0.lastPathComponent.count < $1.lastPathComponent.count }
    }

    private static func names(_ title: String, _ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        func isNameCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "-" || c == "_" }
        var searchRange = title.startIndex..<title.endIndex
        while let found = title.range(of: name, options: [.caseInsensitive], range: searchRange) {
            let before = found.lowerBound == title.startIndex ? nil : title[title.index(before: found.lowerBound)]
            let after = found.upperBound == title.endIndex ? nil : title[found.upperBound]
            if !(before.map(isNameCharacter) ?? false), !(after.map(isNameCharacter) ?? false) { return true }
            searchRange = found.upperBound..<title.endIndex
        }
        return false
    }
}
