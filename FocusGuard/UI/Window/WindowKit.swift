import AppKit
import SwiftUI

// MARK: - Window tokens

/// Colours only the main window uses, from the app-window canvas. Light
/// values first, then dark (`TodayDark`, `ReportsDark`).
extension Theme {
    /// Captions and axis labels: #6E6E78, #8E8E98 on dark.
    static let tertiaryText = windowColor(
        light: Color(red: 110/255, green: 110/255, blue: 120/255),
        dark:  Color(red: 142/255, green: 142/255, blue: 152/255)
    )
    /// Body copy in cards and legends: #3A3A42, #D1D1D6 on dark.
    static let bodyText = windowColor(
        light: Color(red: 58/255, green: 58/255, blue: 66/255),
        dark:  Color(red: 209/255, green: 209/255, blue: 214/255)
    )
    /// Behind a bar or a progress line.
    static let track = windowColor(light: Color.black.opacity(0.06), dark: Color.white.opacity(0.08))
    /// The day strip's empty lanes.
    static let lane = windowColor(light: Color.black.opacity(0.035), dark: Color.white.opacity(0.05))
    /// Thin rules inside cards.
    static let hairline = windowColor(light: Color.black.opacity(0.1), dark: Color.white.opacity(0.12))
    /// A hovered list row.
    static let rowHover = windowColor(light: Color.black.opacity(0.045), dark: Color.white.opacity(0.06))
    /// Header buttons, the day stepper and Export.
    static let headerControl = windowColor(light: Color.white.opacity(0.9), dark: Color.white.opacity(0.1))
    static let headerControlStroke = windowColor(light: Color.black.opacity(0.1), dark: Color.white.opacity(0.1))
    /// The Week | Month switch's track and its picked half.
    static let switchTrack = windowColor(light: Color.black.opacity(0.06), dark: Color.white.opacity(0.08))
    static let switchThumb = windowColor(light: Color.white, dark: Color.white.opacity(0.16))
    /// The picked length in "Ready to focus": near-black, near-white on dark.
    static let choiceFill = windowColor(
        light: Color(red: 29/255, green: 29/255, blue: 31/255),
        dark:  Color(red: 245/255, green: 245/255, blue: 247/255)
    )
    static let choiceText = windowColor(
        light: Color.white,
        dark:  Color(red: 29/255, green: 29/255, blue: 31/255)
    )
    /// The sidebar's glass where Liquid Glass isn't available.
    static let sidebarGlass = windowColor(
        light: Color.white.opacity(0.62),
        dark:  Color(red: 48/255, green: 48/255, blue: 58/255).opacity(0.62)
    )
    /// The session card at the foot of the sidebar.
    static let sidebarCard = windowColor(light: Color.white.opacity(0.8), dark: Color.white.opacity(0.07))
    /// The goal ring's empty track.
    static let goalTrack = windowColor(
        light: Color(red: 97/255, green: 85/255, blue: 245/255).opacity(0.12),
        dark:  Color(red: 109/255, green: 124/255, blue: 255/255).opacity(0.16)
    )
    /// Lighter indigo for past weeks and quieter bars (#C9C4FC).
    static let focusSoft = windowColor(
        light: Color(red: 201/255, green: 196/255, blue: 252/255),
        dark:  Color(red: 109/255, green: 124/255, blue: 255/255).opacity(0.45)
    )
    /// A soft panel inside a card (notes, the drift line).
    static let inset = windowColor(light: Color.black.opacity(0.035), dark: Color.white.opacity(0.05))

    private static let darkNames: Set<NSAppearance.Name> = [
        .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark,
    ]

    fileprivate static func windowColor(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            darkNames.contains(appearance.name) ? NSColor(dark) : NSColor(light)
        })
    }
}

/// Bar and lane colour for each kind of time.
func windowKindColor(_ kind: SessionTimeline.Kind) -> Color {
    switch kind {
    case .focus: return Theme.focus
    case .drift: return Theme.distraction
    case .other: return Theme.other
    }
}

