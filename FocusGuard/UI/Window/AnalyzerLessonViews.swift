import SwiftUI

/// What the page can do with what the corrections taught, as plain values
/// and closures, so the cards render without the app.
struct AnalyzerLessonActions {
    var lessons = AnalyzerLessons()
    /// The site or app to offer counting as work: called work on enough days.
    var suggestion: AnalyzerLessons.WorkAnswer?
    /// Sorted as work from here, and still sorted that way.
    var counted: [AnalyzerLessons.WorkAnswer] = []
    /// Categories can't change now: a strict session is running.
    var isLocked = false
    var teach: (AnalyzerTrigger) -> Void = { _ in }
    var decline: (AnalyzerTrigger) -> Void = { _ in }
    var putBack: (AnalyzerTrigger) -> Void = { _ in }
    var countAsWork: (AnalyzerLessons.WorkAnswer) -> Void = { _ in }
    var keepAsking: (AnalyzerLessons.WorkAnswer) -> Void = { _ in }
}

/// The words for what was taught. A pattern is a site while a tool works,
/// a distraction after an app, or a distraction on its own.
enum AnalyzerLessonCopy {
    private static func parts(_ trigger: AnalyzerTrigger) -> (first: String?, last: String) {
        (trigger.steps.count > 1 ? trigger.steps.first?.label : nil, trigger.steps.last?.label ?? "")
    }

    static func question(_ trigger: AnalyzerTrigger) -> String {
        let (first, last) = parts(trigger)
        guard let first else {
            return String(localized: "Is \(last) fine for you?", comment: "Analyzer question: a distraction the user keeps ruling out")
        }
        if trigger.isWait {
            return String(localized: "Is \(last) while \(first) works fine for you?", comment: "Analyzer question: the site, then the tool")
        }
        return String(localized: "Is \(last) after \(first) fine for you?", comment: "Analyzer question: the distraction, then the app before it")
    }

    static func why(_ trigger: AnalyzerTrigger) -> String {
        let marked = trigger.moments.filter(\.isRuledOut).count
        let lead = String(localized: "You marked \(marked) of these as not a distraction. If that’s how you work, say so once and it stops counting here.",
                          comment: "Analyzer question: how many moments the user ruled out")
        if trigger.isWait, let tool = trigger.steps.first?.label {
            return lead + " " + String(localized: "The card won’t call it a drift while \(tool) works either.",
                                       comment: "Analyzer question, after the lead: the tool")
        }
        return lead + " " + String(localized: "A focus session still catches it: answer “It’s for work” there.",
                                   comment: "Analyzer question, after the lead. “It’s for work” is the block screen's button")
    }

    static func yes(_ trigger: AnalyzerTrigger) -> String {
        let (first, _) = parts(trigger)
        guard let first else { return String(localized: "Yes, it’s fine", comment: "Analyzer button: a pattern isn't a distraction") }
        if trigger.isWait {
            return String(localized: "Yes, it’s fine while \(first) works", comment: "Analyzer button: the tool")
        }
        return String(localized: "Yes, it’s fine after \(first)", comment: "Analyzer button: the app before the distraction")
    }

    static func taught(_ trigger: AnalyzerTrigger) -> String {
        let (first, last) = parts(trigger)
        guard let first else { return String(localized: "\(last) is fine", comment: "Analyzer, what you taught it: a distraction") }
        if trigger.isWait {
            return String(localized: "\(last) while \(first) works is fine", comment: "Analyzer, what you taught it: the site, then the tool")
        }
        return String(localized: "\(last) after \(first) is fine", comment: "Analyzer, what you taught it: the distraction, then the app before it")
    }

    /// What it took out of the period, and what it means from now on.
    static func took(_ trigger: AnalyzerTrigger) -> String {
        let after = trigger.isWait
            ? String(localized: "No drift card for it either.", comment: "Analyzer, what you taught it: a site that's fine while a tool works")
            : String(localized: "A focus session still catches it.", comment: "Analyzer, what you taught it: a pattern that's fine outside sessions")
        let time = WindowFormat.hm(trigger.seconds)
        let out: String
        switch trigger.count {
        case 0:  out = String(localized: "It hasn’t come up in the last 4 weeks.", comment: "Analyzer, what you taught it")
        case 1:  out = String(localized: "Taken out: once, \(time).", comment: "Analyzer, what you taught it: the time it took")
        default: out = String(localized: "Taken out: \(trigger.count) times, \(time).", comment: "Analyzer, what you taught it: times, then the time they took")
        }
        return out + " " + after
    }

