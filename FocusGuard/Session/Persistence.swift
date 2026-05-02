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
