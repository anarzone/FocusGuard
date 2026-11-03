import Foundation

/// Switches for work that's built but not shown yet.
enum FeatureFlags {
    // Pro AI, one switch per feature. Each stays off until the AI behind it
    // exists, so nothing (locked teasers included) advertises a feature that
    // isn't there.

    /// Smart category suggestions, with a reason for each.
    static let smartCategories = true
    /// The session goal, the debrief after a session and the work log.
    static let debrief = true
    /// The weekly coach note and its experiment.
    static let coach = true
    /// Ask: questions about your own focus, answered on this Mac.
    static let ask = true

    /// Open reminders as session goals, ticked off when the session's done
    /// (Settings › Integrations › Tasks as session goals).
    static let taskGoals = true

    /// The month in review, in Reports › Month.
    static let monthlyReview = true

    /// Slack status and Discord activity while a session runs (Settings ›
    /// Integrations › Status in Slack and Discord). Each app's row also
    /// waits for its ID in the build (`SLACK_CLIENT_ID`, `DISCORD_APPLICATION_ID`).
    static let statusSync = true

    /// "Pick up where you left off": the card after a call, a time away or a
    /// drift, and the menu's last places. Free.
    static let pickUp = true

    /// The Analyzer: why focus gets lost, one fix, and a fair test of it. Fixed
    /// rules, no model.
    static let analyzer = true

    /// Any Pro AI feature has shipped: drives general copy about AI (the
    /// upgrade sheet, the Pro pane, the privacy note).
    static var proAI: Bool { smartCategories || debrief || coach || ask || monthlyReview }
}
