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

    // MARK: - Per-minute timeline

    /// Stacked-area timeline points for the given range, one minute each.
    /// Used by the Reports timeline chart to replace its mock data.
    func timeline(from: Date, to: Date) -> [TimelinePoint] {
        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= from && $0.startedAt < to }
        )
        let events = (try? context.fetch(descriptor)) ?? []

        let totalMinutes = max(1, Int(to.timeIntervalSince(from) / 60))
        var focus  = [Double](repeating: 0, count: totalMinutes)
        var neutr  = [Double](repeating: 0, count: totalMinutes)
        var distr  = [Double](repeating: 0, count: totalMinutes)

        for e in events {
            let s = max(e.startedAt, from)
            let f = min(e.endedAt, to)
            guard f > s else { continue }

            // Clamp both bounds to a valid array index range. The predicate
            // can let through edge events where the floor of the start minute
            // lands at totalMinutes; without the explicit clamp we'd build
            // an invalid `start...end` range and trap.
            let rawStart = Int(s.timeIntervalSince(from) / 60)
            let rawEnd   = Int(f.timeIntervalSince(from) / 60)
            let startMin = max(0, min(totalMinutes - 1, rawStart))
            let endMin   = max(0, min(totalMinutes - 1, rawEnd))
            guard startMin <= endMin else { continue }

            for m in startMin...endMin {
                let minStart = from.addingTimeInterval(Double(m) * 60)
                let minEnd   = minStart.addingTimeInterval(60)
                let segStart = max(s, minStart)
                let segEnd   = min(f, minEnd)
                let segDur   = max(0, segEnd.timeIntervalSince(segStart))
                let frac     = segDur / 60
                switch e.classification ?? .neutral {
                case .focus: focus[m] += frac
                case .neutral: neutr[m] += frac
                case .distraction: distr[m] += frac
                }
            }
        }

        return (0..<totalMinutes).map { i in
            TimelinePoint(
                minute: i,
                focus: min(1, focus[i]),
                neutral: min(1, neutr[i]),
                distraction: min(1, distr[i])
            )
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
            var classification: Classification
            var events: Int
            // Per-host breakdown — only populated for browser bundles. Maps
            // host (e.g. "github.com") → (seconds, dominant classification).
            var hosts: [String: (seconds: TimeInterval, classification: Classification)]
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

            if var existing = groups[key] {
                existing.seconds += dur
                existing.events += 1
                if let h = host {
                    let prev = existing.hosts[h] ?? (0, e.classification ?? .neutral)
                    existing.hosts[h] = (prev.seconds + dur, e.classification ?? prev.classification)
                }
                groups[key] = existing
            } else {
                var hosts: [String: (TimeInterval, Classification)] = [:]
                if let h = host {
                    hosts[h] = (dur, e.classification ?? .neutral)
                }
                groups[key] = Group(
                    kind: AppGlyph.kind(forBundleId: e.bundleIdentifier, name: e.appName),
                    name: e.appName,
                    bundleId: e.bundleIdentifier,
                    seconds: dur,
                    classification: e.classification ?? .neutral,
                    events: 1,
                    hosts: hosts
                )
            }
        }

        return groups.values
            .sorted { $0.seconds > $1.seconds }
            .prefix(limit)
            .map { g in
                let tabs = g.hosts
                    .map { TabUsage(host: $0.key, seconds: $0.value.seconds, classification: $0.value.classification) }
                    .sorted { $0.seconds > $1.seconds }
                return AppUsageEntry(
                    kind: g.kind,
                    name: g.name,
                    bundleId: g.bundleId,
                    classification: g.classification,
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
