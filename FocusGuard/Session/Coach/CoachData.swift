import Foundation
import SwiftData

/// One stretch of tracked time, as a plain value the coach can work on off
/// the main thread. Window titles are never read: the coach works from
/// apps, sites and categories only.
struct CoachEvent: Equatable, Sendable {
    let start: Date
    let end: Date
    let kind: Classification
    /// A browser tab's host ("x.com", no "www."), else the app's bundle id.
    let target: String
    /// What to call it: the host, or the app's name.
    let name: String
    let isSite: Bool
    /// The session it was tracked in, if any.
    let session: UUID?

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// A finished session.
struct CoachSession: Equatable, Sendable {
    let id: UUID
    let start: Date
    let end: Date
    let plannedMinutes: Int?

    var minutes: Int { Int(max(0, end.timeIntervalSince(start)) / 60) }
}

/// What the coach reads for a stretch of days: every event in it, clipped
/// to it, and the sessions that started in it.
struct CoachData: Sendable {
    let interval: DateInterval
    let events: [CoachEvent]
    let sessions: [CoachSession]

    static func empty(_ interval: DateInterval) -> CoachData {
        CoachData(interval: interval, events: [], sessions: [])
    }

    /// The same data cut down to `interval`.
    func clipped(to interval: DateInterval) -> CoachData {
        CoachData(
            interval: interval,
            events: events.compactMap { event in
                let start = max(event.start, interval.start), end = min(event.end, interval.end)
                guard end > start else { return nil }
                return CoachEvent(start: start, end: end, kind: event.kind, target: event.target,
                                  name: event.name, isSite: event.isSite, session: event.session)
            },
            sessions: sessions.filter { interval.start <= $0.start && $0.start < interval.end }
        )
    }

    /// The events tracked in a session, by session.
    var eventsBySession: [UUID: [CoachEvent]] {
        var grouped: [UUID: [CoachEvent]] = [:]
        for event in events {
            if let id = event.session { grouped[id, default: []].append(event) }
        }
        return grouped
    }

    /// Days with anything tracked.
    func activeDays(calendar: Calendar) -> Set<Date> {
        Set(events.map { calendar.startOfDay(for: $0.start) })
    }

    /// Focused and drifted seconds over `events`.
    static func tally(_ events: [CoachEvent]) -> (focus: TimeInterval, drift: TimeInterval) {
        events.reduce(into: (focus: 0.0, drift: 0.0)) { total, event in
            switch event.kind {
            case .focus:       total.focus += event.duration
            case .distraction: total.drift += event.duration
            case .neutral:     break
            }
        }
    }
}

/// Reads `CoachData` from the store.
enum CoachDataReader {
    /// Plain reads of `context`; safe on any thread that owns it.
    static func read(_ context: ModelContext, interval: DateInterval) -> CoachData {
        let from = interval.start, to = interval.end
        let events = Persistence.fetch(context, FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.endedAt >= from && $0.startedAt < to },
            sortBy: [SortDescriptor(\.startedAt)]
        )).compactMap { event -> CoachEvent? in
            let start = max(event.startedAt, from), end = min(event.endedAt, to)
            guard end > start else { return nil }
            var host = BrowserTabReader.isBrowser(bundleIdentifier: event.bundleIdentifier)
                ? event.url.flatMap { URL(string: $0)?.host?.lowercased() } : nil
            if let h = host, h.hasPrefix("www.") { host = String(h.dropFirst(4)) }
            return CoachEvent(start: start, end: end, kind: event.classification ?? .neutral,
                              target: host ?? event.bundleIdentifier, name: host ?? event.appName,
                              isSite: host != nil, session: event.session?.id)
        }
        let sessions = Persistence.fetch(context, FetchDescriptor<Session>(
            predicate: #Predicate { $0.startedAt >= from && $0.startedAt < to && $0.endedAt != nil },
            sortBy: [SortDescriptor(\.startedAt)]
        )).compactMap { session -> CoachSession? in
            guard let end = session.endedAt else { return nil }
            return CoachSession(id: session.id, start: session.startedAt, end: end,
                                plannedMinutes: session.plannedDurationMinutes)
        }
        return CoachData(interval: interval, events: events, sessions: sessions)
    }

    /// Reads on a fresh context off the main thread.
    static func read(_ container: ModelContainer, interval: DateInterval) async -> CoachData {
        await Task.detached(priority: .utility) {
            read(ModelContext(container), interval: interval)
        }.value
    }
}
