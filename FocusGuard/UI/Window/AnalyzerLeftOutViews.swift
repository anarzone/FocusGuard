import SwiftUI

/// The words for what the causes leave out.
enum AnalyzerLeftOutCopy {
    /// Facts only: time on distractions the causes don't read. Whether the
    /// evening was work time isn't known, so none of it is called lost.
    static func headline(_ out: AnalyzerLeftOut) -> String {
        String(localized: "\(WindowFormat.hm(out.after + out.away)) on distractions outside your focused stretches",
               comment: "Analyzer: time on distractions after the last stretch and on days with no focus")
    }

    static func body(_ out: AnalyzerLeftOut) -> String {
        var parts = [String(localized: "The causes only count the time between two focused stretches.",
                            comment: "Analyzer: what the causes read")]
        if out.afterDays > 0 {
            parts.append(out.afterDays == 1
                ? String(localized: "On one day, \(WindowFormat.hm(out.after)) more went to distractions in the 2 hours after your last stretch.",
                         comment: "Analyzer: the time")
                : String(localized: "On \(out.afterDays) days, \(WindowFormat.hm(out.after)) more went to distractions in the 2 hours after your last stretch.",
                         comment: "Analyzer: days, then the time"))
        }
        if out.awayDays > 0 {
            parts.append(out.awayDays == 1
                ? String(localized: "One day had no focused stretch at all, with \(WindowFormat.hm(out.away)) on distractions.",
                         comment: "Analyzer: the time")
                : String(localized: "\(out.awayDays) days had no focused stretch at all, with \(WindowFormat.hm(out.away)) on distractions.",
                         comment: "Analyzer: days, then the time"))
        }
        return parts.joined(separator: " ")
    }

    static func story(_ day: AnalyzerLeftOut.Day, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(locale: locale).weekday(.abbreviated).day()
        style.timeZone = calendar.timeZone
        let date = day.day.formatted(style)
        if day.gotAway {
            return String(localized: "\(date): no focused stretch, and \(WindowFormat.hm(day.unseen)) on distractions.",
                          comment: "Analyzer, one day: the date, then the time")
        }
        if day.isOff {
            return String(localized: "\(date): not a working day.", comment: "Analyzer, one day: a weekend or too little tracked")
        }
        let base = String(localized: "\(date): \(WindowFormat.hm(day.focused)) focused, \(WindowFormat.hm(day.between)) lost between stretches.",
                          comment: "Analyzer, one day: the date, focused time, then lost time")
        guard day.unseen > 0 else { return base }
        return base + " " + String(localized: "\(WindowFormat.hm(day.unseen)) more on distractions after the last one.",
                                   comment: "Analyzer, one day: time after the last focused stretch")
    }

    struct Tile: Equatable {
        let title: String
        let value: String
        let note: String
        let isLeftOut: Bool
    }

    static func tiles(_ out: AnalyzerLeftOut) -> [Tile] {
        let after: Tile = out.afterDays == 0
            ? Tile(title: String(localized: "After your last stretch", comment: "Analyzer tile"), value: "0m",
                   note: String(localized: "Nothing on distractions in the 2 hours after it.", comment: "Analyzer tile"), isLeftOut: true)
            : Tile(title: String(localized: "After your last stretch", comment: "Analyzer tile"), value: WindowFormat.hm(out.after),
                   note: String(localized: "On \(out.afterDays) of \(out.workingDays) days, about \(WindowFormat.hm(out.after / Double(out.afterDays))) each, in the 2 hours after it.",
                                comment: "Analyzer tile: days, working days, then the usual time"),
                   isLeftOut: true)
        let away: Tile = out.awayDays == 0
            ? Tile(title: String(localized: "Days that got away", comment: "Analyzer tile: days with no focused stretch"), value: "0",
                   note: String(localized: "Every working day had at least one focused stretch.", comment: "Analyzer tile"), isLeftOut: true)
            : Tile(title: String(localized: "Days that got away", comment: "Analyzer tile: days with no focused stretch"),
                   value: out.awayDays == 1
                       ? String(localized: "1 day · \(WindowFormat.hm(out.away))", comment: "Analyzer tile: the time")
                       : String(localized: "\(out.awayDays) days · \(WindowFormat.hm(out.away))", comment: "Analyzer tile: days, then the time"),
                   note: String(localized: "Weekdays with time on this Mac, not one focused stretch, and that much on distractions.",
                                comment: "Analyzer tile"),
                   isLeftOut: true)
        return [
            Tile(title: String(localized: "Between focused stretches", comment: "Analyzer tile"), value: WindowFormat.hm(out.between),
                 note: String(localized: "What the causes explain.", comment: "Analyzer tile"), isLeftOut: false),
            after, away,
        ]
    }
}

