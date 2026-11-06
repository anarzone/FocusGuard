import SwiftUI

/// The island's colours and sizes. Near-black in light and dark mode alike.
enum IslandStyle {
    static let background = Color(red: 0x17 / 255, green: 0x16 / 255, blue: 0x1F / 255)
    /// White at these opacities on `background`: well over 4.5:1 (`IslandTests`).
    static let secondaryOpacity = 0.72
    static let bodyOpacity = 0.78

    static let pillSize = CGSize(width: 216, height: 38)
    static let cardWidth: CGFloat = 352
    static let pillRadius: CGFloat = 19
    static let cardRadius: CGFloat = 24
    /// The design's shadow: 0 16px 44px rgba(10, 10, 30, 0.42). A radius of 22
    /// is CSS's 44 blur: measured against it, within 0.01 of alpha at every distance.
    static let shadowRadius: CGFloat = 22
    static let shadowOffset: CGFloat = 16
    /// Room in the window around the island, for all of that shadow. Clicks
    /// here pass through (`IslandPanelController`).
    static let margin = EdgeInsets(top: 28, leading: 44, bottom: 60, trailing: 44)
}

/// What the view shows and how to answer. The panel controller owns it.
@MainActor
@Observable
final class IslandModel {
    enum Phase: Equatable { case gone, pill, card }

    var moment: IslandMoment?
    var phase: Phase = .gone
    var cardHeight: CGFloat = 130
    var now = Date()
    var motion = IslandMotion.spring
    var coordinator: PickUpCoordinator?
    var shortcut: String?
    @ObservationIgnored var onPress: (IslandButton) -> Void = { _ in }
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var onOpen: () -> Void = {}

    func size(for phase: Phase) -> CGSize {
        switch phase {
        case .gone: return CGSize(width: 40, height: 8)
        case .pill: return IslandStyle.pillSize
        case .card: return CGSize(width: IslandStyle.cardWidth, height: cardHeight)
        }
    }

    /// The card's height for this content: long text and other languages fit.
    static func fittedHeight(of moment: IslandMoment, now: Date, coordinator: PickUpCoordinator?, shortcut: String?) -> CGFloat {
        let host = NSHostingView(rootView: IslandCardBody(moment: moment, now: now, coordinator: coordinator, shortcut: shortcut,
                                                          animatesRing: false, onPress: { _ in }, onClose: {})
            .environment(\.colorScheme, .dark))
        return ceil(host.fittingSize.height)
    }
}

/// One shape that grows between the pill and the card, with the content
/// cross-fading. With Reduce Motion the two just cross-fade where they are.
struct IslandView: View {
    @Bindable var model: IslandModel

