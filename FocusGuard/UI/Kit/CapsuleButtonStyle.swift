import SwiftUI

/// Capsule buttons. Primary is indigo with white text (one per view),
/// secondary is grey. Destructive is red text on a red tint, only for
/// erasing things.
///
///     Button("Start 50 minutes") { … }.buttonStyle(.capsule)
///     Button("Not now") { … }.buttonStyle(.capsule(.secondary, height: 26))
struct CapsuleButtonStyle: ButtonStyle {
    enum Kind {
        case primary, secondary, destructive
    }

    var kind: Kind = .primary
    /// 26 for small inline buttons, 30 by default, 36 for full-width ones.
    var height: CGFloat = 30
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        CapsuleButtonBody(configuration: configuration, kind: kind, height: height, fullWidth: fullWidth)
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    static var capsule: CapsuleButtonStyle { CapsuleButtonStyle() }

    static func capsule(_ kind: CapsuleButtonStyle.Kind, height: CGFloat = 30,
                        fullWidth: Bool = false) -> CapsuleButtonStyle {
        CapsuleButtonStyle(kind: kind, height: height, fullWidth: fullWidth)
    }
}

private struct CapsuleButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: CapsuleButtonStyle.Kind
    let height: CGFloat
    let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: height >= 34 ? 13 : 12, weight: kind == .secondary ? .regular : .semibold))
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, height < 30 ? 12 : 14)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }

    private var fill: Color {
        switch kind {
        case .primary:     return Theme.focusFill
        case .secondary:   return Theme.control
        case .destructive: return Theme.destructiveTint
        }
    }

    private var ink: Color {
        switch kind {
        case .primary:     return .white
        case .secondary:   return Theme.primaryText
        case .destructive: return Theme.destructive
        }
    }
}

/// A plain text link in the link indigo: "Try Pro free for 14 days".
struct TextLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.link)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == TextLinkButtonStyle {
    static var textLink: TextLinkButtonStyle { TextLinkButtonStyle() }
}
