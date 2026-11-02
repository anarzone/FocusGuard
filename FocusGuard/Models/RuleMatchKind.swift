import Foundation

enum RuleMatchKind: Int, Codable, CaseIterable {
    /// Exact bundle id match. Cheap and the most reliable signal.
    case bundleId = 0
    /// Hostname substring match against the captured browser URL host.
    /// Example pattern "youtube.com" matches host "www.youtube.com".
    case host = 1
    /// Window title regex (case-insensitive). Last-resort, expensive.
    case titleRegex = 2
    /// Part of a site: host plus path prefix, e.g. "youtube.com/shorts".
    /// The host matches like `.host`; the path on whole segments.
    case urlPrefix = 3

    var label: String {
        switch self {
        case .bundleId:   return String(localized: "App", comment: "What a rule matches")
        case .host:       return String(localized: "Site", comment: "What a rule matches")
        case .titleRegex: return String(localized: "Title regex", comment: "What a rule matches")
        case .urlPrefix:  return String(localized: "Part of a site", comment: "What a rule matches")
        }
    }
}