    var body: some View {
        Group {
            switch model.motion {
            case .spring:    morphing
            case .crossFade: crossFading
            }
        }
        .padding(IslandStyle.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("FocusGuard")
    }

    private var morphing: some View {
        let size = model.size(for: model.phase)
        return ZStack(alignment: .top) {
            switch model.phase {
            case .card: card.transition(model.motion.contentFade)
            case .pill: pill.transition(model.motion.contentFade)
            case .gone: EmptyView()
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .modifier(IslandShape(radius: model.phase == .card ? IslandStyle.cardRadius : IslandStyle.pillRadius))
        .animation(model.motion.change, value: model.phase)
        .animation(model.motion.change, value: model.cardHeight)
        .animation(model.motion.change, value: model.moment?.key)
        .opacity(model.phase == .gone ? 0 : 1)
        .animation(model.motion.fade, value: model.phase)
        .offset(y: model.phase == .gone ? -14 : 0)
        .animation(model.motion.change, value: model.phase)
    }

    private var crossFading: some View {
        ZStack(alignment: .top) {
            pill
                .modifier(IslandShape(radius: IslandStyle.pillRadius))
                .opacity(model.phase == .pill ? 1 : 0)
                .accessibilityHidden(model.phase != .pill)
            if model.phase == .card {
                card
                    .frame(height: model.cardHeight, alignment: .top)
                    .modifier(IslandShape(radius: IslandStyle.cardRadius))
                    .transition(model.motion.contentFade)
            }
        }
        .animation(model.motion.change, value: model.phase)
        .animation(model.motion.change, value: model.moment?.key)
    }

    @ViewBuilder
    private var pill: some View {
        if let moment = model.moment {
            Button { model.onOpen() } label: {
                IslandPillBody(moment: moment, now: model.now)
            }
            .buttonStyle(.plain)
            .id(moment.key)
            .accessibilityLabel(String(localized: "\(moment.shownPillName(at: model.now)), \(moment.shownPillValue(at: model.now))", comment: "The small island read aloud: x.com, 0:58"))
            .accessibilityHint(String(localized: "Opens the card"))
        }
    }

    @ViewBuilder
    private var card: some View {
        if let moment = model.moment {
            IslandCardBody(moment: moment, now: model.now, coordinator: model.coordinator, shortcut: model.shortcut,
                           animatesRing: moment.startsOpen && model.motion == .spring,
                           onPress: model.onPress, onClose: model.onClose)
                .id(moment.key)
        }
    }
}

/// The near-black shape, its ring of light and its shadow.
private struct IslandShape: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(IslandStyle.background)
            .clipShape(shape)
            // The ring of light sits just outside the shape, as a CSS spread does.
            .overlay(shape.inset(by: -0.25).stroke(.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: Color(red: 10 / 255, green: 10 / 255, blue: 30 / 255).opacity(0.42),
                    radius: IslandStyle.shadowRadius, y: IslandStyle.shadowOffset)
    }
}

/// The ring. Starts at the top and runs clockwise; a countdown's slides as it empties.
struct IslandRing: View {
    let fill: Double
    let tone: IslandTone
    let diameter: CGFloat
    let lineWidth: CGFloat
    var trackOpacity = 0.2
    /// Fills once when it appears: the finished session's.
    var fillsOnAppear = false

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var motion: Animation? {
        if reduceMotion { return nil }
        return fillsOnAppear ? .timingCurve(0.3, 0.8, 0.4, 1, duration: 1) : .linear(duration: 1)
    }

    var body: some View {
        let shown = fillsOnAppear && !appeared && !reduceMotion ? 0 : fill
        ZStack {
            Circle().stroke(.white.opacity(trackOpacity), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(tone.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter * 31.8 / 36, height: diameter * 31.8 / 36)
        .frame(width: diameter, height: diameter)
        .animation(motion, value: shown)
        .onAppear { appeared = true }
        .accessibilityHidden(true)
    }
}

/// Name on the left, value on the right.
struct IslandPillBody: View {
    let moment: IslandMoment
    let now: Date

    var body: some View {
        HStack(spacing: 9) {
            IslandRing(fill: moment.shownFill(at: now), tone: moment.tone, diameter: 24, lineWidth: 2.7)
            Text(moment.shownPillName(at: now))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(moment.shownPillValue(at: now))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(IslandStyle.secondaryOpacity))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(width: IslandStyle.pillSize.width, height: IslandStyle.pillSize.height)
        .contentShape(Rectangle())
    }
}

/// Everything the card says, at its fitted height.
struct IslandCardBody: View {
    let moment: IslandMoment
    let now: Date
    let coordinator: PickUpCoordinator?
    let shortcut: String?
    let animatesRing: Bool
    let onPress: (IslandButton) -> Void
    let onClose: () -> Void

    var body: some View {
        Group {
            if let card = moment.pickUp, let coordinator {
                PickUpCardView(card: card, coordinator: coordinator, shortcut: shortcut)
            } else {
                standard
            }
        }
        .frame(width: IslandStyle.cardWidth, alignment: .leading)
    }

    /// Stated, not left to the row: the height measured then matches the height drawn.
    private var headerTextWidth: CGFloat {
        let value = moment.shownValue(at: now).map {
            ceil(($0 as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)]).width) + 13
        }
        return IslandStyle.cardWidth - 28 - 46 - 12 - 12 - 24 - (value ?? 0)
    }

    private var standard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                IslandRing(fill: moment.shownFill(at: now), tone: moment.tone, diameter: 46, lineWidth: 4.3,
                           trackOpacity: 0.18, fillsOnAppear: animatesRing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(moment.shownKicker)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(IslandStyle.secondaryOpacity))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(moment.title)
                        .font(.system(size: 16, weight: .bold))
                        .kerning(-0.16)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                .frame(width: headerTextWidth, alignment: .leading)
                .frame(minHeight: 46)
                if let value = moment.shownValue(at: now) {
                    Text(value)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .fixedSize()
                        .frame(minHeight: 46)
                }
                IslandCloseButton(action: onClose)
            }
            if let chart = moment.weekChart {
                IslandWeekBars(chart: chart, animates: animatesRing)
            }
            Text(moment.shownBody(at: now))
                .font(.system(size: 12))
                .lineSpacing(2.5)
                .foregroundStyle(.white.opacity(IslandStyle.bodyOpacity))
                .fixedSize(horizontal: false, vertical: true)
            IslandButtonRow(primary: moment.buttons.first.map { button in (button.title, { onPress(button) }) },
                            secondary: moment.buttons.dropFirst().first.map { button in (button.title, { onPress(button) }) })
        }
        .padding(14)
    }
}

