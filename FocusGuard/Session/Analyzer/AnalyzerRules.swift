import Foundation

/// Every threshold behind the Analyzer, in one place. All of it is fixed
/// rules over tracked data: no model reads or words anything here.
enum AnalyzerRules {
    // MARK: Days

    /// The period looked at, finished days only, and the equal one before it.
    static let periodDays = 28
    /// Nothing is named until this many working days are in the period.
    static let namingDays = 7
    /// A change against the period before shows only with this many in both.
    static let compareDays = 7
    /// A day off isn't a working day: it needs this much tracked and focused.
    static let workingDayTracked: TimeInterval = 60 * 60
    static let workingDayFocus: TimeInterval = 15 * 60
    /// A day with this share of its time in calls says little about attention:
    /// it stays out of the measures, of every cause but meetings, and of tests.
    static let callHeavyShare = 0.6

    // MARK: Stretches

    /// A break this short doesn't end a stretch.
    static let stretchGrace: TimeInterval = 60
    /// A stretch this long is a deep block; a gap between calls shorter than
    /// this can't hold one.
    static let deepBlock: TimeInterval = 25 * 60
    /// Tracker events of one app this close are one.
    static let sameEventGap: TimeInterval = 5
    /// Focus this short doesn't count as being back (Pick up's own rule).
    static let solidStretch = PickUpRules.enoughFocus
    /// Lost focus this short isn't a stretch of it (Pick up's own rule).
    static let shortestLoss = PickUpRules.shortestDrift
    /// Nothing tracked for this long: away from the Mac, not lost focus
    /// (Pick up's own rule).
    static let awayGap = PickUpRules.shortestAway
    /// Time in Teams this long is a call (Pick up's own rule); shorter, chat.
    static let shortestCall = PickUpRules.shortestCall
    /// Nothing tracked for this long before the first focus: the day starts
    /// after it, so the morning's news at home isn't "getting started".
    static let sitDownGap: TimeInterval = 15 * 60
    /// "Coming back" shows from this many returns, "getting started" from
    /// this many mornings.
    static let enoughReturns = 5
    static let enoughStarts = 3

    // MARK: What the causes leave out

    /// Distractions this soon after the last focused stretch count as lost:
    /// the day isn't over when the focus is. Later is the evening's own.
    static let afterLastWindow: TimeInterval = 2 * 60 * 60
    /// A day with no focused stretch got away when this much of it went to
    /// distractions; less is a light day.
    static let gotAwayMinimum: TimeInterval = 30 * 60
    /// The card shows from this much left out, over at least this many days.
    static let leftOutMinimum: TimeInterval = 30 * 60
    static let leftOutDays = 2

    // MARK: Causes

    /// A message app this close to where focus was lost explains it.
    static let messageLead: TimeInterval = 2 * 60
    /// Rapid switching: at least 3 apps, none held longer than the dwell, at
    /// least one switch every 2 minutes, for at least 8 minutes.
    static let churnDwell: TimeInterval = 3 * 60
    static let churnMinimum: TimeInterval = 8 * 60
    static let churnApps = 3
    static let churnSwitchesPerMinute = 0.5
    /// Lost time counts as an unclear task when churn covers this share of it.
    static let churnShare = 0.5
    /// The late part of a day starts this far through its working time.
    static let lateDayShare = 0.6
    /// A late-day pattern needs this many days with enough on both sides,
    /// this far a drop in focus rate overall, and lower on this share of days.
    static let lateDayDays = 5
    static let lateDaySideMinimum: TimeInterval = 30 * 60
    static let lateDayDrop = 0.2
    static let lateDayLowerShare = 0.6

    // MARK: Naming a cause

    /// To be named, a cause takes this long on average, on this share of the
    /// days that can speak for it, this many times over, so one odd week of
    /// calls can't name anything.
    static let causeDailyMinimum: TimeInterval = 15 * 60
    static let causeDayShare = 0.5
    static let causeEpisodes = 5
    /// Days without heavy calls needed before anything but meetings is named.
    static let causeClearDays = 5
    /// The top cause must be this many times the next, and this far ahead a
    /// day; otherwise they're called too close.
    static let causeLead = 1.5
    static let causeDailyMargin: TimeInterval = 10 * 60

    // MARK: Fixes

    /// Sessions with and without a goal are compared from this many of each.
    static let goalSessions = 5
    /// Asking for a goal does nothing without this many sessions, and this
    /// many of them without one. A message reminder needs sessions to go with.
    static let sessionsForAFix = 5
    static let goallessForAFix = 3
    static let protectedBlockMinutes = 50
    static let protectedBlockFirstHour = 9
    static let protectedBlockLastHour = 17

    // MARK: Experiments

