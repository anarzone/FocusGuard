import EventKit
import Foundation

/// When the calendar says the user is busy, for the morning plan and the
/// wrap-up's "best time to start tomorrow". Only reads, and only when
/// Calendar access was already given (for calendar auto-start); it never
/// asks for it.
@MainActor
final class CalendarBusyTimes {
    private let store = EKEventStore()

    var canRead: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return true
        default: return false
        }
    }

    /// Timed events in the range that block time: all-day events, ones
    /// marked free and ones the user declined don't. Nil without access.
    func busy(from start: Date, to end: Date) -> [DateInterval]? {
        guard canRead, end > start else { return nil }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { event in
            guard !event.isAllDay, event.availability != .free, !Self.declined(event),
                  let from = event.startDate, let to = event.endDate, to > from else { return nil }
            return DateInterval(start: from, end: to)
        }
    }

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }
}
