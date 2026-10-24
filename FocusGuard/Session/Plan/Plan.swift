import Foundation

/// What someone has: Free, the 14-day Pro trial, or Pro.
enum Plan: Hashable {
    case free
    case trial(endsAt: Date)
    case pro

    /// The trial: 14 days, no card.
    static let trialDays = 14
    /// The reminder goes out this many days before the trial ends.
    static let trialReminderDays = 2
    /// Reports on Free reach back this many days; Pro has full history.
    static let freeHistoryDays = 30
    /// Daily limits on Free; Pro has no cap.
    static let freeDailyLimits = 1

    /// Pro, or a trial still running at `now`.
    func unlocksPro(at now: Date) -> Bool {
        switch self {
        case .free: return false
        case .trial(let endsAt): return now < endsAt
        case .pro: return true
        }
    }

    /// Days left in a trial, a part day counting as one; nil off a trial.
    func daysLeft(at now: Date) -> Int? {
        guard case .trial(let endsAt) = self else { return nil }
        return max(0, Int((endsAt.timeIntervalSince(now) / 86_400).rounded(.up)))
    }
}

/// Everything Pro adds. Free has tracking, sessions, breaks, reports,
/// manual categories, Pause the tab and one daily limit.
enum ProFeature: String, CaseIterable {
    case blockInBrowser
    case macWideBlock
    case partsOfSites
    case youtubePerVideo
    case unlimitedLimits
    case smartCategories
    case debrief
    case workLog
    case coach
    case fullHistory

    var title: String {
        switch self {
        case .blockInBrowser:  return "Block in the browser"
        case .macWideBlock:    return "Block on the whole Mac"
        case .partsOfSites:    return "Parts of sites"
        case .youtubePerVideo: return "YouTube video by video"
        case .unlimitedLimits: return "Unlimited daily limits"
        case .smartCategories: return "Smart categories"
        case .debrief:         return "Session debrief"
        case .workLog:         return "Work log"
        case .coach:           return "Weekly coach"
        case .fullHistory:     return "Full history"
        }
    }
}
