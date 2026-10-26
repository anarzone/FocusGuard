import Foundation
import SwiftData

/// One tracked stretch, copied off the store so evidence can be worked out
/// on a background thread.
struct ActivityRecord: Sendable, Equatable {
    let start: Date
    let end: Date
    let bundleId: String
    let appName: String
    let title: String?
    let url: String?
    let inSession: Bool
    let classification: Classification

    var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) + 1 }

    /// A site's host (no "www.") for browsers, else the app's bundle id;
    /// the same key Apps & sites uses.
    var key: String { host ?? bundleId }

    var host: String? {
        guard BrowserTabReader.isBrowser(bundleIdentifier: bundleId),
              var host = url.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }
}

extension ActivityRecord {
    init(_ event: ActivityEvent) {
        self.init(start: event.startedAt, end: event.endedAt, bundleId: event.bundleIdentifier, appName: event.appName,
                  title: event.windowTitle, url: event.url, inSession: event.session != nil,
                  classification: event.classification ?? .neutral)
    }

    /// The last `days` of activity, on a context of its own.
    static func recent(in container: ModelContainer, days: Int, now: Date) -> [ActivityRecord] {
        let start = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<ActivityEvent>(predicate: #Predicate { $0.endedAt >= start })
        descriptor.sortBy = [SortDescriptor(\.startedAt)]
        return Persistence.fetch(context, descriptor).map(ActivityRecord.init)
    }
}

/// What smart categories know about one app or site: the model's input.
struct SmartEvidence: Equatable, Sendable {
    let key: String
    let name: String
    let bundleId: String
    let host: String?
    let seconds: TimeInterval
    let inSession: TimeInterval
    /// "mostly 10:00 to 12:00", when most of its use falls in two hours.
    let hours: String?
    /// What it's used next to, most often first: names with their category.
    let alongside: [(name: String, classification: Classification)]
    /// Window or page titles, most time first. Never from an app that's
    /// opted out of titles.
    let titles: [String]

    var isSite: Bool { host != nil }
    var sessionShare: Double { seconds > 0 ? inSession / seconds : 0 }

    static func == (a: SmartEvidence, b: SmartEvidence) -> Bool {
        a.key == b.key && a.seconds == b.seconds && a.inSession == b.inSession && a.hours == b.hours
            && a.titles == b.titles && a.alongside.map(\.name) == b.alongside.map(\.name)
    }
}

enum SmartEvidenceBuilder {
    /// Switches closer than this count as "used next to".
    static let alongsideGap: TimeInterval = 120
    static let titleLimit = 3
    static let titleLength = 60

    /// Evidence for every app and site in `records` (sorted by start), most
    /// time first. Titles from `optedOut` apps are never read.
    static func build(_ records: [ActivityRecord], optedOut: Set<String>,
                      calendar: Calendar = .current) -> [SmartEvidence] {
        struct Tally {
            var name: String
            var bundleId: String
            var host: String?
            var seconds: TimeInterval = 0
            var inSession: TimeInterval = 0
            var byHour = [TimeInterval](repeating: 0, count: 24)
            var titles: [String: TimeInterval] = [:]
            var neighbours: [String: Int] = [:]
            var categories: [Classification: TimeInterval] = [:]
        }
        var tallies: [String: Tally] = [:]
        var previous: ActivityRecord?
        for record in records {
            let key = record.key
            var tally = tallies[key] ?? Tally(name: record.host ?? record.appName, bundleId: record.bundleId, host: record.host)
            tally.seconds += record.seconds
            if record.inSession { tally.inSession += record.seconds }
            tally.byHour[calendar.component(.hour, from: record.start)] += record.seconds
            tally.categories[record.classification, default: 0] += record.seconds
            if let title = record.title.map(cleanTitle), !title.isEmpty, !optedOut.contains(record.bundleId) {
                tally.titles[title, default: 0] += record.seconds
            }
            tallies[key] = tally

            if let previous, previous.key != key, record.start.timeIntervalSince(previous.end) < alongsideGap {
                tallies[key]?.neighbours[previous.key, default: 0] += 1
                tallies[previous.key]?.neighbours[key, default: 0] += 1
            }
            previous = record
        }

        return tallies.map { key, tally in
            let alongside = tally.neighbours.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(3).compactMap { other -> (String, Classification)? in
                guard let neighbour = tallies[other.key] else { return nil }
                let category = neighbour.categories.max { $0.value < $1.value }?.key ?? .neutral
                return (neighbour.name, category)
            }
            let titles = tally.titles.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(titleLimit).map(\.key)
            return SmartEvidence(key: key, name: tally.name, bundleId: tally.bundleId, host: tally.host,
                                 seconds: tally.seconds, inSession: tally.inSession,
                                 hours: busyHours(tally.byHour), alongside: alongside.map { (name: $0.0, classification: $0.1) },
                                 titles: titles)
        }
        .sorted { ($0.seconds, $1.key) > ($1.seconds, $0.key) }
    }

    /// "mostly 10:00 to 12:00" when two neighbouring hours hold at least
    /// half the time; nil when it's spread out.
    static func busyHours(_ byHour: [TimeInterval]) -> String? {
        let total = byHour.reduce(0, +)
        guard total > 0 else { return nil }
        var best = 0
        var bestSeconds: TimeInterval = -1
        for hour in 0..<23 where byHour[hour] + byHour[hour + 1] > bestSeconds {
            best = hour
            bestSeconds = byHour[hour] + byHour[hour + 1]
        }
        guard bestSeconds / total >= 0.5 else { return nil }
        return String(format: "mostly %02d:00 to %02d:00", best, best + 2)
    }

    /// Short and tidy: no "(3)" unread count, no line breaks.
    static func cleanTitle(_ title: String) -> String {
        var text = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if let match = text.firstMatch(of: /^\(\d+\)\s*/) { text.removeSubrange(match.range) }
        if text.count > titleLength { text = String(text.prefix(titleLength - 1)) + "…" }
        return text
    }
}
