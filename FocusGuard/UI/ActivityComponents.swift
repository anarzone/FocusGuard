import SwiftUI

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