/// "What the numbers leave out": four weeks a day a column, the time
/// between stretches, after the last one, and the days that got away.
struct AnalyzerLeftOutCard: View {
    let leftOut: AnalyzerLeftOut
    @State private var picked: Date?

    private var pickedDay: AnalyzerLeftOut.Day? {
        leftOut.days.first { $0.day == picked } ?? leftOut.days.last { $0.gotAway } ?? leftOut.days.last { !$0.isOff }
    }

    var body: some View {
        AnalyzerCard {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) { title; Spacer(minLength: 12); legend }
                    VStack(alignment: .leading, spacing: 6) { title; legend }
                }
                Text(AnalyzerLeftOutCopy.headline(leftOut))
                    .font(.system(size: 20, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(AnalyzerLeftOutCopy.body(leftOut))
                    .font(.system(size: 13)).foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                chart
                if let day = pickedDay {
                    Text(AnalyzerLeftOutCopy.story(day))
                        .font(.system(size: 12)).foregroundStyle(Theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 10) { tiles }
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: some View {
        Text(String(localized: "What the numbers leave out", comment: "Analyzer card: lost time the causes don't explain"))
            .font(.system(size: 13, weight: .semibold))
    }

    private var legend: some View {
        HStack(spacing: 12) {
            key(Theme.focus, String(localized: "Focused", comment: "Analyzer legend"))
            key(Theme.distraction, String(localized: "Lost between stretches", comment: "Analyzer legend"))
            HStack(spacing: 4) {
                AnalyzerStripes().frame(width: 9, height: 9).clipShape(RoundedRectangle(cornerRadius: 2.5))
                Text(String(localized: "After the last stretch, or a day that got away", comment: "Analyzer legend"))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            .fixedSize()
        }
    }

    private func key(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2.5).fill(color).frame(width: 9, height: 9)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .fixedSize()
    }

    private var chart: some View {
        let most = max(1, leftOut.days.map { $0.focused + $0.between + $0.unseen }.max() ?? 1)
        let height: CGFloat = 110
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(leftOut.days) { day in
                let on = day.day == pickedDay?.day
                Button { picked = day.day } label: {
                    VStack(spacing: 1) {
                        Spacer(minLength: 0)
                        AnalyzerStripes()
                            .frame(height: CGFloat(day.unseen / most) * height)
                            .overlay { if day.gotAway { Rectangle().strokeBorder(Theme.distraction, lineWidth: 1) } }
                        Rectangle().fill(Theme.distraction).frame(height: CGFloat(day.between / most) * height)
                        Rectangle().fill(day.isOff ? Theme.gridFuture : Theme.focus)
                            .frame(height: day.isOff ? 2 : CGFloat(day.focused / most) * height)
                    }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
                    .frame(maxWidth: 16)
                    .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .bottom)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Theme.focusTint : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AnalyzerLeftOutCopy.story(day))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var tiles: some View {
        ForEach(AnalyzerLeftOutCopy.tiles(leftOut), id: \.title) { tile in
            VStack(alignment: .leading, spacing: 3) {
                Text(tile.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                Text(tile.value).font(.system(size: 18, weight: .bold)).monospacedDigit()
                Text(tile.note).font(.system(size: 11)).foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tile.isLeftOut ? Theme.distractionTint : Theme.chip))
        }
    }
}

/// Diagonal stripes in the distraction colour: time the causes don't read.
struct AnalyzerStripes: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.distraction.opacity(0.35)))
            var x: CGFloat = -size.height
            while x < size.width {
                var line = Path()
                line.move(to: CGPoint(x: x, y: size.height))
                line.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(line, with: .color(Theme.distraction), lineWidth: 1.5)
                x += 5
            }
        }
        .accessibilityHidden(true)
    }
}
