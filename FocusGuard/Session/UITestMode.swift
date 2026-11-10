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
        case "analyzer": return MainActor.assumeIsolated { seedAnalyzer(context, now: now, calendar: calendar) }
        case "cards":
            // One kind paused, one resting, for Settings' cards you let pass.
            var learning = IslandLearning()
            learning.entries[IslandKind.autoStart.rawValue] = .init(streak: 0, lastShown: now.addingTimeInterval(-86_400),
                                                                     pausedUntil: calendar.date(byAdding: .day, value: 12, to: calendar.startOfDay(for: now)),
                                                                     onProbation: true, pauses: 1)
            learning.entries[IslandKind.driftPrompt.rawValue] = .init(streak: 5, lastShown: now.addingTimeInterval(-86_400))
            learning.save(defaults)
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
        WeekProjectStore().save(WeekProjectSettings(clients: ["Onboarding": "Acme", "Login": "Acme", "Pricing": "Acme"]))
    }

    /// Three weeks of work with the same drifts again and again: x.com while
    /// Claude Code works, YouTube after Slack. And the waits behind them, for
    /// the Analyzer's triggers and its waits card.
    @MainActor
    private static func seedAnalyzer(_ context: ModelContext, now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        func add(_ start: Date, _ minutes: Double, _ app: String, site: String? = nil, title: String? = nil, bundle: String? = nil,
                 session: Session? = nil, _ kind: Classification) {
            let event = ActivityEvent(startedAt: start, endedAt: start.addingTimeInterval(minutes * 60),
                                      bundleIdentifier: site == nil ? bundle ?? "com.example.\(app)" : "com.google.Chrome",
                                      appName: site == nil ? app : "Google Chrome", url: site.map { "https://\($0)/" }, session: session)
            event.windowTitle = title
            event.classification = kind
            context.insert(event)
        }
        var made = 0
        for back in 1...21 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today),
                  !calendar.isDateInWeekend(day) else { continue }
            made += 1
            let at = { (hour: Double) in day.addingTimeInterval(hour * 3600) }
            add(at(9), 80, "Xcode", .focus)
            add(at(10 + 20 / 60), 3, "Terminal", title: "~/Projects/curiplay — claude", .focus)
            let drift = Double(6 + made % 6)
            add(at(10 + 23 / 60), drift, "Chrome", site: "x.com", .distraction)
            WaitLog.shared.add(WaitRecord(start: at(10 + 23 / 60), tool: "Claude Code", project: "Curiplay",
                                          seconds: drift * 60, drift: drift * 60, to: "x.com"))
            add(at(10 + (23 + drift) / 60), 90, "Xcode", .focus)
            if made % 2 == 0 {
                add(at(12), 3, "Slack", .neutral)
                add(at(12 + 3 / 60), 8, "Chrome", site: "youtube.com", .distraction)
            }
            add(at(12.25), 75, "Xcode", .focus)
            for (index, hour) in [14.0, 14.5, 15.0].enumerated() {
                let tool = index == 1 ? "Codex" : "Claude Code"
                WaitLog.shared.add(WaitRecord(start: at(hour), tool: tool, project: index == 2 ? "FocusGuard" : "Curiplay",
                                              seconds: 95, drift: 0))
            }
            // A call before lunch, and the work after it a little late.
            if made % 3 != 0 {
                add(at(11.75), 15, "Zoom", bundle: "us.zoom.xos", .neutral)
                add(at(12), 8, "Notes", .neutral)
            }
            // The afternoon's session breaks around minute 30.
            let session = Session(startedAt: at(14), status: .completed)
            session.endedAt = at(15)
            context.insert(session)
            let broke = Double(25 + (made % 3) * 5)
            add(at(14), broke, "Xcode", session: session, .focus)
            add(at(14 + broke / 60), 4, "Chrome", site: "youtube.com", session: session, .distraction)
            add(at(14 + (broke + 4) / 60), 60 - broke - 4, "Xcode", session: session, .focus)
            add(at(15), 60, "Xcode", .focus)
        }
        try? context.save()
        seedRuns(today: today, calendar: calendar)
        // "It's for work", said about one site on two days: the offer to sort it.
        for back in [5, 3] {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            FocusAnalyzer.shared.learn { $0.saidForWork(key: "reddit.com", name: "reddit.com", isSite: true, at: day, calendar: calendar) }
        }
    }

    /// The last week's tool runs as the tools timed them, and the waits on
    /// them, for the Analyzer's headline: Curiplay's answers sit while x.com
    /// is open, FocusGuard's mostly don't, and the tool on dotfiles doesn't
    /// say when it starts.
    @MainActor
    private static func seedRuns(today: Date, calendar: Calendar) {
        /// The hour it started, the minutes it worked, the minutes its answer
        /// sat while a distraction was open (nil: none was), and whether it
        /// stopped to ask.
        typealias Seeded = (hour: Double, worked: Double, sat: Double?, asked: Bool)
        let curiplay: [Seeded] = [
            (9.6, 4, nil, false), (10.3, 11, 6, false), (11.2, 7, 0, false), (13.4, 3, nil, true),
            (14.1, 14, 9, false), (15.3, 6, 4, true), (16.2, 9, nil, false),
        ]
        let focusGuard: [Seeded] = [(9.9, 5, nil, false), (11.6, 8, 2, false), (15.8, 12, nil, false), (16.9, 4, nil, true)]
        for back in 0...6 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today), !calendar.isDateInWeekend(day) else { continue }
            let stretch = 1 + Double(back % 3) * 0.15
            func run(_ item: Seeded, tool: String, project: String, site: String) {
                let start = day.addingTimeInterval(item.hour * 3600)
                let seconds = (item.worked * 60 * stretch).rounded()
                WaitLog.shared.add(RunRecord(start: start, tool: tool, project: project, seconds: seconds, asked: item.asked))
                guard let sat = item.sat else { return }
                // They left a minute in, and came back that long after it had finished.
                let late = (sat * 60 * stretch).rounded()
                WaitLog.shared.add(WaitRecord(start: start.addingTimeInterval(60), tool: tool, project: project,
                                              seconds: seconds - 60 + late, drift: seconds - 60 + late, to: site, exact: true,
                                              worked: seconds, ran: start, late: late > 0 ? late : nil))
            }
            for (index, item) in curiplay.prefix(4 + back % 4).enumerated() {
                run(item, tool: "Claude Code", project: "Curiplay", site: index % 3 == 2 ? "youtube.com" : "x.com")
            }
            for (index, item) in focusGuard.prefix(2 + back % 3).enumerated() {
                run(item, tool: index == 2 ? "Codex" : "Claude Code", project: "FocusGuard", site: "x.com")
            }
            if back % 2 == 1 {
                WaitLog.shared.add(WaitRecord(start: day.addingTimeInterval(17.5 * 3600), tool: "Aider", project: "dotfiles",
                                              seconds: 240, drift: back % 4 == 1 ? 180 : 0, to: back % 4 == 1 ? "youtube.com" : nil))
            }
        }
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
