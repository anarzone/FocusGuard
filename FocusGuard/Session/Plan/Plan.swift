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
    case taskGoals
    case ask
    case monthlyReview
    case analyzer
    case statusSync
    case fullHistory

    var title: String {
        switch self {
        case .blockInBrowser:  return String(localized: "Block in the browser")
        case .macWideBlock:    return String(localized: "Block on the whole Mac")
        case .partsOfSites:    return String(localized: "Parts of sites")
        case .youtubePerVideo: return String(localized: "YouTube video by video")
        case .unlimitedLimits: return String(localized: "Unlimited daily limits")
        case .smartCategories: return String(localized: "Smart categories")
        case .debrief:         return String(localized: "Session debrief")
        case .workLog:         return String(localized: "Your week")
        case .coach:           return String(localized: "Weekly coach")
        case .taskGoals:       return String(localized: "Tasks as session goals")
        case .ask:             return String(localized: "Ask", comment: "A Pro feature: asking questions about your own focus")
        case .monthlyReview:   return String(localized: "Month in review")
        case .analyzer:        return String(localized: "Analyzer", comment: "A Pro feature: why focus gets lost, and fair tests of fixes")
        case .statusSync:      return String(localized: "Status in Slack and Discord")
        case .fullHistory:     return String(localized: "Full history")
        }
    }
}