// MARK: - Formatting

/// How the window writes times and changes. Kept here rather than borrowed
/// from the menu, which is being rebuilt on its own.
enum WindowFormat {
    /// "3h 23m", "4h 05m", "47m", "4h", "0m".
    static func hm(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds)) / 60
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h " + String(format: "%02dm", m)
    }

    /// "41 min".
    static func minutes(_ seconds: TimeInterval) -> String {
        "\(Int(max(0, seconds)) / 60) min"
    }

    /// "18:40", in the user's own clock style.
    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "18:40–19:30".
    static func span(_ start: Date, _ end: Date) -> String {
        "\(clock(start))–\(clock(end))"
    }

    /// "+12%", "−8%": the change from `before` to `now`, nil when there's
    /// too little to compare.
    static func percentChange(_ now: TimeInterval, _ before: TimeInterval) -> String? {
        guard before >= 60 else { return nil }
        let pct = Int(((now - before) / before * 100).rounded())
        return "\(pct >= 0 ? "+" : "−")\(abs(pct))%"
    }

    /// "+2 pts", "−3 pts", "same".
    static func pointsChange(_ now: Double, _ before: Double) -> String {
        let pts = Int(((now - before) * 100).rounded())
        if pts == 0 { return "same" }
        return "\(pts > 0 ? "+" : "−")\(abs(pts)) pts"
    }

    /// "+25m", "−8m", "new" for a distraction against the period before.
    static func minutesChange(_ now: TimeInterval, _ before: TimeInterval?) -> String {
        guard let before, before >= 60 else { return "new" }
        let delta = Int(((now - before) / 60).rounded())
        if delta == 0 { return "same" }
        return "\(delta > 0 ? "+" : "−")\(hm(TimeInterval(abs(delta) * 60)))"
    }

    /// "1 day", "3 days".
    static func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        "\(n) \(n == 1 ? noun : plural ?? noun + "s")"
    }
}

// MARK: - Page chrome

/// Page header: big title and subtitle on the left, controls on the right.
struct PageHeader<Controls: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .kerning(-0.44)
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            controls()
        }
        .frame(height: 60)
    }
}

/// "37 minutes to your 4-hour goal. This session can cover most of it."
struct WindowHeadline: View {
    let lead: String
    let rest: String

    var body: some View {
        (Text(lead).fontWeight(.semibold).foregroundColor(Theme.primaryText)
            + Text(rest.isEmpty ? "" : " " + rest).foregroundColor(Theme.secondaryText))
            .font(.system(size: 15))
            .kerning(-0.15)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// White (dark grey on dark) rounded card for window content.
struct WindowCard<Content: View>: View {
    var padding = EdgeInsets(top: 14, leading: 20, bottom: 12, trailing: 20)
    var radius: CGFloat = 18
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(shape.fill(Theme.windowCard))
            .overlay(shape.strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
    }
}

/// A card's title row: "Sessions" on the left, a note or link on the right.
struct WindowCardTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension WindowCardTitle where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

extension WindowCardTitle where Trailing == Text {
    /// A grey note on the right: "last 4 weeks".
    init(_ title: String, note: String) {
        self.init(title: title) {
            Text(note).font(.system(size: 11)).foregroundColor(Theme.tertiaryText)
        }
    }
}

/// Header control: white capsule with a hairline, like Export.
struct HeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Theme.primaryText)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(HeaderCapsuleBackground())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

extension ButtonStyle where Self == HeaderButtonStyle {
    static var header: HeaderButtonStyle { HeaderButtonStyle() }
}

struct HeaderCapsuleBackground: View {
    var body: some View {
        Capsule()
            .fill(Theme.headerControl)
            .overlay(Capsule().strokeBorder(Theme.headerControlStroke, lineWidth: 0.5))
            .shadow(color: Color(red: 20/255, green: 30/255, blue: 60/255).opacity(0.06), radius: 3, y: 2)
    }
}

/// ‹ › stepper for days, weeks and months. `offset` counts back from now.
struct PeriodStepper: View {
    @Binding var offset: Int
    let unit: String
    /// How far back it may go; nil for no limit.
    var maxOffset: Int?

