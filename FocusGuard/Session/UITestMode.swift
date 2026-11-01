import Foundation
import SwiftData

/// The copy of the app the UI tests launch (`-FocusGuardUITesting`). The real
/// FocusGuard may be running beside it with the same bundle id, so this copy
/// keeps to itself: an in-memory store with a little sample activity, and no
/// tracking, browser bridge, update checks, notifications, widgets or weekly
/// coach. It opens straight into the window.
enum UITestMode {
    static let argument = "-FocusGuardUITesting"
    static let isOn = ProcessInfo.processInfo.arguments.contains(argument)

    /// A week of mornings and today's last few hours, with a session each
    /// day, so every page has something to show.
    static func seed(_ context: ModelContext, now: Date = .now, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        for back in 1...7 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today),
                  let nine = calendar.date(byAdding: .hour, value: 9, to: day) else { continue }
            addSession(context, start: nine, focus: 50 * 60, drift: 5 * 60)
        }
        // Today: a finished session ending an hour ago, whatever the time.
        addSession(context, start: now.addingTimeInterval(-2 * 3600), focus: 45 * 60, drift: 6 * 60)
        try? context.save()
    }

    private static func addSession(_ context: ModelContext, start: Date, focus: TimeInterval, drift: TimeInterval) {
        let session = Session(startedAt: start, status: .completed, plannedDurationMinutes: 50)
        session.endedAt = start.addingTimeInterval(focus + drift)
        context.insert(session)
        let work = ActivityEvent(startedAt: start, endedAt: start.addingTimeInterval(focus),
                                 bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode", session: session)
        work.classification = .focus
        context.insert(work)
        let away = ActivityEvent(startedAt: start.addingTimeInterval(focus), endedAt: start.addingTimeInterval(focus + drift),
                                 bundleIdentifier: "com.apple.Safari", appName: "Safari",
                                 url: "https://x.com/home", session: session)
        away.classification = .distraction
        context.insert(away)
    }
}
