import Foundation
import SwiftData

/// Aggregates `ActivityEvent` rows into the shapes the Reports view needs.
/// The view holds a single instance and asks for fresh data when it appears
/// or when the user opens a different session.
@MainActor
struct ReportBuilder {
    let context: ModelContext

    // MARK: - Today

    func todayBreakdown() -> BreakdownSnapshot {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: .now)
        return breakdown(from: startOfDay, to: .now)
    }

    func breakdown(from: Date, to: Date) -> BreakdownSnapshot {
        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= from && $0.startedAt < to }
        )
        let events = (try? context.fetch(descriptor)) ?? []
        var f: TimeInterval = 0, n: TimeInterval = 0, d: TimeInterval = 0
        for e in events {
            let start = max(e.startedAt, from)
            let end = min(e.endedAt, to)
            let dur = max(0, end.timeIntervalSince(start))
            switch e.classification ?? .neutral {
            case .focus: f += dur
            case .neutral: n += dur
            case .distraction: d += dur
            }
        }
        return BreakdownSnapshot(focus: f, neutral: n, distraction: d)
    }

    // MARK: - Per-day totals

    /// One bar per calendar day in the range, oldest first. Used by the
    /// hero sparkline so it can adapt to whatever range the user picks.
    /// Pass `classification:` to count only events of that type — e.g. the
    /// streak calculator needs focus-only totals.
    func dailyTotals(from: Date, to: Date, classification: Classification? = nil, calendar: Calendar = .current) -> [DailyTotal] {
        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= from && $0.startedAt < to }
        )
        let events = (try? context.fetch(descriptor)) ?? []

        // Build one slot per day, even days with zero activity.
        let firstDay = calendar.startOfDay(for: from)
        let lastDay  = calendar.startOfDay(for: to.addingTimeInterval(-1))
        var days: [Date] = []
        var cursor = firstDay
        while cursor <= lastDay {
            days.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
        }

        var totals: [Date: TimeInterval] = [:]
        for d in days { totals[d] = 0 }

        for e in events {
            if let classification, (e.classification ?? .neutral) != classification { continue }
            let s = max(e.startedAt, from)
            let f = min(e.endedAt, to)
            guard f > s else { continue }
            // Split the event across day boundaries so a long midnight-spanning
            // event doesn't get attributed entirely to its start day.
            var segStart = s
            while segStart < f {
                let dayStart = calendar.startOfDay(for: segStart)
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
                let segEnd = min(f, dayEnd)
                let dur = segEnd.timeIntervalSince(segStart)
                totals[dayStart, default: 0] += max(0, dur)
                segStart = segEnd
            }
        }

        return days.map { DailyTotal(date: $0, seconds: totals[$0] ?? 0) }
    }

    // MARK: - Per-day breakdown (focus / neutral / distraction)

    /// Same shape as dailyTotals but split by classification. Used by the
    /// menu-bar / home-view stacked weekly chart so each day's bar segments
    /// the user's focus / neutral / distraction time.
    func dailyBreakdowns(from: Date, to: Date, calendar: Calendar = .current) -> [DailyBreakdown] {
        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= from && $0.startedAt < to }
        )
        let events = (try? context.fetch(descriptor)) ?? []

        let firstDay = calendar.startOfDay(for: from)
        let lastDay = calendar.startOfDay(for: to.addingTimeInterval(-1))
        var days: [Date] = []
        var cursor = firstDay
        while cursor <= lastDay {
            days.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
        }

        var byDay: [Date: (focus: TimeInterval, neutral: TimeInterval, distraction: TimeInterval)] = [:]
        for d in days { byDay[d] = (0, 0, 0) }

        for e in events {
            let s = max(e.startedAt, from)
            let f = min(e.endedAt, to)
            guard f > s else { continue }
            var segStart = s
            while segStart < f {
                let dayStart = calendar.startOfDay(for: segStart)
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
                let segEnd = min(f, dayEnd)
                let dur = max(0, segEnd.timeIntervalSince(segStart))
                var entry = byDay[dayStart] ?? (0, 0, 0)
                switch e.classification ?? .neutral {
                case .focus:       entry.focus       += dur
                case .neutral:     entry.neutral     += dur
                case .distraction: entry.distraction += dur
                }
                byDay[dayStart] = entry
                segStart = segEnd
            }
        }

        return days.map { day in
            let entry = byDay[day] ?? (0, 0, 0)
            return DailyBreakdown(date: day,
                                  focus: entry.focus,
                                  neutral: entry.neutral,
                                  distraction: entry.distraction)
        }
    }

    // MARK: - Top distractions

    /// Top apps by time spent in the window, regardless of classification.
    /// Used by the "All apps today" section so users can see what they actually
    /// used — focus apps like PhpStorm wouldn't otherwise show anywhere except
    /// the hero number.
    func topApps(from: Date, to: Date, limit: Int = 10) -> [AppUsageEntry] {
        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= from && $0.startedAt < to }
        )
        let events = (try? context.fetch(descriptor)) ?? []

        struct Group {
            var kind: AppGlyphKind
            var name: String
            var bundleId: String
            var seconds: TimeInterval
            var tally: ClassificationTally
            var events: Int
            // Per-host breakdown — only populated for browser bundles. Maps
            // host (e.g. "github.com") → time per classification.
            var hosts: [String: ClassificationTally]
        }
        var groups: [String: Group] = [:]

        for e in events {
            let key = e.bundleIdentifier
            let dur = max(0, min(e.endedAt, to).timeIntervalSince(max(e.startedAt, from)))
            if dur <= 0 { continue }

            let isBrowser = BrowserTabReader.isBrowser(bundleIdentifier: e.bundleIdentifier)
            let host = isBrowser
                ? e.url.flatMap { URL(string: $0)?.host?.replacingOccurrences(of: "www.", with: "") }
                : nil

            let classification = e.classification ?? .neutral
            var group = groups[key] ?? Group(
                kind: AppGlyph.kind(forBundleId: e.bundleIdentifier, name: e.appName),
                name: e.appName,
                bundleId: e.bundleIdentifier,
                seconds: 0,
                tally: ClassificationTally(),
                events: 0,
                hosts: [:]
            )
            group.seconds += dur
            group.events += 1
            group.tally.add(dur, classification)
            if let h = host {
                group.hosts[h, default: ClassificationTally()].add(dur, classification)
            }
            groups[key] = group
        }

        return groups.values
            .sorted { $0.seconds > $1.seconds }
            .prefix(limit)
            .map { g in
                let tabs = g.hosts
                    .map { TabUsage(host: $0.key, seconds: $0.value.total, classification: $0.value.dominant) }
                    .sorted { $0.seconds > $1.seconds }
                return AppUsageEntry(
                    kind: g.kind,
                    name: g.name,
                    bundleId: g.bundleId,
                    classification: g.tally.dominant,
                    seconds: g.seconds,
                    events: g.events,
                    tabs: tabs
                )
            }
    }

    func topDistractions(from: Date, to: Date, limit: Int = 5) -> [DistractionEntry] {
        let dRaw = Classification.distraction.rawValue
        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate {
                $0.endedAt >= from && $0.startedAt < to && $0.classificationRaw == dRaw
            }
        )
        let events = (try? context.fetch(descriptor)) ?? []

        // Group by host (for browser distractions) or bundle id otherwise.
        struct Group {
            var kind: AppGlyphKind
            var name: String
            var subtitle: String
            var seconds: TimeInterval
            var host: String?
            var bundleId: String
        }
        var groups: [String: Group] = [:]

        for e in events {
            let host = e.url.flatMap { URL(string: $0)?.host?.replacingOccurrences(of: "www.", with: "") }
            let key = host ?? e.bundleIdentifier
            let dur = max(0, e.endedAt.timeIntervalSince(max(e.startedAt, from)))

            if var existing = groups[key] {
                existing.seconds += dur
                groups[key] = existing
            } else {
                let kind = AppGlyph.kind(forBundleId: e.bundleIdentifier, name: host ?? e.appName)
                groups[key] = Group(
                    kind: kind,
                    name: host ?? e.appName,
                    subtitle: host ?? e.bundleIdentifier,
                    seconds: dur,
                    host: host,
                    bundleId: e.bundleIdentifier
                )
            }
        }

        let totalDistr = groups.values.reduce(0) { $0 + $1.seconds }
        return groups.values
            .sorted { $0.seconds > $1.seconds }
            .prefix(limit)
            .map { g in
                DistractionEntry(
                    kind: g.kind,
                    name: g.name,
                    subtitle: g.subtitle,
                    seconds: g.seconds,
                    fractionOfTotal: totalDistr > 0 ? g.seconds / totalDistr : 0,
                    host: g.host,
                    bundleId: g.bundleId
                )
            }
    }
}

