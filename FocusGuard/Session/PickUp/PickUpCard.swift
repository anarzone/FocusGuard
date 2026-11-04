import Foundation

/// The running or paused session, as the card needs it.
struct PickUpSessionInfo: Equatable {
    var goal: String?
    var isPaused: Bool
    /// Nil for an open-ended session.
    var minutesLeft: Int?
}

/// What the card says. Worked out here, away from the view, so the wording
/// can be tested.
struct PickUpCard: Equatable, Identifiable {
    enum Kind: Equatable { case call, away, drift, menu, failed }

    /// One line in the card's list.
    struct Row: Equatable, Identifiable {
        let place: PickUpPlace
        let detail: String?
        var id: String { place.id }
    }

    var id = UUID()
    var kind: Kind
    var top: String
    var title: String
    var sub: String
    var rows: [Row]
    /// "Resume your session too · 14 min left"; nil without a paused session.
    var resumeOffer: String?
    /// Nil when there's nothing to press but the way out.
    var primary: String?
    var secondary: String

    var places: [PickUpPlace] { rows.map(\.place) }

    // MARK: - A return

    static func returning(_ found: PickUpReturn, places: [PickUpPlace], session: PickUpSessionInfo?,
                          sawPrivateWindow: Bool) -> PickUpCard {
        let kind: Kind
        let top: String
        let duration = Self.duration(found.seconds)
        switch found.kind {
        case .call:
            kind = .call
            top = String(localized: "Back from your call · \(duration)")
        case .away:
            kind = .away
            top = String(localized: "Back after \(duration)", comment: "Back at the Mac after a time away: Back after 52 min")
        case .drift(let name):
            kind = .drift
            top = String(localized: "\(name) for \(duration)", comment: "Time on a distracting site: x.com for 6 min")
        }
        let shown = kind == .drift ? Array(places.prefix(1)) : places
        let goal = (session?.goal ?? places.first?.sessionGoal)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        let sub: String
        if let goal, !goal.isEmpty {
            title = String(localized: "You were working on “\(goal)”", comment: "The goal of the session, in the user's own words")
            sub = String(localized: "Your goal for this session")
        } else {
            if let site = places.first?.host {
                title = String(localized: "You were on \(site)", comment: "A website: You were on tradingview.com")
            } else {
                title = String(localized: "You were in \(lastWindow(places.first))", comment: "A window or app: You were in AuthSession.swift")
            }
            if sawPrivateWindow {
                sub = String(localized: "Private windows are never remembered")
            } else if kind == .drift, session?.isPaused == false {
                sub = String(localized: "Your session is still running")
            } else {
                sub = String(localized: "From your last windows")
            }
        }
        let primary = kind == .drift
            ? String(localized: "Back to \(shown.first?.shortAppName ?? "")")
            : String(localized: "Pick up", comment: "Button: go back to what you were doing")
        return PickUpCard(kind: kind, top: top, title: title, sub: sub,
                          rows: shown.map { Row(place: $0, detail: $0.what) },
                          resumeOffer: session.flatMap(resumeOffer), primary: primary,
                          secondary: String(localized: "Not now"))
    }

    private static func lastWindow(_ place: PickUpPlace?) -> String {
        guard let place else { return "" }
        // A long window name reads better as the app.
        guard let title = place.shortTitle, title.count <= 40 else { return place.appName }
        return title
    }

    private static func resumeOffer(_ session: PickUpSessionInfo) -> String? {
        guard session.isPaused else { return nil }
        guard let left = session.minutesLeft else { return String(localized: "Resume your session too") }
        return String(localized: "Resume your session too · \(left) min left")
    }

    /// "38 min", "1 h 5 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return String(localized: "\(minutes) min", comment: "Compact minutes") }
        let hours = minutes / 60, rest = minutes % 60
        if rest == 0 { return String(localized: "\(hours) h", comment: "Hours away from the Mac") }
        return String(localized: "\(hours) h \(rest) min", comment: "Hours and minutes away from the Mac")
    }

    // MARK: - From the menu

    /// "Where you left off": the last places, newest first.
    static func lastPlaces(_ places: [PickUpPlace], now: Date, calendar: Calendar = .current) -> PickUpCard {
        let today = places.first.map { calendar.isDate($0.at, inSameDayAs: now) } ?? true
        return PickUpCard(
            kind: .menu,
            top: today ? String(localized: "Earlier today") : String(localized: "Earlier this week"),
            title: String(localized: "Where you left off"),
            sub: String(localized: "Your last places, newest first"),
            rows: places.map {
                Row(place: $0, detail: String(localized: "at \(when($0.at, now: now, calendar: calendar))",
                                              comment: "When you were last in an app: at 14:00"))
            },
            resumeOffer: nil,
            primary: places.first.map { pickUpTitle(for: $0, now: now, calendar: calendar) },
            secondary: String(localized: "Close")
        )
    }

    /// "Pick up 14:00".
    static func pickUpTitle(for place: PickUpPlace, now: Date, calendar: Calendar = .current) -> String {
        String(localized: "Pick up \(when(place.at, now: now, calendar: calendar))", comment: "Button: go back to the place you were at this time")
    }

    /// "14:00" today, "Mon 14:00" on another day.
    private static func when(_ date: Date, now: Date, calendar: Calendar) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? MomentText.time(date)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    // MARK: - Something didn't come back

    /// "Xcode and Terminal are back. Arc couldn't reopen one page."
    static func failed(back: [PickUpPlace], failed: [PickUpPlace]) -> PickUpCard {
        let names = ListFormatter.localizedString(byJoining: back.map(\.appName))
        let title: String
        switch back.count {
        case 0:  title = String(localized: "Nothing came back")
        case 1:  title = String(localized: "\(names) is back", comment: "An app was brought back to the front")
        default: title = String(localized: "\(names) are back", comment: "Two or three apps were brought back to the front")
        }
        let first = failed.first
        let sub = first?.url == nil
            ? String(localized: "\(first?.appName ?? "") couldn't open")
            : String(localized: "\(first?.appName ?? "") couldn't reopen one page")
        return PickUpCard(kind: .failed, top: String(localized: "Back in place"), title: title, sub: sub,
                          rows: failed.map { Row(place: $0, detail: $0.what) }, resumeOffer: nil,
                          primary: failed.contains { $0.url != nil } ? String(localized: "Open in browser") : nil,
                          secondary: String(localized: "Skip"))
    }
}
