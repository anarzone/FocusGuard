import SwiftUI

/// The three patterns side by side: when sessions break, the best hours,
/// getting back after a call. Each says "too few yet" until it can say more.
struct AnalyzerPatternCards: View {
    let patterns: AnalyzerPatterns

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) { cards.frame(minWidth: 230, maxWidth: .infinity) }
            VStack(spacing: 10) { cards }
        }
    }

    @ViewBuilder private var cards: some View {
        breaks
        hours
        calls
    }

    // MARK: When sessions break

    private var breaks: some View {
        AnalyzerCard {
            VStack(alignment: .leading, spacing: 8) {
                kicker(String(localized: "When sessions break", comment: "Analyzer card: how far into a session the first drift comes"))
                Text(breakTitle).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                let most = max(1, patterns.breaks.max() ?? 1)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(patterns.breaks.indices, id: \.self) { index in
                        breakBar(index, most: most)
                    }
                }
                .frame(height: 48, alignment: .bottom)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(breakTitle)
                axis(String(localized: "start", comment: "Analyzer axis: the start of a session"),
                     String(localized: "60 min", comment: "Analyzer axis: an hour into a session"))
            }
        }
    }

    private func breakBar(_ index: Int, most: Int) -> some View {
        let count = patterns.breaks[index]
        let height = max(2, CGFloat(count) / CGFloat(most) * 48)
        let from = index * 5
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(index == patterns.commonBreak ? Theme.distraction : Theme.gridFuture)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .help(String(localized: "Minute \(from) to \(from + 5): \(count)",
                         comment: "Analyzer bar: a 5-minute slice of a session, then how many broke in it"))
    }

    private var breakTitle: String {
        if let slice = patterns.commonBreak {
            return String(localized: "Most often between minute \(slice * 5) and \(slice * 5 + 5)",
                          comment: "Analyzer: the 5-minute slice of a session where focus most often breaks")
        }
        return String(localized: "Too few sessions yet: \(patterns.sessionsWithBreak) of \(AnalyzerPatterns.enoughBreaks)",
                      comment: "Analyzer: sessions that broke so far, of those needed")
    }

    // MARK: Best hours

    private var hours: some View {
        AnalyzerCard {
            VStack(alignment: .leading, spacing: 8) {
                kicker(String(localized: "Your best hours", comment: "Analyzer card: focus by hour of the day"))
                Text(hoursTitle).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 3) {
                    ForEach(patterns.hourRates.indices, id: \.self) { index in
                        hourCell(index)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(hoursTitle)
                axis("\(AnalyzerPatterns.firstHour):00", "\(AnalyzerPatterns.lastHour):00")
            }
        }
    }

    private func hourCell(_ index: Int) -> some View {
        let hour = AnalyzerPatterns.firstHour + index
        let rate = patterns.hourRates[index]
        let fill: Color
        let help: String
        if let rate {
            let strength = max(0, min(1, (rate - 0.3) / 0.6))
            fill = Theme.focus.opacity(0.12 + 0.88 * strength)
            let percent = Int((rate * 100).rounded())
            help = String(localized: "\(hour):00, \(percent)% focused", comment: "Analyzer: an hour, then its focus rate")
        } else {
            fill = Theme.gridFuture
            help = String(localized: "\(hour):00, too little tracked", comment: "Analyzer: an hour with too little data")
        }
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(fill)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .help(help)
    }

    private var hoursTitle: String {
        guard let best = patterns.bestHours else {
            return String(localized: "Not enough tracked yet", comment: "Analyzer: too little data for best hours")
        }
        return String(localized: "\(best.hour) to \(best.hour + 2): \(Int((best.rate * 100).rounded()))% focused",
                      comment: "Analyzer: the best two hours, then their focus rate: 9 to 11: 86% focused")
    }

    // MARK: After a call

    private var calls: some View {
        AnalyzerCard {
            VStack(alignment: .leading, spacing: 8) {
                kicker(String(localized: "Getting back after a call", comment: "Analyzer card: time back to work after a call"))
                Text(callsTitle).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                let longest = max(60, max(patterns.afterCall ?? 0, patterns.afterDrift ?? 0))
                VStack(alignment: .leading, spacing: 6) {
                    if let afterCall = patterns.afterCall {
                        row(String(localized: "After a call"), afterCall, longest, Theme.distraction)
                    }
                    if let afterDrift = patterns.afterDrift {
                        row(String(localized: "After a drift", comment: "Analyzer: back to work after drifting"), afterDrift, longest, Theme.gridFuture)
                    }
                }
            }
        }
    }

    private var callsTitle: String {
        if let afterCall = patterns.afterCall {
            return String(localized: "About \(max(1, Int((afterCall / 60).rounded()))) minutes after a call",
                          comment: "Analyzer: usual minutes back to work after a call")
        }
        if patterns.calls == 0 { return String(localized: "No calls seen yet", comment: "Analyzer: no calls in the period") }
        return String(localized: "Too few calls yet: \(patterns.calls) of \(AnalyzerPatterns.enoughCalls)",
                      comment: "Analyzer: calls so far, of those needed")
    }

    private func row(_ label: String, _ seconds: TimeInterval, _ longest: TimeInterval, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).frame(width: 74, alignment: .leading)
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color)
                    .frame(width: max(4, proxy.size.width * CGFloat(seconds / longest)))
            }
            .frame(height: 10)
            Text(WindowFormat.hm(seconds)).font(.system(size: 11)).monospacedDigit().frame(minWidth: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Parts

    private func kicker(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
    }

    private func axis(_ from: String, _ to: String) -> some View {
        HStack {
            Text(from)
            Spacer()
            Text(to)
        }
        .font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
    }
}
