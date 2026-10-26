import Foundation

/// Switches for work that's built but not shown yet.
enum FeatureFlags {
    // Pro AI, one switch per feature. Each stays off until the AI behind it
    // exists, so nothing (locked teasers included) advertises a feature that
    // isn't there.

    /// Smart category suggestions, with a reason for each.
    static let smartCategories = false
    /// The session goal, the debrief after a session and the work log.
    static let debrief = false
    /// The weekly coach note and its experiment.
    static let coach = true

    /// Any Pro AI feature has shipped: drives general copy about AI (the
    /// upgrade sheet, the Pro pane, the privacy note).
    static var proAI: Bool { smartCategories || debrief || coach }
}
