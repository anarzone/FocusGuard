import SwiftUI

/// Color + spacing + radius tokens drawn from the FocusGuard design pack.
/// Colors mirror the CSS custom properties — light values match
/// `:root`, dark values match `[data-scheme="dark"]`. We use NSColor's
/// dynamic provider so each token resolves correctly per appearance.
enum Theme {
    // MARK: - Classifications

    // Focus is indigo (close to macOS Focus), drift is orange. The pair was
    // checked for colour-vision deficiency in both modes; green/red failed.
    // Orange is weak on light surfaces, so it always ships with a label.
    static let focus = dynamicColor(
        light: Color(red: 97/255, green: 85/255, blue: 245/255),     // #6155F5
        dark:  Color(red: 109/255, green: 124/255, blue: 255/255)    // #6D7CFF
    )
    /// Fill for controls with white labels (prominent buttons, selected
    /// pills). Dark mode's `focus` is too light for white text (3.5:1);
    /// this keeps it at least 5:1 in both modes.
    static let focusFill = dynamicColor(
        light: Color(red: 97/255, green: 85/255, blue: 245/255),     // #6155F5, 5.1:1
        dark:  Color(red: 94/255, green: 92/255, blue: 230/255)      // #5E5CE6, 5.1:1
    )
    static let neutral = dynamicColor(
        light: Color(red: 142/255, green: 142/255, blue: 147/255),   // #8E8E93
        dark:  Color(red: 152/255, green: 152/255, blue: 157/255)    // #98989D
    )
    static let distraction = dynamicColor(
        light: Color(red: 255/255, green: 141/255, blue: 40/255),    // #FF8D28
        dark:  Color(red: 220/255, green: 118/255, blue: 32/255)     // #DC7620
    )
    /// Orange dark enough for glyphs and small marks on light glass.
    static let distractionInk = dynamicColor(
        light: Color(red: 224/255, green: 115/255, blue: 22/255),    // #E07316
        dark:  Color(red: 255/255, green: 146/255, blue: 48/255)     // #FF9230
    )
    static let warning = Color(red: 255/255, green: 159/255, blue: 10/255)  // #FF9F0A

    // MARK: - Tints (16-22% alpha of the base)

    static let focusTint = dynamicColor(
        light: Color(red: 97/255, green: 85/255, blue: 245/255).opacity(0.14),
        dark:  Color(red: 109/255, green: 124/255, blue: 255/255).opacity(0.22)
    )
    static let neutralTint = dynamicColor(
        light: Color(red: 142/255, green: 142/255, blue: 147/255).opacity(0.18),
        dark:  Color(red: 152/255, green: 152/255, blue: 157/255).opacity(0.22)
    )
    static let distractionTint = dynamicColor(
        light: Color(red: 255/255, green: 141/255, blue: 40/255).opacity(0.14),
        dark:  Color(red: 220/255, green: 118/255, blue: 32/255).opacity(0.22)
    )

    // MARK: - Menu glass

    /// "Other" minutes in the session grid — monochrome, never a hue.
    static let other = dynamicColor(
        light: Color.black.opacity(0.24),
        dark:  Color.white.opacity(0.34)
    )
    /// Rounded module sitting on the menu's glass.
    static let module = dynamicColor(
        light: Color.white.opacity(0.58),
        dark:  Color.white.opacity(0.07)
    )
    static let moduleStroke = dynamicColor(
        light: Color.black.opacity(0.06),
        dark:  Color.white.opacity(0.08)
    )
    /// Circular control platters and secondary capsules.
    static let control = dynamicColor(
        light: Color.black.opacity(0.07),
        dark:  Color.white.opacity(0.12)
    )
    // MARK: - Window

    /// Main window backdrop behind the floating sidebar and cards.
    static let windowBackground = dynamicColor(
        light: Color(red: 245/255, green: 245/255, blue: 248/255),   // #F5F5F8
        dark:  Color(red: 28/255, green: 28/255, blue: 33/255)       // #1C1C21
    )
    /// Content cards in the main window.
    static let windowCard = dynamicColor(
        light: Color.white,
        dark:  Color(red: 38/255, green: 38/255, blue: 44/255)       // #26262C
    )

    /// Outline of a minute that hasn't happened yet.
    static let gridFuture = dynamicColor(
        light: Color.black.opacity(0.13),
        dark:  Color.white.opacity(0.16)
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
