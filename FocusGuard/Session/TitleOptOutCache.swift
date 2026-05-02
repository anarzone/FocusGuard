import Foundation
import SwiftData

/// In-memory snapshot of opted-out bundle identifiers. The activity tracker hits
/// this on every poll; we don't want to round-trip SwiftData each second.
@MainActor
@Observable
final class TitleOptOutCache {
    private let context: ModelContext
    private(set) var bundleIdentifiers: Set<String> = []

    init(context: ModelContext) {
        self.context = context
        refresh()
    }

    func refresh() {
        let rows = (try? context.fetch(FetchDescriptor<TitleOptOut>())) ?? []
        bundleIdentifiers = Set(rows.map(\.bundleIdentifier))
    }

    func isOptedOut(_ bundleIdentifier: String) -> Bool {
        bundleIdentifiers.contains(bundleIdentifier)
    }
}
