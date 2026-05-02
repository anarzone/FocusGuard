import Foundation
import SwiftData

/// Apps whose window titles often contain private content. Seeded into the store
/// the first time the app runs. The user can edit this list later (Phase 7 UI).
enum DefaultTitleOptOut {
    static let bundleIdentifiers: [String] = [
        "com.apple.mail",
        "com.apple.MobileSMS",        // Messages
        "com.apple.Notes",
        "com.agilebits.onepassword7",
        "com.1password.1password",    // 1Password 8
        "com.bitwarden.desktop",
        "com.tinyspeck.slackmacgap",  // Slack — channel/DM names can be sensitive
        "com.hnc.Discord",
        "ru.keepcoder.Telegram",
        "net.whatsapp.WhatsApp",
        "com.apple.iCal",             // Calendar event titles
    ]

    @MainActor
    static func seedIfNeeded(in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<TitleOptOut>())) ?? []
        let existingIds = Set(existing.map(\.bundleIdentifier))
        var inserted = 0
        for bid in bundleIdentifiers where !existingIds.contains(bid) {
            context.insert(TitleOptOut(bundleIdentifier: bid, reason: "Default"))
            inserted += 1
        }
        if inserted > 0 {
            Persistence.save(context)
        }
    }
}