// MARK: - DistractionEntry

struct AppUsageEntry: Identifiable, Hashable {
    let id = UUID()
    let kind: AppGlyphKind
    let name: String
    let bundleId: String
    let classification: Classification
    let seconds: TimeInterval
    let events: Int
    /// For browser bundles, the per-host breakdown of time spent. Sorted
    /// descending. Empty for non-browsers.
    let tabs: [TabUsage]

    var timeLabel: String {
        Self.format(seconds: seconds)
    }

    static func format(seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        let h = total / 3600
        let m = (total % 3600) / 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

struct DailyTotal: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let seconds: TimeInterval
}

/// Time per classification for one app or site. Its category is whichever
/// covers the most time — events can disagree (a rule changed, or a page
/// title matched a different rule), and picking any single event's label
/// made the category flip between refreshes.
struct ClassificationTally: Equatable {
    var focus: TimeInterval = 0
    var neutral: TimeInterval = 0
    var distraction: TimeInterval = 0

    var total: TimeInterval { focus + neutral + distraction }

    mutating func add(_ seconds: TimeInterval, _ classification: Classification) {
        switch classification {
        case .focus:       focus += seconds
        case .neutral:     neutral += seconds
        case .distraction: distraction += seconds
        }
    }

    /// Ties go to distraction, then focus, so a drift never hides.
    var dominant: Classification {
        if distraction > 0, distraction >= focus, distraction >= neutral { return .distraction }
        if focus > 0, focus >= neutral { return .focus }
        return .neutral
    }
}

struct DailyBreakdown: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let focus: TimeInterval
    let neutral: TimeInterval
    let distraction: TimeInterval
    var total: TimeInterval { focus + neutral + distraction }
}

struct TabUsage: Identifiable, Hashable {
    let id = UUID()
    let host: String
    let seconds: TimeInterval
    let classification: Classification

    var timeLabel: String { AppUsageEntry.format(seconds: seconds) }
}

struct DistractionEntry: Identifiable, Hashable {
    let id = UUID()
    let kind: AppGlyphKind
    let name: String
    let subtitle: String
    let seconds: TimeInterval
    var fractionOfTotal: Double = 0
    /// Set when the row was grouped by browser host. Used for reclassification.
    let host: String?
    /// The originating app bundle id (always set, even for browser host rows).
    let bundleId: String

    var timeLabel: String {
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        let m = total / 60
        let s = total % 60
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }
}