    static func work(_ answer: AnalyzerLessons.WorkAnswer, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(locale: locale).weekday(.wide)
        style.timeZone = calendar.timeZone
        let names = answer.days.suffix(2).map { $0.formatted(style) }
        let ask = String(localized: "Count it as work from now on? It stops being caught, in sessions and here.",
                         comment: "Analyzer: offer to sort a site or app as work")
        if answer.days.count == 2, names.count == 2, names[0] != names[1] {
            return String(localized: "You said \(answer.name) was for work on \(names[0]) and \(names[1]).",
                          comment: "Analyzer: a site, then two weekdays") + " " + ask
        }
        return String(localized: "You said \(answer.name) was for work on \(answer.days.count) days.",
                      comment: "Analyzer: a site, then how many days") + " " + ask
    }
}

/// "Is youtube.com after Xcode fine for you?": asked once, when the user has
/// ruled out two of a pattern's moments.
struct AnalyzerLessonQuestion: View {
    let trigger: AnalyzerTrigger
    var teach: () -> Void = {}
    var decline: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AnalyzerLessonCopy.question(trigger))
                .font(.system(size: 14, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(AnalyzerLessonCopy.why(trigger))
                .font(.system(size: 12)).foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 6) { buttons }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.focusTint))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.focus, lineWidth: 1.5))
        .padding(.top, 4)
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }

    @ViewBuilder private var buttons: some View {
        Button(AnalyzerLessonCopy.yes(trigger), action: teach)
            .buttonStyle(.borderedProminent).tint(Theme.focus)
        Button(String(localized: "No, just those times", comment: "Analyzer button: only the marked moments weren't distractions"), action: decline)
    }
}

/// "What you taught it": the patterns that are fine, each with a way back,
/// and the site called work in sessions often enough to offer sorting it.
struct AnalyzerLessonsCard: View {
    let taught: [AnalyzerTrigger]
    let actions: AnalyzerLessonActions

    /// Every pattern that's fine: the ones seen in the period, then the ones
    /// that haven't come up in it.
    var rows: [AnalyzerTrigger] {
        let seen = Set(taught.map(\.id))
        return taught + actions.lessons.fine.filter { !seen.contains($0) }.map {
            AnalyzerTrigger(id: $0, steps: AnalyzerTriggers.steps(of: $0), moments: [], perDay: [], cause: nil)
        }
    }

    static func isWorthShowing(taught: [AnalyzerTrigger], actions: AnalyzerLessonActions) -> Bool {
        !taught.isEmpty || !actions.lessons.fine.isEmpty || !actions.counted.isEmpty || actions.suggestion != nil
    }

    var body: some View {
        AnalyzerCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "What you taught it", comment: "Analyzer card: what the user's corrections changed"))
                    .font(.system(size: 13, weight: .semibold))
                ForEach(rows) { trigger in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AnalyzerLessonCopy.taught(trigger))
                                .font(.system(size: 12, weight: .semibold))
                            Text(AnalyzerLessonCopy.took(trigger))
                                .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(String(localized: "Put it back")) { actions.putBack(trigger) }
                            .buttonStyle(.textLink)
                            .font(.system(size: 12))
                    }
                    .accessibilityElement(children: .contain)
                }
                ForEach(actions.counted) { answer in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "\(answer.name) counts as work", comment: "Analyzer, what you taught it: a site or app"))
                            .font(.system(size: 12, weight: .semibold))
                        Text(String(localized: "You called it work in sessions. Change it any time in Apps & Sites.",
                                    comment: "Analyzer, what you taught it. Apps & Sites is a page of the window"))
                            .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let answer = actions.suggestion {
                    if !rows.isEmpty || !actions.counted.isEmpty { Divider() }
                    Text(AnalyzerLessonCopy.work(answer))
                        .font(.system(size: 12)).foregroundStyle(Theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(String(localized: "Count it as work", comment: "Analyzer button: sort a site as work")) { actions.countAsWork(answer) }
                            .buttonStyle(.borderedProminent).tint(Theme.focus)
                            .disabled(actions.isLocked)
                        Button(String(localized: "Keep asking", comment: "Analyzer button: leave a site as it is")) { actions.keepAsking(answer) }
                        if actions.isLocked {
                            Text(String(localized: "Locked while a strict session runs.", comment: "Analyzer: why a site can't be sorted now"))
                                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}
