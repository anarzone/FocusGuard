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
                    seconds: dur
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
                    fractionOfTotal: totalDistr > 0 ? g.seconds / totalDistr : 0
                )
            }
    }
}

// MARK: - DistractionEntry

struct DistractionEntry: Identifiable, Hashable {
    let id = UUID()
    let kind: AppGlyphKind
    let name: String
    let subtitle: String
    let seconds: TimeInterval
    var fractionOfTotal: Double = 0

    var timeLabel: String {
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        let m = total / 60
        let s = total % 60
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }
}
