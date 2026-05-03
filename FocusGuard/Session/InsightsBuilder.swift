import Foundation
import SwiftData

/// Derives the three "Highlights" cards on the Reports view from existing
/// ActivityEvent rows. Each method is independently optional — the card is
/// hidden when there isn't enough history to produce a meaningful number.
@MainActor
struct InsightsBuilder {
    let context: ModelContext

    // MARK: - Trend (focus this period vs prior period)

    struct Trend {
        let currentSeconds: TimeInterval
        let priorSeconds: TimeInterval
        /// Δ as a fraction (e.g. 0.22 = +22%). nil when prior period had no data.
        var deltaPercent: Double? {
            guard priorSeconds > 0 else { return nil }
            return (currentSeconds - priorSeconds) / priorSeconds
        }
    }

    func focusTrend(from: Date, to: Date) -> Trend {
        let current = ReportBuilder(context: context).breakdown(from: from, to: to).focus
        let length = to.timeIntervalSince(from)
        let priorTo = from
        let priorFrom = from.addingTimeInterval(-length)
        let prior = ReportBuilder(context: context).breakdown(from: priorFrom, to: priorTo).focus
        return Trend(currentSeconds: current, priorSeconds: prior)
    }

    // MARK: - Peak focus hour (last N days)

    /// Hour-of-day (0–23) with the highest average focus seconds across the
    /// last `daysBack` days. nil if there's no focus history at all.
    func peakFocusHour(daysBack: Int = 14, calendar: Calendar = .current) -> Int? {
        let now = Date()
        let from = calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: now)) ?? now
        let focusRaw = Classification.focus.rawValue
        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate {
                $0.endedAt >= from && $0.startedAt < now && $0.classificationRaw == focusRaw
            }
        )
        let events = (try? context.fetch(descriptor)) ?? []

        var perHour = [TimeInterval](repeating: 0, count: 24)
        for e in events {
            // Slice the event into per-hour chunks so a multi-hour focus
            // session is fairly attributed.
            var cursor = max(e.startedAt, from)
            let end = min(e.endedAt, now)
            while cursor < end {
                let hour = calendar.component(.hour, from: cursor)
                let nextHour = calendar.date(bySetting: .minute, value: 0, of: cursor.addingTimeInterval(3600)) ?? cursor.addingTimeInterval(3600)
                let chunkEnd = min(end, nextHour)
                let dur = chunkEnd.timeIntervalSince(cursor)
                perHour[hour] += max(0, dur)
                cursor = chunkEnd
            }
        }

        let total = perHour.reduce(0, +)
        guard total > 0 else { return nil }
        return perHour.indices.max(by: { perHour[$0] < perHour[$1] })
    }

    // MARK: - Top regression (biggest distraction host increase)

    struct HostDelta {
        let host: String
        let currentSeconds: TimeInterval
        let priorSeconds: TimeInterval
        var deltaSeconds: TimeInterval { currentSeconds - priorSeconds }
    }

    /// Distraction host whose seconds grew the most vs the prior period.
    /// Returns nil if no host shows a positive delta of at least 60s.
    func topRegression(from: Date, to: Date) -> HostDelta? {
        let length = to.timeIntervalSince(from)
        let priorTo = from
        let priorFrom = from.addingTimeInterval(-length)

        let current = distractionsByHost(from: from, to: to)
        let prior = distractionsByHost(from: priorFrom, to: priorTo)

        var best: HostDelta?
        let allHosts = Set(current.keys).union(prior.keys)
        for host in allHosts {
            let delta = (current[host] ?? 0) - (prior[host] ?? 0)
            if delta < 60 { continue }
            if best == nil || delta > best!.deltaSeconds {
                best = HostDelta(host: host, currentSeconds: current[host] ?? 0, priorSeconds: prior[host] ?? 0)
            }
        }
        return best
    }

    private func distractionsByHost(from: Date, to: Date) -> [String: TimeInterval] {
        let dRaw = Classification.distraction.rawValue
        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate {
                $0.endedAt >= from && $0.startedAt < to && $0.classificationRaw == dRaw && $0.url != nil
            }
        )
        let events = (try? context.fetch(descriptor)) ?? []
        var out: [String: TimeInterval] = [:]
        for e in events {
            guard let host = e.url.flatMap({ URL(string: $0)?.host?.replacingOccurrences(of: "www.", with: "") }) else { continue }
            let dur = max(0, min(e.endedAt, to).timeIntervalSince(max(e.startedAt, from)))
            out[host, default: 0] += dur
        }
        return out
    }
}