    var body: some View {
        HStack(spacing: 0) {
            Button { offset += 1 } label: {
                Image(systemName: "chevron.left").frame(width: 34, height: 32).contentShape(Rectangle())
            }
            .disabled(maxOffset.map { offset >= $0 } ?? false)
            .help("Previous \(unit)")
            .accessibilityLabel("Previous \(unit)")
            Rectangle().fill(Theme.headerControlStroke).frame(width: 0.5, height: 16)
            Button { offset = max(0, offset - 1) } label: {
                Image(systemName: "chevron.right").frame(width: 34, height: 32).contentShape(Rectangle())
            }
            .disabled(offset == 0)
            .help("Next \(unit)")
            .accessibilityLabel("Next \(unit)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.primaryText)
        .background(HeaderCapsuleBackground())
    }
}

/// Two or three choices on a grey track, the picked one raised in white:
/// Week | Month.
struct WindowSwitch<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var label: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let picked = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: picked ? .semibold : .regular))
                        .foregroundStyle(Theme.primaryText)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background {
                            if picked {
                                Capsule().fill(Theme.switchThumb)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.switchTrack))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A number with its label and a line under it, as in the KPI cards.
struct WindowStat: View {
    let label: String
    let value: String
    var detail: String?
    var valueSize: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            Text(value)
                .font(.system(size: valueSize, weight: .semibold).monospacedDigit())
                .kerning(-0.44)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A KPI card: one `WindowStat` on its own card.
struct WindowKPICard: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        WindowCard(padding: EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16), radius: 16) {
            WindowStat(label: label, value: value, detail: detail)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A legend entry: a small square and its name.
struct WindowLegend: View {
    let color: Color
    let title: String
    var dashed = false

    var body: some View {
        HStack(spacing: 5) {
            if dashed {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                    .frame(width: 8, height: 6)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            }
            Text(title)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.bodyText)
    }
}

/// An app's icon or a site's, small, for list rows.
struct WindowItemIcon: View {
    let name: String
    let bundleId: String?
    let host: String?
    var size: CGFloat = 20

    var body: some View {
        AppGlyph(kind: .generic, bundleId: host == nil ? bundleId : nil, host: host, size: size)
            .accessibilityHidden(true)
    }
}

/// A category chip that opens a menu to change it.
struct WindowCategoryPicker: View {
    let name: String
    let current: Classification
    let onChange: (Classification) -> Void

