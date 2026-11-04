import Foundation
import SwiftData

/// The copy of the app the UI tests launch (`-FocusGuardUITesting`). The real
/// FocusGuard may be running beside it with the same bundle id, so this copy
/// keeps to itself: an in-memory store with a little sample activity, and no
/// tracking, browser bridge, update checks, notifications, widgets or weekly
/// coach. It opens straight into the window.
enum UITestMode {
    static let argument = "-FocusGuardUITesting"
    /// A `var` so the unit tests can build an in-memory `AppState` too
    /// (`FlowAppStateTests`, on CI only).
    static var isOn = ProcessInfo.processInfo.arguments.contains(argument)

    /// Settings this copy keeps apart from the real app's, which shares its
    /// bundle id. Cleared when it starts.
    static let suiteName = "com.anar.focusguard.uitesting"

    /// Where to keep things the sample data would otherwise leave in the real app.
    static var defaults: UserDefaults {
        isOn ? UserDefaults(suiteName: suiteName) ?? .standard : .standard
    }

    /// A week of mornings and today's last few hours, with a session each
    /// day, so every page has something to show. `-FocusGuardUITestSeed`
    /// asks for another state: `empty`, `big` (years of data, long names) or
    /// `limits` (three daily limits).
    static func seed(_ context: ModelContext, now: Date = .now, calendar: Calendar = .current) {
        defaults.removePersistentDomain(forName: suiteName)
        switch UserDefaults.standard.string(forKey: "FocusGuardUITestSeed") {
        case "empty": return
        case "big": return seedBig(context, now: now, calendar: calendar)
        case "week": return seedWeek(context, now: now, calendar: calendar)
        case "limits":
            for (index, site) in ["first.example", "second.example", "third.example"].enumerated() {
                context.insert(DailyLimit(target: site, isSite: true, name: site, minutes: 30,
                                          createdAt: now.addingTimeInterval(TimeInterval(index - 10))))
            }
        default: break
        }
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

    /// A working week with goals, projects and a stretch without a goal: what
    /// Your week is for. It runs up to now, so the week always looks full,
    /// in the current week and the one before.
    private static func seedWeek(_ context: ModelContext, now: Date, calendar: Calendar) {
        struct Item {
            let day: Int, hour: Double, minutes: Double
            let goal: String?
            let project: String?
            var verdict: GoalVerdict?
            var app = "Xcode"
            var site: String?
        }
        let items = [
            Item(day: 0, hour: 9, minutes: 90, goal: "Onboarding flow", project: "Onboarding", verdict: .partly, app: "Figma"),
            Item(day: 0, hour: 11, minutes: 30, goal: "Ship the pricing page", project: "Pricing", verdict: .partly),
            Item(day: 0, hour: 13, minutes: 60, goal: nil, project: nil, app: "Safari", site: "github.com"),
            Item(day: 0, hour: 14.5, minutes: 60, goal: nil, project: nil, app: "Notes"),
            Item(day: 1, hour: 9, minutes: 60, goal: "Onboarding flow", project: "Onboarding", verdict: .partly, app: "Figma"),
            Item(day: 1, hour: 10.5, minutes: 160, goal: "Fix the login redirect (ENG-142)", project: "Login", verdict: .done),
            Item(day: 1, hour: 14, minutes: 210, goal: nil, project: nil, app: "Notes"),
            Item(day: 2, hour: 9, minutes: 75, goal: "Onboarding flow", project: "Onboarding", verdict: .partly, app: "Figma"),
            Item(day: 2, hour: 11, minutes: 80, goal: "Ship the pricing page", project: "Pricing", verdict: .done),
            Item(day: 2, hour: 13.5, minutes: 135, goal: nil, project: nil, app: "Notes"),
            Item(day: 3, hour: 9, minutes: 90, goal: "Onboarding flow", project: "Onboarding", verdict: .partly, app: "Figma"),
            Item(day: 3, hour: 11, minutes: 65, goal: nil, project: nil, app: "Safari", site: "github.com"),
            Item(day: 3, hour: 13, minutes: 85, goal: nil, project: nil, app: "Notes"),
            Item(day: 4, hour: 9, minutes: 55, goal: "Onboarding flow", project: "Onboarding", verdict: nil, app: "Figma"),
            Item(day: 4, hour: 10.5, minutes: 105, goal: nil, project: nil, app: "Notes"),
        ]
        // Monday, whichever day the calendar's week starts on.
        let thisWeek = ReportPeriod.week.interval(offset: 0, now: now, calendar: calendar)
        var week = thisWeek.start
        while calendar.component(.weekday, from: week) != 2, week < thisWeek.end {
            week = calendar.date(byAdding: .day, value: 1, to: week) ?? thisWeek.end
        }
        for weekBack in 0...1 {
            guard let monday = calendar.date(byAdding: .day, value: -7 * weekBack, to: week) else { continue }
            for item in items {
                guard let day = calendar.date(byAdding: .day, value: item.day, to: monday) else { continue }
                let start = day.addingTimeInterval(item.hour * 3600)
                // A little less last week, to compare against.
                let focus = item.minutes * 60 * (weekBack == 0 ? 1 : 0.86)
                let end = start.addingTimeInterval(focus)
                guard end <= now else { continue }
                let session = Session(startedAt: start, status: .completed)
                session.endedAt = end
                session.goal = item.goal
                session.goalVerdict = item.verdict
                session.project = item.project
                context.insert(session)
                let work = ActivityEvent(startedAt: start, endedAt: end, bundleIdentifier: "com.example.\(item.app)", appName: item.app,
                                         url: item.site.map { "https://\($0)/acme/login" }, session: session)
                work.classification = .focus
                context.insert(work)
            }
        }
        try? context.save()
    }

    /// Three years of long days under long names: what the pages have to
    /// hold in the end.
    private static func seedBig(_ context: ModelContext, now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        for back in 0...(3 * 365) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today),
                  let six = calendar.date(byAdding: .hour, value: 6, to: day) else { continue }
            let session = Session(startedAt: six, label: "A very long session name that goes on well past anything the row was built for",
                                  status: .completed, plannedDurationMinutes: 720)
            session.endedAt = six.addingTimeInterval(13 * 3600)
            context.insert(session)
            let work = ActivityEvent(startedAt: six, endedAt: six.addingTimeInterval(11 * 3600 + 5 * 60),
                                     bundleIdentifier: "com.example.long-named-app", appName: "An Application With A Really Very Long Name",
                                     session: session)
            work.classification = .focus
            context.insert(work)
            let away = ActivityEvent(startedAt: six.addingTimeInterval(11 * 3600 + 5 * 60), endedAt: six.addingTimeInterval(13 * 3600),
                                     bundleIdentifier: "com.apple.Safari", appName: "Safari",
                                     url: "https://a-rather-long-subdomain.an-extremely-long-domain-name-example.com/home", session: session)
            away.classification = .distraction
            context.insert(away)
        }
        context.insert(DailyLimit(target: "a-rather-long-subdomain.an-extremely-long-domain-name-example.com", isSite: true,
                                  name: "a-rather-long-subdomain.an-extremely-long-domain-name-example.com", minutes: 240))
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
