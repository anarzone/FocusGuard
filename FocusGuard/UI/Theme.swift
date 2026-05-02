import SwiftUI

/// Color + spacing + radius tokens drawn from the FocusGuard design pack.
/// Colors mirror the CSS custom properties — light values match
/// `:root`, dark values match `[data-scheme="dark"]`. We use NSColor's
/// dynamic provider so each token resolves correctly per appearance.
enum Theme {
    // MARK: - Classifications

    static let focus = dynamicColor(
        light: Color(red: 52/255, green: 199/255, blue: 89/255),     // #34C759
        dark:  Color(red: 48/255, green: 209/255, blue: 88/255)      // #30D158
    )
    static let neutral = dynamicColor(
        light: Color(red: 142/255, green: 142/255, blue: 147/255),   // #8E8E93
        dark:  Color(red: 152/255, green: 152/255, blue: 157/255)    // #98989D
    )
    static let distraction = dynamicColor(
        light: Color(red: 255/255, green: 69/255, blue: 58/255),     // #FF453A
        dark:  Color(red: 255/255, green: 105/255, blue: 97/255)     // #FF6961
    )
    static let warning = Color(red: 255/255, green: 159/255, blue: 10/255)  // #FF9F0A

    // MARK: - Tints (16-22% alpha of the base)

    static let focusTint = dynamicColor(
        light: Color(red: 52/255, green: 199/255, blue: 89/255).opacity(0.16),
        dark:  Color(red: 48/255, green: 209/255, blue: 88/255).opacity(0.22)
    )
    static let neutralTint = dynamicColor(
        light: Color(red: 142/255, green: 142/255, blue: 147/255).opacity(0.18),
        dark:  Color(red: 152/255, green: 152/255, blue: 157/255).opacity(0.22)
    )
    static let distractionTint = dynamicColor(
        light: Color(red: 255/255, green: 69/255, blue: 58/255).opacity(0.16),
        dark:  Color(red: 255/255, green: 105/255, blue: 97/255).opacity(0.22)
    )

    // MARK: - Fills (gray-on-gray subtle backgrounds)

    static let fill1 = dynamicColor(
        light: Color(red: 120/255, green: 120/255, blue: 128/255).opacity(0.12),
        dark:  Color(red: 120/255, green: 120/255, blue: 128/255).opacity(0.24)
    )
    static let fill2 = dynamicColor(
        light: Color(red: 120/255, green: 120/255, blue: 128/255).opacity(0.16),
        dark:  Color(red: 120/255, green: 120/255, blue: 128/255).opacity(0.36)
    )
    static let fill3 = dynamicColor(
        light: Color(red: 120/255, green: 120/255, blue: 128/255).opacity(0.08),
        dark:  Color(red: 120/255, green: 120/255, blue: 128/255).opacity(0.16)
    )

    // MARK: - Separators / cards

    static let separator = dynamicColor(
        light: Color(red: 60/255, green: 60/255, blue: 67/255).opacity(0.18),
        dark:  Color(white: 1).opacity(0.10)
    )
    static let cardBackground = dynamicColor(
        light: Color.white.opacity(0.65),
        dark:  Color(red: 118/255, green: 118/255, blue: 128/255).opacity(0.18)
    )

    // MARK: - Radii

    enum Radius {
        static let chip: CGFloat = 8
        static let card: CGFloat = 12
        static let surface: CGFloat = 16
    }

    // MARK: - Helpers

    private static let darkAppearanceNames: Set<NSAppearance.Name> = [
        .darkAqua,
        .vibrantDark,
        .accessibilityHighContrastDarkAqua,
        .accessibilityHighContrastVibrantDark,
    ]

    private static func dynamicColor(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            darkAppearanceNames.contains(appearance.name) ? NSColor(dark) : NSColor(light)
        })
    }
}