    var body: some View {
        Menu {
            ForEach([Classification.focus, .neutral, .distraction], id: \.self) { c in
                Button {
                    onChange(c)
                } label: {
                    if c == current { Label(categoryName(c), systemImage: "checkmark") } else { Text(categoryName(c)) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(CategoryChip.dot(current)).frame(width: 7, height: 7)
                Text(categoryName(current)).font(.system(size: 11)).foregroundStyle(Theme.primaryText)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Theme.chip))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("\(name): \(categoryName(current)). Change category")
    }
}

// MARK: - Rings

/// An arc from `start` to `end`, as fractions of a turn from 12 o'clock.
struct WindowArc: Shape {
    var start: Double
    var end: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(start, end) }
        set { start = newValue.first; end = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(start * 360 - 90), endAngle: .degrees(end * 360 - 90),
                    clockwise: false)
        return path
    }
}

/// The daily goal ring: in-session focus in indigo, focus between
/// sessions in a lighter shade after it.
struct WindowGoalRing<Center: View>: View {
    /// Fractions of the goal, 0...1.
    let inSession: Double
    let total: Double
    var lineWidth: CGFloat = 18
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            Circle().inset(by: lineWidth / 2).stroke(Theme.goalTrack, lineWidth: lineWidth)
            if total > 0 {
                WindowArc(start: 0, end: min(total, 0.9999))
                    .inset(lineWidth / 2)
                    .stroke(Theme.goalBetweenSessions, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            if inSession > 0 {
                WindowArc(start: 0, end: min(inSession, 0.9999))
                    .inset(lineWidth / 2)
                    .stroke(Theme.goalInSession, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            center()
        }
    }
}

extension WindowArc {
    /// The arc drawn `amount` in from the frame, so a stroke stays inside.
    func inset(_ amount: CGFloat) -> some Shape { InsetWindowArc(arc: self, amount: amount) }
}

private struct InsetWindowArc: Shape {
    let arc: WindowArc
    let amount: CGFloat

    func path(in rect: CGRect) -> Path { arc.path(in: rect.insetBy(dx: amount, dy: amount)) }
}

/// A session's ring: its minutes as focus, drift and other arcs, with a
/// knob where it's got to. `segments` come from `SessionTimeline.ringSegments`.
struct WindowSessionRing<Center: View>: View {
    let segments: [SessionTimeline.RingSegment]
    /// Where the knob sits, 0...1; nil for none.
    var knob: Double?
    var lineWidth: CGFloat = 10
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            Circle().inset(by: lineWidth / 2).stroke(Theme.track, lineWidth: lineWidth)
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                WindowArc(start: segment.start / 360, end: segment.end / 360)
                    .inset(lineWidth / 2)
                    .stroke(windowKindColor(segment.kind), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
            if let knob {
                GeometryReader { geo in
                    let r = min(geo.size.width, geo.size.height) / 2 - lineWidth / 2
                    let angle = knob * 2 * .pi
                    Circle()
                        .fill(Theme.windowCard)
                        .overlay(Circle().strokeBorder(Theme.focus, lineWidth: 2.5))
                        .frame(width: lineWidth + 3, height: lineWidth + 3)
                        .position(x: geo.size.width / 2 + r * sin(angle), y: geo.size.height / 2 - r * cos(angle))
                }
            }
            center()
        }
    }
}

extension WindowSessionRing where Center == EmptyView {
    init(segments: [SessionTimeline.RingSegment], knob: Double? = nil, lineWidth: CGFloat = 10) {
        self.init(segments: segments, knob: knob, lineWidth: lineWidth) { EmptyView() }
    }
}

/// A small ring for a focus rate, as in the session list.
struct WindowRateRing: View {
    let rate: Double
    var size: CGFloat = 24
    var lineWidth: CGFloat = 3.5

    var body: some View {
        ZStack {
            Circle().inset(by: lineWidth / 2).stroke(Theme.track, lineWidth: lineWidth)
            if rate > 0 {
                WindowArc(start: 0, end: min(rate, 0.9999))
                    .inset(lineWidth / 2)
                    .stroke(Theme.focus, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A thin bar, filled to `fraction`.
struct WindowBar: View {
    let fraction: Double
    var color: Color = Theme.focus
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                if fraction > 0 {
                    Capsule().fill(color)
                        .frame(width: max(height, geo.size.width * CGFloat(min(1, fraction))))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Layout

/// Columns that share a row by weight, like CSS `1.62fr 1fr`. Every
/// column gets the row's full height.
struct WindowSplitRow: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        let widths = columnWidths(width, count: subviews.count)
        let height = proposal.height ?? zip(subviews, widths)
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, columnWidths(bounds.width, count: subviews.count)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    private func columnWidths(_ total: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let weights = (0..<count).map { $0 < self.weights.count ? self.weights[$0] : 1 }
        let free = max(0, total - spacing * CGFloat(count - 1))
        let sum = max(0.001, weights.reduce(0, +))
        return weights.map { free * $0 / sum }
    }
}

/// A page that fills the window when there's room and scrolls when there
/// isn't: flexible rows stretch to the bottom edge, down to their minimum.
struct WindowScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                content()
                    .frame(minHeight: geo.size.height, alignment: .top)
            }
            .scrollIndicators(.automatic)
        }
    }
}
