import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// The app's snapshot as it will look at `date`; nil before FocusGuard
    /// has written one.
    let snapshot: SurfaceSnapshot?
}

/// Reads the app's snapshot and runs it ahead: an entry a minute while a
/// session or a break runs (so the rings move without the app), one when
/// it ends, and one at midnight when today starts over.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .sample(at: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let now = Date()
        let snapshot = SurfaceStore.shared?.readSnapshot()?.projected(to: now)
        completion(SnapshotEntry(date: now, snapshot: snapshot ?? (context.isPreview ? .sample(at: now) : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Self.timeline(for: SurfaceStore.shared?.readSnapshot(), now: .now))
    }

    static func timeline(for snapshot: SurfaceSnapshot?, now: Date, calendar: Calendar = .current) -> Timeline<SnapshotEntry> {
        guard let snapshot else {
            return Timeline(entries: [SnapshotEntry(date: now, snapshot: nil)], policy: .after(now.addingTimeInterval(15 * 60)))
        }
        let dates = snapshot.timelineDates(now: now, calendar: calendar)
        let entries = dates.map { SnapshotEntry(date: $0, snapshot: snapshot.projected(to: $0, calendar: calendar)) }
        let refresh = min(dates.last ?? now, now.addingTimeInterval(30 * 60))
        return Timeline(entries: entries, policy: .after(max(refresh, now.addingTimeInterval(60))))
    }
}

extension SurfaceSnapshot {
    /// What the gallery shows before FocusGuard has written anything.
    static func sample(at now: Date, calendar: Calendar = .current) -> SurfaceSnapshot {
        let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        return SurfaceSnapshot(
            writtenAt: now, phase: .ready, session: nil, onBreak: nil,
            today: Day(start: calendar.startOfDay(for: now), focused: 135 * 60, drifted: 22 * 60, other: 30 * 60,
                       sessions: 3, goalSeconds: 4 * 3600, streak: 5),
            week: Week(start: week, focused: [265, 190, 290, 245, 135, 0, 0].map { TimeInterval($0 * 60) }),
            lastSession: Last(name: "Locked-in Deep Dive", endedAt: now.addingTimeInterval(-2 * 3600), minutes: 50, focusRate: 0.92),
            usualMinutes: 50
        )
    }
}
