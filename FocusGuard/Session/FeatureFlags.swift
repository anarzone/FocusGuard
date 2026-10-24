import Foundation

/// Switches for work that's built but not shown yet.
enum FeatureFlags {
    /// Pro AI: the debrief after a session, the weekly coach, smart category
    /// suggestions and the session goal the debrief checks, plus their locked
    /// teasers for free users. Off until the AI behind them exists, so
    /// nothing advertises a feature that isn't there.
    static let proAI = false
}