    /// Half On, half Off.
    static let experimentDays = 10
    /// Skipped days are made up, at most this many times.
    static let maxMakeUps = 10
    /// In a seeded shuffle, neither arm runs longer than this, and each week
    /// holds both, so a busy week can't fake a result.
    static let longestRun = 3
    /// Below this in either arm: "Not enough days".
    static let verdictDays = 4
    /// "It worked" needs little overlap: picking one On and one Off day, On is
    /// better in at least 7 of 8 pairs (ties count half). That's a
    /// Mann-Whitney U over n·m, and 5 against 5 means a U of 22 or more, which
    /// chance alone reaches about 3 times in 100.
    static let verdictWinShare = 0.875
    /// And a clear gap between the medians: a fifth of the Off days', and at
    /// least the measure's own small amount.
    static let verdictGapShare = 0.2
    static let verdictGapMinutes = 5.0
    static let verdictGapBlocks = 0.5
}

/// Message apps and sites, by bundle ID and host.
enum AnalyzerApps {
    static let messagingBundleIds: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.microsoft.teams2", "com.microsoft.teams",
        "com.apple.mail", "com.apple.MobileSMS",
        "com.hnc.Discord",
        "ru.keepcoder.Telegram", "org.telegram.desktop", "com.tdesktop.Telegram",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "org.whispersystems.signal-desktop",
        "com.microsoft.Outlook",
        "com.readdle.SparkDesktop", "com.readdle.smartemail-Mac",
        "it.bloop.airmail2", "com.superhuman.electron", "com.freron.MailMate",
        "com.mimestream.Mimestream",
    ]

    static let messagingHosts = [
        "slack.com", "teams.microsoft.com", "teams.live.com", "discord.com",
        "web.whatsapp.com", "web.telegram.org", "messages.google.com",
        "mail.google.com", "outlook.office.com", "outlook.live.com", "mail.yahoo.com",
    ]

    static func isMessaging(target: String, isSite: Bool) -> Bool {
        isSite ? messagingHosts.contains { Classifier.host(target, matches: $0) }
            : messagingBundleIds.contains(target)
    }
}

/// The five explanations, in the order the rules try them.
enum AnalyzerCause: String, Codable, CaseIterable, Identifiable, Sendable {
    case meetings, chatAndMail, habit, unclearTask, tiredness

    var id: String { rawValue }

    /// A row's name: "Unclear task".
    var name: String {
        switch self {
        case .meetings:    return String(localized: "Meeting gaps", comment: "Analyzer: one of the reasons focus gets lost")
        case .chatAndMail: return String(localized: "Chat and mail", comment: "Analyzer: one of the reasons focus gets lost")
        case .habit:       return String(localized: "Habit sites", comment: "Analyzer: one of the reasons focus gets lost")
        case .unclearTask: return String(localized: "Unclear task", comment: "Analyzer: one of the reasons focus gets lost")
        case .tiredness:   return String(localized: "Late-day dip", comment: "Analyzer: one of the reasons focus gets lost. A pattern in the times, not a claim about how someone feels")
        }
    }

    /// The headline's words: "Unclear tasks".
    var title: String {
        self == .unclearTask ? String(localized: "Unclear tasks", comment: "Analyzer: headline, a reason focus gets lost") : name
    }

    /// Under the headline. What was seen, never a claim about why.
    var explanation: String {
        switch self {
        case .meetings:
            return String(localized: "The gaps between your calls are often too short for a 25-minute block. Of what FocusGuard can see, this takes the most time.")
        case .chatAndMail:
            return String(localized: "Focus often ends in or right after a message app. Of what FocusGuard can see, this takes the most time.")
        case .habit:
            return String(localized: "Focus often ends on a distracting site or app, with no message just before it. Of what FocusGuard can see, this takes the most time.")
        case .unclearTask:
            return String(localized: "You switch quickly between work apps, with no distracting site involved. A blocker may not help with this. Of what FocusGuard can see, this takes the most time.")
        case .tiredness:
            return String(localized: "Your focus rate drops later in the day against your own earlier hours, and nothing else here explains that time. This is a pattern in the times, not a claim about how you feel.")
        }
    }
}

/// What an experiment compares each day, calls left out. Higher is better.
enum AnalyzerMeasureKind: String, Codable, Sendable {
    case longestStretch, deepBlocks

    func value(_ day: AnalyzerDay) -> Double {
        switch self {
        case .longestStretch: return day.longest / 60
        case .deepBlocks:     return Double(day.deepBlocks)
        }
    }

    var minimumGap: Double {
        switch self {
        case .longestStretch: return AnalyzerRules.verdictGapMinutes
        case .deepBlocks:     return AnalyzerRules.verdictGapBlocks
        }
    }

    /// "41 min", "1.5".
    func format(_ value: Double) -> String {
        switch self {
        case .longestStretch: return String(localized: "\(Int(value.rounded())) min", comment: "Compact minutes")
        case .deepBlocks:     return value.formatted(.number.precision(.fractionLength(0...1)))
        }
    }

    /// "Your longest unbroken stretch, with calls left out".
    var compares: String {
        switch self {
        case .longestStretch: return String(localized: "Your longest unbroken stretch, with calls left out")
        case .deepBlocks:     return String(localized: "Your deep blocks a day, with calls left out")
        }
    }

    /// Over the result's chart.
    var chartTitle: String {
        switch self {
        case .longestStretch: return String(localized: "Longest unbroken stretch, each day in order")
        case .deepBlocks:     return String(localized: "Deep blocks, each day in order")
        }
    }
}

enum AnalyzerMath {
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
