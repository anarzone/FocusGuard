import Foundation
import SwiftData

/// Seeded once at first launch. Users can edit/delete these later in Settings →
/// Rules. Default rules use priority 100; user-added rules default to 200 so
/// they override defaults without us having to delete the built-ins.
enum DefaultRules {
    struct Seed {
        let pattern: String
        let kind: RuleMatchKind
        let classification: Classification
    }

    static let seeds: [Seed] = [
        // ── Focus apps ─────────────────────────────────────────
        Seed(pattern: "com.jetbrains.PhpStorm",                   kind: .bundleId, classification: .focus),
        Seed(pattern: "com.jetbrains.intellij",                   kind: .bundleId, classification: .focus),
        Seed(pattern: "com.jetbrains.WebStorm",                   kind: .bundleId, classification: .focus),
        Seed(pattern: "com.jetbrains.pycharm",                    kind: .bundleId, classification: .focus),
        Seed(pattern: "com.jetbrains.goland",                     kind: .bundleId, classification: .focus),
        Seed(pattern: "com.jetbrains.rubymine",                   kind: .bundleId, classification: .focus),
        Seed(pattern: "com.apple.dt.Xcode",                       kind: .bundleId, classification: .focus),
        Seed(pattern: "com.microsoft.VSCode",                     kind: .bundleId, classification: .focus),
        Seed(pattern: "com.todesktop.230313mzl4w4u92",            kind: .bundleId, classification: .focus),  // Cursor
        Seed(pattern: "com.zed.dev",                              kind: .bundleId, classification: .focus),
        Seed(pattern: "com.sublimetext.4",                        kind: .bundleId, classification: .focus),
        Seed(pattern: "com.apple.Terminal",                       kind: .bundleId, classification: .focus),
        Seed(pattern: "com.googlecode.iterm2",                    kind: .bundleId, classification: .focus),
        Seed(pattern: "com.github.wez.wezterm",                   kind: .bundleId, classification: .focus),
        Seed(pattern: "dev.warp.Warp-Stable",                     kind: .bundleId, classification: .focus),
        Seed(pattern: "com.figma.Desktop",                        kind: .bundleId, classification: .focus),
        Seed(pattern: "com.linear",                               kind: .bundleId, classification: .focus),
        Seed(pattern: "com.notion.id",                            kind: .bundleId, classification: .focus),
        Seed(pattern: "com.tinyspeck.slackmacgap",                kind: .bundleId, classification: .neutral),
        Seed(pattern: "com.anthropic.claudefordesktop",           kind: .bundleId, classification: .focus),

        // ── Browsers themselves are neutral; URL rules below classify pages ──
        Seed(pattern: "com.apple.Safari",                         kind: .bundleId, classification: .neutral),
        Seed(pattern: "com.google.Chrome",                        kind: .bundleId, classification: .neutral),
        Seed(pattern: "company.thebrowser.Browser",               kind: .bundleId, classification: .neutral),
        Seed(pattern: "com.brave.Browser",                        kind: .bundleId, classification: .neutral),
        Seed(pattern: "com.microsoft.edgemac",                    kind: .bundleId, classification: .neutral),

        // ── Distraction sites ─────────────────────────────────
        Seed(pattern: "youtube.com",     kind: .host, classification: .distraction),
        Seed(pattern: "twitter.com",     kind: .host, classification: .distraction),
        Seed(pattern: "x.com",           kind: .host, classification: .distraction),
        Seed(pattern: "reddit.com",      kind: .host, classification: .distraction),
        Seed(pattern: "instagram.com",   kind: .host, classification: .distraction),
        Seed(pattern: "tiktok.com",      kind: .host, classification: .distraction),
        Seed(pattern: "facebook.com",    kind: .host, classification: .distraction),
        Seed(pattern: "netflix.com",     kind: .host, classification: .distraction),
        Seed(pattern: "twitch.tv",       kind: .host, classification: .distraction),
        Seed(pattern: "9gag.com",        kind: .host, classification: .distraction),
        Seed(pattern: "linkedin.com",    kind: .host, classification: .distraction),
        Seed(pattern: "news.ycombinator.com", kind: .host, classification: .distraction),

        // ── Focus sites ───────────────────────────────────────
        Seed(pattern: "github.com",         kind: .host, classification: .focus),
        Seed(pattern: "gitlab.com",         kind: .host, classification: .focus),
        Seed(pattern: "stackoverflow.com",  kind: .host, classification: .focus),
        Seed(pattern: "developer.apple.com",kind: .host, classification: .focus),
        Seed(pattern: "docs.swift.org",     kind: .host, classification: .focus),
        Seed(pattern: "developer.mozilla.org", kind: .host, classification: .focus),

        // ── Distraction apps ──────────────────────────────────
        Seed(pattern: "com.hnc.Discord",           kind: .bundleId, classification: .distraction),
        Seed(pattern: "ru.keepcoder.Telegram",     kind: .bundleId, classification: .distraction),
        Seed(pattern: "net.whatsapp.WhatsApp",     kind: .bundleId, classification: .distraction),
    ]

    /// Insert seed rules. Skips any seed already present (matched by pattern+kind).
    @MainActor
    static func seedIfNeeded(in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<AppRule>())) ?? []
        let existingKey = Set(existing.map { "\($0.matchKindRaw):\($0.pattern)" })

        var inserted = 0
        for seed in seeds {
            let key = "\(seed.kind.rawValue):\(seed.pattern)"
            if existingKey.contains(key) { continue }
            context.insert(AppRule(
                pattern: seed.pattern,
                matchKind: seed.kind,
                classification: seed.classification,
                priority: 100
            ))
            inserted += 1
        }
        if inserted > 0 {
            Persistence.save(context)
        }
    }
}
