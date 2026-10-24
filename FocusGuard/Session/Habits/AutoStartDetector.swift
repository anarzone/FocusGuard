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
        var bundleId: String? = nil
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
        /// The first app's bundle id.
        let bundleId: String?
        /// Already offered: one offer per stretch.
        var offered = false
    }

    private(set) var stretch: Stretch?
    /// When the current blip away from focus began.
    private var blipStart: Date?
    /// When the distraction in progress began.
    private var driftStart: Date?
    private var lastSampleAt: Date?

    /// Feeds one tick; returns an offer the moment the stretch reaches the threshold.
    mutating func observe(_ sample: Sample) -> AutoStartOffer? {
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
            stretch = Stretch(start: sample.at, apps: [sample.appName], bundleId: sample.bundleId)
            return nil
        }
        if !current.apps.contains(sample.appName) { current.apps.append(sample.appName) }
        var offer: AutoStartOffer?
        if !current.offered, sample.at.timeIntervalSince(current.start) >= Self.threshold {
            current.offered = true
            offer = AutoStartOffer(since: current.start, appNames: current.apps, bundleId: current.bundleId)
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

/// The offer to start a session from focused work already under way. The
/// notification and the menu show it; `HabitsCoordinator.autoStartOffer`
/// holds it while that work goes on.
struct AutoStartOffer: Equatable {
    /// When the work began; a session started from the offer counts from here.
    let since: Date
    /// Focus apps used, in the order first seen.
    let appNames: [String]
    /// The first app's bundle id.
    let bundleId: String?

    /// Time since the work began, short blips included.
    func focusSeconds(now: Date = .now) -> TimeInterval {
        max(0, now.timeIntervalSince(since))
    }

    /// "You've been in Xcode 5 minutes", or "You've been focused for 5
    /// minutes" across several apps.
    func title(now: Date = .now) -> String {
        let length = NotificationPresenter.plural(Int(focusSeconds(now: now) / 60), "minute")
        guard appNames.count == 1, let app = appNames.first else { return "You've been focused for \(length)" }
        return "You've been in \(app) \(length)"
    }

    /// "Start a session? It counts from 10:02, when you opened Xcode."
    func body(locale: Locale = .current, calendar: Calendar = .current) -> String {
        let time = HabitFormat.time(since, locale: locale, calendar: calendar)
        return "Start a session? It counts from \(time), when you opened \(appNames.first ?? "it")."
    }
}
