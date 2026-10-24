import Foundation

/// Finds times for focus sessions between calendar events.
///
/// Slots start on a grid (the hour and half hour), fit a whole session
/// before the next event, and are spread across the day rather than packed
/// at its start: first the slots are kept a share of the day apart, and if
/// that leaves too few, just a session plus a break apart.
enum FreeSlots {
    /// - Parameters:
    ///   - busy: calendar events; they may overlap and spill past `window`.
    ///   - window: when sessions may run.
    ///   - length: a session's length.
    ///   - count: how many slots are wanted.
    ///   - breakLength: the least time between one session's end and the next start.
    ///   - grid: slot starts are whole multiples of this from midnight.
    static func find(busy: [DateInterval], in window: DateInterval, length: TimeInterval, count: Int,
                     breakLength: TimeInterval, grid: TimeInterval = HabitSchedule.slotGrid,
                     calendar: Calendar = .current) -> [Date] {
        guard count > 0, length > 0, window.duration >= length else { return [] }
        let starts = candidates(busy: busy, in: window, length: length, grid: grid, calendar: calendar)
        let tight = length + breakLength
        let spread = max(tight, window.duration / Double(count))
        let spaced = pick(from: starts, count: count, gap: spread)
        return spaced.count == count ? spaced : pick(from: starts, count: count, gap: tight)
    }

    /// Every grid time in `window` where a whole session fits clear of `busy`.
    static func candidates(busy: [DateInterval], in window: DateInterval, length: TimeInterval,
                           grid: TimeInterval, calendar: Calendar = .current) -> [Date] {
        let midnight = calendar.startOfDay(for: window.start)
        let offset = window.start.timeIntervalSince(midnight)
        var cursor = midnight.addingTimeInterval((offset / grid).rounded(.up) * grid)
        var out: [Date] = []
        while cursor.addingTimeInterval(length) <= window.end {
            let session = DateInterval(start: cursor, duration: length)
            if !busy.contains(where: { overlaps($0, session) }) { out.append(cursor) }
            cursor = cursor.addingTimeInterval(grid)
        }
        return out
    }

    /// The earliest starts, each at least `gap` after the one before.
    private static func pick(from starts: [Date], count: Int, gap: TimeInterval) -> [Date] {
        var out: [Date] = []
        for start in starts where out.count < count {
            if let last = out.last, start.timeIntervalSince(last) < gap { continue }
            out.append(start)
        }
        return out
    }

    /// Touching end to start isn't overlapping.
    private static func overlaps(_ a: DateInterval, _ b: DateInterval) -> Bool {
        a.start < b.end && b.start < a.end
    }
}
