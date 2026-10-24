import AppKit
import SwiftUI

/// What the share image shows and how it looks.
struct ShareOptions: Equatable {
    enum Size: String, CaseIterable, Identifiable {
        case portrait = "Portrait", square = "Square"
        var id: String { rawValue }

        var pixels: CGSize {
            switch self {
            case .portrait: return CGSize(width: 1080, height: 1350)
            case .square:   return CGSize(width: 1080, height: 1080)
            }
        }
    }

    enum Look: String, CaseIterable, Identifiable {
        case light = "Light", dark = "Dark"
        var id: String { rawValue }
    }

    var size: Size = .portrait
    var look: Look = .light
    var timePerDay = true
    var sessionNames = true
    /// Off unless the user turns it on: it names apps and sites.
    var topPlaces = false
}

/// "My focus week": the 1080 px image the share composer previews and
/// exports. Its colours are fixed, not the Mac's appearance, so the image
/// looks the same wherever it's posted.
struct ShareWeekImage: View {
    let week: FocusWeek
    let options: ShareOptions
    /// The app icon for the header.
    let icon: NSImage?

    private var palette: Palette { options.look == .dark ? .dark : .light }
    private var square: Bool { options.size == .square }
    /// Square is tighter, so everything scales down a little.
    private var unit: CGFloat { square ? 0.9 : 1 }

    var body: some View {
        let size = options.size.pixels
        VStack(alignment: .leading, spacing: 0) {
            header
            Text("My focus week")
                .font(.system(size: (square ? 64 : 76), weight: .bold))
                .tracking(-0.03 * (square ? 64 : 76))
                .foregroundStyle(palette.text)
                .padding(.top, square ? 40 : 56)
            total
            if options.timePerDay {
                bars.padding(.top, square ? 40 : 52)
            }
            tiles.padding(.top, square ? 40 : 48)
            if options.sessionNames, !week.names.isEmpty {
                chips(week.names.map { "\($0.name) ×\($0.count)" })
                    .padding(.top, square ? 22 : 26)
            }
            if options.topPlaces, !week.places.isEmpty {
                places.padding(.top, square ? 20 : 24)
            }
            Spacer(minLength: 24)
            Text("Tracked on my Mac with FocusGuard")
                .font(.system(size: square ? 20 : 22))
                .foregroundStyle(palette.secondary)
        }
        .padding(.horizontal, square ? 80 : 88)
        .padding(.top, square ? 80 : 88)
        .padding(.bottom, 80)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(background)
        .environment(\.colorScheme, options.look == .dark ? .dark : .light)
    }

    // MARK: - Parts

    private var header: some View {
        HStack(spacing: 16) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: square ? 56 : 64, height: square ? 56 : 64)
            }
            Text("FocusGuard")
                .font(.system(size: square ? 26 : 28, weight: .semibold))
                .foregroundStyle(palette.text)
            Spacer(minLength: 0)
            Text(week.rangeLabel())
                .font(.system(size: square ? 26 : 28))
                .monospacedDigit()
                .foregroundStyle(palette.secondary)
        }
    }

    private var total: some View {
        let number = Text(FocusWeek.duration(week.focus))
            .font(.system(size: square ? 150 : 168, weight: .semibold))
            .tracking(-0.04 * (square ? 150 : 168))
            .monospacedDigit()
            .foregroundStyle(palette.accent)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
        let sessions = FocusWeek.counted(week.sessions, "session")
        return Group {
            if square {
                HStack(alignment: .firstTextBaseline, spacing: 22) {
                    number
                    Text("focused").font(.system(size: 30)).foregroundStyle(palette.secondary)
                }
                .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    number
                    Text("focused, across \(sessions)")
                        .font(.system(size: 32))
                        .foregroundStyle(palette.secondary)
                }
                .padding(.top, 18)
            }
        }
    }

    private var bars: some View {
        let height: CGFloat = square ? (options.sessionNames || options.topPlaces ? 180 : 220) : (options.topPlaces ? 240 : 270)
        let goal = TimeInterval(week.goalMinutes * 60)
        let top = max(week.days.map(\.focus).max() ?? 0, goal) * 1.06
        let best = week.days.indices.max { week.days[$0].focus < week.days[$1].focus }
        let gap: CGFloat = square ? 24 : 26
        return VStack(spacing: 14 * unit) {
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(week.days.indices, id: \.self) { index in
                        let day = week.days[index]
                        RoundedRectangle(cornerRadius: square ? 12 : 14, style: .continuous)
                            .fill(day.isWeekend ? palette.weekendBar : palette.bar)
                            .frame(height: top > 0 ? max(day.focus > 0 ? 6 : 0, height * CGFloat(day.focus / top)) : 0)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: height, alignment: .bottom)
                if goal > 0, top > 0 {
                    let y = height * CGFloat(goal / top)
                    Line()
                        .stroke(palette.goalLine, style: StrokeStyle(lineWidth: 3, dash: [9, 7]))
                        .frame(height: 3)
                        .offset(y: -y)
                    Text("\(FocusGoal.format(minutes: week.goalMinutes)) goal")
                        .font(.system(size: 22 * unit))
                        .foregroundStyle(palette.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .offset(y: -y - 12)
                }
            }
            .frame(height: height)
            .accessibilityHidden(true)
            HStack(spacing: gap) {
                ForEach(week.days.indices, id: \.self) { index in
                    Text(week.days[index].date.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 24 * unit, weight: index == best && week.focus > 0 ? .bold : .regular))
                        .foregroundStyle(index == best && week.focus > 0 ? palette.text : palette.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// "Most focused in Xcode, github.com and Terminal".
    private var places: some View {
        week.places.enumerated().reduce(Text("Most focused in ")) { text, item in
            let joiner = item.offset == 0 ? "" : (item.offset == week.places.count - 1 ? " and " : ", ")
            return text + Text(joiner) + Text(item.element).fontWeight(.semibold).foregroundColor(palette.text)
        }
        .font(.system(size: 26 * unit))
        .foregroundStyle(palette.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var tiles: some View {
        HStack(spacing: square ? 16 : 18) {
            tile("Focus rate", "\(week.focusPercent)%")
            tile("Longest in the zone", FocusWeek.duration(week.longestZone))
            if square {
                tile("Sessions", "\(week.sessions)")
            } else {
                tile("Goal met", FocusWeek.counted(week.goalDays, "day"))
            }
        }
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6 * unit) {
            Text(label)
                .font(.system(size: 24 * unit))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.system(size: 52 * unit, weight: .semibold))
                .tracking(-0.02 * 52 * unit)
                .monospacedDigit()
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.vertical, 26 * unit)
        .padding(.horizontal, 28 * unit)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28 * unit, style: .continuous)
                .fill(palette.tile)
                .overlay(RoundedRectangle(cornerRadius: 28 * unit, style: .continuous)
                    .strokeBorder(palette.tileStroke, lineWidth: 1))
        )
    }

    private func chips(_ items: [String]) -> some View {
        HStack(spacing: 12) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 24 * unit, weight: .semibold))
                    .foregroundStyle(palette.chipText)
                    .lineLimit(1)
                    .padding(.vertical, 12 * unit)
                    .padding(.horizontal, 20 * unit)
                    .background(Capsule().fill(palette.chip))
            }
        }
    }

    private var background: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: palette.background, startPoint: .top, endPoint: .bottom)
            ShieldOutline()
                .stroke(palette.shield, style: StrokeStyle(lineWidth: 1.2 * 16, lineJoin: .round))
                .frame(width: 720, height: 820)
                .offset(x: 250, y: -130)
                .opacity(options.look == .dark ? 0.6 : 0.5)
        }
        .clipped()
    }
}

