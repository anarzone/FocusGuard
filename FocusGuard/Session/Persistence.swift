import Foundation
import SwiftData
import os

/// Centralized SwiftData save with structured logging. Prefer `Persistence.save(context:)`
/// over raw `try? context.save()` so failures surface in Console.app under
/// the "FocusGuard" subsystem instead of being swallowed.
enum Persistence {
    static let logger = Logger(subsystem: "com.anar.focusguard", category: "persistence")

    /// Save if dirty. Returns true on success, false on failure (logged).
    @MainActor
    @discardableResult
    static func save(_ context: ModelContext, file: StaticString = #file, line: UInt = #line) -> Bool {
        guard context.hasChanges else { return true }
        do {
            try context.save()
            return true
        } catch {
            logger.error("SwiftData save failed at \(String(describing: file)):\(line): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Fetch with error logging.
    @MainActor
    static func fetch<T>(_ context: ModelContext, _ descriptor: FetchDescriptor<T>, file: StaticString = #file, line: UInt = #line) -> [T] {
        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error("SwiftData fetch failed at \(String(describing: file)):\(line): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Delete every row matching `predicate`, one object at a time.
    ///
    /// Don't use `context.delete(model:where:)` for ActivityEvent or Session:
    /// SwiftData's batch delete refuses rows on either side of the
    /// session↔events relationship ("Constraint trigger violation: Batch
    /// delete failed due to mandatory OTO nullify inverse"), so it silently
    /// left session activity behind. Deleting objects applies the
    /// relationship rules (nullify / cascade) properly. Fetches in pages to
    /// keep memory flat on large stores. Returns the number deleted.
    @MainActor
    @discardableResult
    static func deleteAll<T: PersistentModel>(_ type: T.Type, where predicate: Predicate<T>? = nil,
                                              in context: ModelContext, pageSize: Int = 500,
                                              file: StaticString = #file, line: UInt = #line) -> Int {
        var deleted = 0
        while true {
            var descriptor = FetchDescriptor<T>(predicate: predicate)
            descriptor.fetchLimit = pageSize
            let page = fetch(context, descriptor, file: file, line: line)
            guard !page.isEmpty else { break }
            for object in page { context.delete(object) }
            deleted += page.count
            guard save(context, file: file, line: line) else { break }
            if page.count < pageSize { break }
        }
        return deleted
    }

    /// Fetch count with error logging.
    @MainActor
    static func fetchCount<T>(_ context: ModelContext, _ descriptor: FetchDescriptor<T>, file: StaticString = #file, line: UInt = #line) -> Int {
        do {
            return try context.fetchCount(descriptor)
        } catch {
            logger.error("SwiftData fetchCount failed at \(String(describing: file)):\(line): \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}
