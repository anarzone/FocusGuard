import Foundation

/// What happened in a session, as names and seconds: what the debrief
/// stands on, with the model or without it.
///
/// Window titles are only taken from apps that aren't opted out, even
/// when an older event still has one: titles for opted-out apps never
/// reach the model or the screen.
struct DebriefFacts: Equatable {
    /// One activity event, stripped down to what the debrief reads.
    struct Event: Equatable {
        let start: Date
        let end: Date
        let bundleId: String
        let appName: String
        let title: String?
        let url: String?
        let classification: Classification
    }

    /// An app, or a site for browser time.
    struct App: Equatable {
        let name: String
        let bundleId: String
        let isSite: Bool
        let classification: Classification
        let seconds: TimeInterval
    }

    struct Title: Equatable {
        let app: String
        let title: String
        let seconds: TimeInterval
        /// When it was first in front.
        let at: Date
    }

    /// A stretch in distracting apps or sites.
    struct Drift: Equatable {
        let name: String
        let start: Date
        let seconds: TimeInterval
        /// What was in front just before, and its title if allowed.
        let after: String?
        let afterTitle: String?
    }

    let goal: String?
    let start: Date
    let end: Date
    let focused: TimeInterval
    let drifted: TimeInterval
    let other: TimeInterval
    /// Most time first.
    let apps: [App]
    /// Allowed titles, most time first, at most `titleLimit`.
    let titles: [Title]
    /// In time order.
    let drifts: [Drift]

    static let titleLimit = 15

    var focusRate: Double { FocusRate.of(focused: focused, drifted: drifted) }
    var tracked: TimeInterval { focused + drifted + other }

    /// The site or app drifted to most, with its total.
    var topDrift: (name: String, seconds: TimeInterval)? {
        let totals = Dictionary(drifts.map { ($0.name, $0.seconds) }, uniquingKeysWith: +)
        return totals.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }
            .map { (name: $0.key, seconds: $0.value) }
    }

    /// - Parameter isOptedOut: whether an app's window titles must be left out.
    static func make(goal: String?, start: Date, end: Date, events: [Event],
                     isOptedOut: (String) -> Bool) -> DebriefFacts {
        let sorted = events.sorted { $0.start < $1.start }
        var focused: TimeInterval = 0, drifted: TimeInterval = 0, other: TimeInterval = 0
        var apps: [String: App] = [:]
        var order: [String] = []
        var titles: [String: Title] = [:]
        var drifts: [Drift] = []
        var lastDriftEnd: Date?
        var previous: (name: String, title: String?)?

        for event in sorted {
            // Each event covers its first through last 1 Hz sample, as in
            // SessionTimeline, so it stands for its duration plus a second.
            let seconds = max(0, event.end.timeIntervalSince(event.start)) + 1
            switch event.classification {
            case .focus:       focused += seconds
            case .distraction: drifted += seconds
            case .neutral:     other += seconds
            }

            let host = Self.host(event.url)
            let name = host ?? event.appName
            if let app = apps[name] {
                apps[name] = App(name: name, bundleId: app.bundleId, isSite: app.isSite,
                                 classification: app.classification, seconds: app.seconds + seconds)
            } else {
                apps[name] = App(name: name, bundleId: event.bundleId, isSite: host != nil,
                                 classification: event.classification, seconds: seconds)
                order.append(name)
            }

            let allowedTitle = isOptedOut(event.bundleId) ? nil : Self.clean(event.title)
            if let title = allowedTitle {
                let key = "\(name)\u{1}\(title)"
                if let known = titles[key] {
                    titles[key] = Title(app: name, title: title, seconds: known.seconds + seconds, at: known.at)
                } else {
                    titles[key] = Title(app: name, title: title, seconds: seconds, at: event.start)
                }
            }

            if event.classification == .distraction {
                if let last = drifts.last, last.name == name, let lastEnd = lastDriftEnd,
                   event.start.timeIntervalSince(lastEnd) < 60 {
                    drifts[drifts.count - 1] = Drift(name: name, start: last.start, seconds: last.seconds + seconds,
                                                     after: last.after, afterTitle: last.afterTitle)
                } else {
                    drifts.append(Drift(name: name, start: event.start, seconds: seconds,
                                        after: previous?.name, afterTitle: previous?.title))
                }
                lastDriftEnd = event.end
            } else {
                previous = (name, allowedTitle)
            }
        }

        let appList = order.compactMap { apps[$0] }
            .enumerated()
            .sorted { $0.element.seconds != $1.element.seconds ? $0.element.seconds > $1.element.seconds : $0.offset < $1.offset }
            .map(\.element)
        let titleList = titles.values
            .filter { $0.seconds >= 10 }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.at < $1.at }
        return DebriefFacts(
            goal: goal.flatMap(Self.clean), start: start, end: end,
            focused: focused, drifted: drifted, other: other,
            apps: appList, titles: Array(titleList.prefix(titleLimit)), drifts: drifts
        )
    }

    /// "github.com" from a URL, without "www.".
    static func host(_ url: String?) -> String? {
        guard let host = url.flatMap({ URL(string: $0)?.host }), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

extension DebriefFacts {
    /// The facts of a finished session, from its own events.
    @MainActor
    init(session: Session, isOptedOut: (String) -> Bool) {
        let events = session.events.map {
            Event(start: $0.startedAt, end: $0.endedAt, bundleId: $0.bundleIdentifier, appName: $0.appName,
                  title: $0.windowTitle, url: $0.url, classification: $0.classification ?? .neutral)
        }
        self = DebriefFacts.make(goal: session.goal, start: session.startedAt, end: session.endedAt ?? .now,
                                 events: events, isOptedOut: isOptedOut)
    }
}