// MARK: - Palette

private struct Palette {
    let background: [Color]
    let text: Color
    let secondary: Color
    let accent: Color
    let bar: Color
    let weekendBar: Color
    let goalLine: Color
    let tile: Color
    let tileStroke: Color
    let chip: Color
    let chipText: Color
    let shield: Color

    static let light = Palette(
        background: [Color(hex: 0xFBFAFF), Color(hex: 0xECE9FF)],
        text: Color(hex: 0x1D1D1F),
        secondary: Color(hex: 0x55555E),
        accent: Color(hex: 0x4B3FD9),
        bar: Color(hex: 0x6155F5),
        weekendBar: Color(hex: 0xA49DFA),
        goalLine: Color(hex: 0x1D1D1F).opacity(0.22),
        tile: Color.white.opacity(0.8),
        tileStroke: Color(hex: 0x4B3FD9).opacity(0.08),
        chip: Color(hex: 0x6155F5).opacity(0.12),
        chipText: Color(hex: 0x4B3FD9),
        shield: Color(hex: 0xDAD5FF)
    )

    static let dark = Palette(
        background: [Color(hex: 0x17161F), Color(hex: 0x1E1B33), Color(hex: 0x2A2347)],
        text: Color(hex: 0xF5F5F7),
        secondary: Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.66),
        accent: Color(hex: 0x9AA4FF),
        bar: Color(hex: 0x6D7CFF),
        weekendBar: Color(hex: 0x4A4F9A),
        goalLine: Color.white.opacity(0.26),
        tile: Color.white.opacity(0.07),
        tileStroke: Color.white.opacity(0.08),
        chip: Color(red: 109 / 255, green: 124 / 255, blue: 1).opacity(0.24),
        chipText: Color(hex: 0xB9C0FF),
        shield: Color(hex: 0x3A3470)
    )
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// A horizontal line across the frame.
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

/// The FocusGuard shield, drawn large behind the numbers.
private struct ShieldOutline: Shape {
    func path(in rect: CGRect) -> Path {
        // The icon's shield, in a 46 × 58 box starting at (27, 21).
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - 27) / 46 * rect.width, y: rect.minY + (y - 21) / 58 * rect.height)
        }
        var path = Path()
        path.move(to: p(50, 22))
        path.addLine(to: p(72.3, 31.2))
        path.addLine(to: p(72.3, 47.4))
        path.addCurve(to: p(50, 78), control1: p(72.3, 60.9), control2: p(63.1, 72.8))
        path.addCurve(to: p(27.7, 47.4), control1: p(36.9, 72.8), control2: p(27.7, 60.9))
        path.addLine(to: p(27.7, 31.2))
        path.closeSubpath()
        return path
    }
}
