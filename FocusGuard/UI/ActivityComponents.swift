import SwiftUI

// MARK: - Session duration choice

enum SessionDurationChoice: Hashable, CaseIterable {
    case min25, min50, min90, custom

    var minutes: Int? {
        switch self {
        case .min25: return 25
        case .min50: return 50
        case .min90: return 90
        case .custom: return nil
        }
    }
    var shortLabel: String {
        switch self {
        case .min25: return "25m"
        case .min50: return "50m"
        case .min90: return "90m"
        case .custom: return ""
        }
    }
}

extension ActivitySnapshot {
    /// URL host > URL host+path > window title > bundle id.
    /// For browsers, the URL is the most informative thing; the window title
    /// is usually just "Page Title - Chrome" which duplicates the page.
    var detailLine: String {
        if let urlString = url, !urlString.isEmpty {
            if let url = URL(string: urlString), let host = url.host {
                let displayPath = url.path.count > 1 ? url.path : ""
                return host + displayPath
            }
            return urlString
        }
        if let title = windowTitle, !title.isEmpty {
            return title
        }
        return bundleIdentifier
    }
}
