import Foundation

/// Notices a few minutes of focused work outside a session, so FocusGuard
/// can offer to start one: "You've been in Xcode 5 minutes. Start a
/// session?" The session it starts counts from when that work began.
///
/// The stretch survives short blips, the ones `FocusRuns` allows: up to
/// 30 s away from focus apps, of which up to 10 s on a distraction. It ends
/// when the user leaves the Mac, starts a session or a break, or joins a call.
struct AutoStartDetector: Equatable {
    /// Focused this long before the offer.
    static let threshold: TimeInterval = 5 * 60
    /// A longer gap between ticks means the Mac slept: the stretch ends.
    static let maxTickGap: TimeInterval = 60

    /// One tick of what the user is doing.
    struct Sample {
        let appName: String
        let classification: Classification
        let at: Date
        /// False in a session, on a break, away from the Mac or in a call.
        let eligible: Bool
    }

    /// Focused work in progress.
    struct Stretch: Equatable {
        let start: Date
        /// Focus apps used, in the order first seen.
        var apps: [String]
        /// Already offered: one offer per stretch.
        var offered = false
    }

    /// What the offer says.
    struct Offer: Equatable {
        /// When the work began; a session started from the offer counts from here.
        let since: Date
        /// The app the work began in.
        let app: String
        /// Whether the whole stretch was in that one app.
        let oneApp: Bool
        let minutes: Int

        /// "You've been in Xcode 5 minutes", or "You've been focused for 5
        /// minutes" across several apps.
        var title: String {
            let length = NotificationPresenter.plural(minutes, "minute")
            return oneApp ? "You've been in \(app) \(length)" : "You've been focused for \(length)"
        }

        /// "Start a session? It counts from 10:02, when you opened Xcode."
        func body(locale: Locale = .current, calendar: Calendar = .current) -> String {
            "Start a session? It counts from \(HabitFormat.time(since, locale: locale, calendar: calendar)), when you opened \(app)."
        }
    }

    private(set) var stretch: Stretch?
    /// When the current blip away from focus began.
    private var blipStart: Date?
    /// When the distraction in progress began.
    private var driftStart: Date?
    private var lastSampleAt: Date?

    /// Feeds one tick; returns an offer the moment the stretch reaches the threshold.
    mutating func observe(_ sample: Sample) -> Offer? {
        if let last = lastSampleAt, sample.at.timeIntervalSince(last) > Self.maxTickGap { reset() }
        lastSampleAt = sample.at
        guard sample.eligible else { reset(); return nil }

        guard sample.classification == .focus else {
            guard stretch != nil else { return nil }
            let blip = blipStart ?? sample.at
            blipStart = blip
            driftStart = sample.classification == .distraction ? (driftStart ?? sample.at) : nil
            let drifted = driftStart.map { sample.at.timeIntervalSince($0) } ?? 0
            if sample.at.timeIntervalSince(blip) > FocusRuns.blipGrace || drifted > FocusRuns.driftBreak { reset() }
            return nil
        }

        blipStart = nil
        driftStart = nil
        guard var current = stretch else {
            stretch = Stretch(start: sample.at, apps: [sample.appName])
            return nil
        }
        if !current.apps.contains(sample.appName) { current.apps.append(sample.appName) }
        let elapsed = sample.at.timeIntervalSince(current.start)
        var offer: Offer?
        if !current.offered, elapsed >= Self.threshold {
            current.offered = true
            offer = Offer(since: current.start, app: current.apps.first ?? sample.appName,
                          oneApp: current.apps.count == 1, minutes: Int(elapsed / 60))
        }
        stretch = current
        return offer
    }

    /// Whether the stretch that began at `since` is still going, so a
    /// session started from its offer can count from then.
    func isOngoing(since: Date) -> Bool {
        guard let start = stretch?.start else { return false }
        return abs(start.timeIntervalSince(since)) < 1
    }

    mutating func reset() {
        stretch = nil
        blipStart = nil
        driftStart = nil
    }
}
