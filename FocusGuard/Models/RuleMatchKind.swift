import Foundation

enum RuleMatchKind: Int, Codable, CaseIterable {
    /// Exact bundle id match. Cheap and the most reliable signal.
    case bundleId = 0
    /// Hostname substring match against the captured browser URL host.
    /// Example pattern "youtube.com" matches host "www.youtube.com".
    case host = 1
    /// Window title regex (case-insensitive). Last-resort, expensive.
    case titleRegex = 2

    var label: String {
        switch self {
        case .bundleId:   return "App"
        case .host:       return "Site"
        case .titleRegex: return "Title regex"
        }
    }
}
