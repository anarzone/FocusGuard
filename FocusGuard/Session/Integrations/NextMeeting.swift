import Foundation

/// The next timed event in the chosen calendars, for the menu: "Standup in
/// 25 min · 10:30", from 30 minutes before it starts. FocusGuard's own
/// events, all-day ones and declined ones aren't meetings.
struct NextMeeting: Equatable, Identifiable {
    let id: String
    let title: String
    let start: Date

    /// The menu shows it from this long before.
    static let showFrom: TimeInterval = 30 * 60

    /// The first event starting after `now`.
    static func pick(from entries: [CalendarEntry], now: Date, ownIDs: Set<String>) -> NextMeeting? {
        entries
            .filter { !$0.isAllDay && !$0.isOwn && !$0.isDeclined && !ownIDs.contains($0.id) && $0.start > now }
            .min { $0.start < $1.start }
            .map {
                NextMeeting(id: $0.id,
                            title: $0.title.isEmpty ? String(localized: "A meeting", comment: "Stands in for a calendar event with no title") : $0.title,
                            start: $0.start)
            }
    }

    func isShown(at now: Date) -> Bool {
        start > now && start.timeIntervalSince(now) <= Self.showFrom
    }

    /// "in 25 min", "in 1 min".
    func countdown(at now: Date) -> String {
        let minutes = max(1, Int((start.timeIntervalSince(now) / 60).rounded(.up)))
        return String(localized: "in \(minutes) min", comment: "Countdown to the next meeting, on its own line")
    }

    /// The name as the start button says it: "ends before Standup". A long
    /// title is just "the meeting".
    var shortTitle: String {
        title.count <= 14 ? title : String(localized: "the meeting", comment: "Stands in for a long title on the start button: Start 25 min · ends before the meeting")
    }
}

/// A session length that ends before the next meeting.
enum MeetingFit {
    /// Shorter than this, a session before the meeting isn't worth it.
    static let shortest = 10
    static let step = 5

    /// The length to suggest instead of `minutes` so the session ends by
    /// `meeting`: the longest 5-minute step that fits. Nil when `minutes`
    /// already fits, or when less than 10 minutes are left.
    static func minutes(_ minutes: Int, now: Date, meeting: Date) -> Int? {
        let free = Int(meeting.timeIntervalSince(now) / 60)
        guard free < minutes else { return nil }
        let fitted = free / step * step
        return fitted >= shortest ? fitted : nil
    }

    /// Whether a session of `minutes` started now ends by `meeting`.
    static func endsBefore(_ minutes: Int, now: Date, meeting: Date) -> Bool {
        now.addingTimeInterval(TimeInterval(minutes * 60)) <= meeting
    }
}