/// Friday's bars growing in, day by day, in the dark card's colours: the
/// page's three, a step lighter, and white for Other.
struct IslandWeekBars: View {
    let chart: IslandWeekChart
    let animates: Bool
    @State private var grown = false

    /// #8378F0, #0E9FB2, #C03D97: passes the colour-blind checks on the card.
    private static let colours = [Color(red: 0x83 / 255, green: 0x78 / 255, blue: 0xF0 / 255),
                                  Color(red: 0x0E / 255, green: 0x9F / 255, blue: 0xB2 / 255),
                                  Color(red: 0xC0 / 255, green: 0x3D / 255, blue: 0x97 / 255)]
    private let height: CGFloat = 66
    private let labelHeight: CGFloat = 15

    var body: some View {
        let most = max(1, chart.days.map(\.total).max() ?? 1)
        let scale = (height - labelHeight) / most
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(chart.days.enumerated()), id: \.offset) { index, day in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(spacing: 1) {
                        ForEach(Array(day.parts.reversed().enumerated()), id: \.offset) { position, part in
                            UnevenRoundedRectangle(topLeadingRadius: position == 0 ? 4 : 0, topTrailingRadius: position == 0 ? 4 : 0)
                                .fill(part.slot.map { Self.colours[min($0, Self.colours.count - 1)] } ?? Color.white.opacity(0.34))
                                .frame(width: 24, height: max(2, part.seconds * scale - (position == day.parts.count - 1 ? 0 : 1)))
                        }
                    }
                    .scaleEffect(y: !animates || grown ? 1 : 0, anchor: .bottom)
                    .animation(.spring(response: 0.5, dampingFraction: 0.72).delay(0.18 + Double(index) * 0.06), value: grown)
                    Text(day.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(IslandStyle.secondaryOpacity))
                        .lineLimit(1)
                        .frame(height: labelHeight)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: height)
        .onAppear { grown = true }
        .accessibilityHidden(true)
    }
}

/// Dismiss.
struct IslandCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Dismiss"))
    }
}

/// Side by side when they fit, stacked when they don't: labels never truncate.
struct IslandButtonRow<Chip: View>: View {
    let primary: (title: String, action: () -> Void)?
    let secondary: (title: String, action: () -> Void)?
    @ViewBuilder var chip: () -> Chip

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                primaryButton.frame(maxWidth: .infinity)
                secondaryButton
            }
            VStack(spacing: 6) {
                primaryButton.frame(maxWidth: .infinity)
                secondaryButton.frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if let primary {
            Button(action: primary.action) {
                HStack(spacing: 8) {
                    Text(primary.title)
                    chip()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(IslandButtonStyle(isPrimary: true))
        }
    }

    @ViewBuilder
    private var secondaryButton: some View {
        if let secondary {
            Button(secondary.title, action: secondary.action)
                .buttonStyle(IslandButtonStyle(isPrimary: primary == nil))
        }
    }
}

extension IslandButtonRow where Chip == EmptyView {
    init(primary: (title: String, action: () -> Void)?, secondary: (title: String, action: () -> Void)?) {
        self.init(primary: primary, secondary: secondary, chip: { EmptyView() })
    }
}

/// 30 points high: the primary white, the other translucent.
struct IslandButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: isPrimary ? .semibold : .medium))
            .foregroundStyle(isPrimary ? IslandStyle.background : .white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(Capsule().fill(isPrimary ? Color.white : Color.white.opacity(0.16)))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
