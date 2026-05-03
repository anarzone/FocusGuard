import SwiftUI
import AppKit

/// Brand-style app icon tile used in the popover Now-card and reports
/// distraction list. Prefers the real macOS app icon when we can resolve
/// the bundle id; falls back to a SwiftUI-drawn tile for known brands or
/// a plain generic tile otherwise.
enum AppGlyphKind: String {
    case shield, focusguard
    case mail, slack, twitter, youtube, reddit, notion, github, safari, chrome
    case figma, xcode, terminal, phpstorm
    case generic
}

/// Resolves a real NSImage for an installed app. Cached so repeated lookups
/// (e.g. one per row of the Apps list, redrawn on every popover tick) stay
/// cheap. Workspace lookup is on-disk so the cache is essential.
enum AppIconLoader {
    private static var cache: [String: NSImage?] = [:]

    static func icon(forBundleId bundleId: String) -> NSImage? {
        if let cached = cache[bundleId] { return cached }
        let ws = NSWorkspace.shared
        let image: NSImage? = {
            guard let url = ws.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
            let img = ws.icon(forFile: url.path)
            // NSWorkspace returns a small placeholder if it doesn't recognize
            // the file — sanity-check that we got a real icon.
            return img.size.width > 0 ? img : nil
        }()
        cache[bundleId] = image
        return image
    }
}

struct AppGlyph: View {
    let kind: AppGlyphKind
    /// When set, we try to render the real macOS icon for this bundle id
    /// before falling back to the SwiftUI-drawn tile.
    var bundleId: String?
    /// When set and bundleId resolution fails, we try a favicon for this host
    /// before falling back to the SwiftUI-drawn tile.
    var host: String?
    var size: CGFloat = 36

    @StateObject private var favicons = FaviconLoader.shared

    private var radius: CGFloat { size <= 24 ? 6 : 8 }

    var body: some View {
        if let bundleId, let nsImage = AppIconLoader.icon(forBundleId: bundleId) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else if let host, let favicon = favicons.image(for: host) {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        } else {
            tile
        }
    }

    private var tile: some View {
        ZStack {
            background
            foreground
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 0.5, y: 0.5)
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .shield, .focusguard:
            LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .mail:
            LinearGradient(colors: [Color(red: 90/255, green: 200/255, blue: 250/255), Color(red: 0/255, green: 122/255, blue: 255/255)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .slack:
            LinearGradient(colors: [Color(red: 74/255, green: 21/255, blue: 75/255), Color(red: 110/255, green: 29/255, blue: 111/255)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .twitter:
            LinearGradient(colors: [Color(white: 0.07), Color(white: 0.20)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .youtube:
            LinearGradient(colors: [Color(red: 255/255, green: 59/255, blue: 48/255), Color(red: 193/255, green: 16/255, blue: 11/255)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .reddit:
            LinearGradient(colors: [Color(red: 255/255, green: 86/255, blue: 0), Color(red: 220/255, green: 60/255, blue: 0)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .notion:
            LinearGradient(colors: [Color(white: 0.97), Color(white: 0.83)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .github:
            LinearGradient(colors: [Color(white: 0.11), Color(white: 0.23)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .safari:
            RadialGradient(colors: [Color(red: 90/255, green: 200/255, blue: 250/255), Color(red: 0/255, green: 122/255, blue: 255/255)], center: .topLeading, startRadius: 0, endRadius: size)
        case .chrome:
            LinearGradient(colors: [Color(red: 232/255, green: 234/255, blue: 237/255), Color(red: 218/255, green: 220/255, blue: 224/255)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .figma:
            // Figma's signature stack of colored rectangles
            VStack(spacing: 0) {
                Color(red: 242/255, green: 78/255, blue: 30/255)
                Color(red: 255/255, green: 114/255, blue: 98/255)
                Color(red: 162/255, green: 89/255, blue: 255/255)
                Color(red: 26/255, green: 188/255, blue: 254/255)
            }
        case .xcode:
            LinearGradient(colors: [Color(red: 26/255, green: 115/255, blue: 232/255), Color(red: 10/255, green: 76/255, blue: 168/255)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .terminal:
            LinearGradient(colors: [Color(white: 0.18), Color.black], startPoint: .top, endPoint: .bottom)
        case .phpstorm:
            LinearGradient(colors: [Color(red: 130/255, green: 41/255, blue: 174/255), Color(red: 232/255, green: 30/255, blue: 99/255)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .generic:
            LinearGradient(colors: [Color(red: 79/255, green: 140/255, blue: 255/255), Color(red: 31/255, green: 84/255, blue: 200/255)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    @ViewBuilder
    private var foreground: some View {
        switch kind {
        case .shield, .focusguard:
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(.white)
        case .mail:
            Image(systemName: "envelope.fill")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        case .slack:
            Text("#")
                .font(.system(size: size * 0.55, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        case .twitter:
            Text("𝕏")
                .font(.system(size: size * 0.55, weight: .bold))
                .foregroundStyle(.white)
        case .youtube:
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.45, weight: .black))
                .foregroundStyle(.white)
        case .reddit:
            Image(systemName: "circle.grid.2x2.fill")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
        case .notion:
            Text("N")
                .font(.system(size: size * 0.55, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
        case .github:
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(.white)
        case .safari:
            Image(systemName: "safari.fill")
                .font(.system(size: size * 0.65, weight: .semibold))
                .foregroundStyle(.white)
        case .chrome:
            Circle()
                .fill(Color.accentColor)
                .frame(width: size * 0.45, height: size * 0.45)
                .overlay(Circle().stroke(Color.white, lineWidth: size * 0.05))
        case .xcode:
            Image(systemName: "hammer.fill")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
        case .terminal:
            Text(">_")
                .font(.system(size: size * 0.4, weight: .heavy, design: .monospaced))
                .foregroundStyle(.green)
        case .phpstorm:
            Text("PS")
                .font(.system(size: size * 0.4, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        case .figma:
            EmptyView()  // gradient bands speak for themselves
        case .generic:
            EmptyView()
        }
    }
}

extension AppGlyph {
    /// Best-effort guess from a bundle id or app name.
    static func kind(forBundleId bundleId: String, name: String? = nil) -> AppGlyphKind {
        let id = bundleId.lowercased()
        let n = (name ?? "").lowercased()
        if id.contains("phpstorm") || n.contains("phpstorm") { return .phpstorm }
        if id.contains("xcode") { return .xcode }
        if id.contains("safari") { return .safari }
        if id.contains("chrome") { return .chrome }
        if id.contains("slack") { return .slack }
        if id.contains("mail") { return .mail }
        if id.contains("notion") { return .notion }
        if id.contains("github") { return .github }
        if id.contains("figma") { return .figma }
        if id.contains("terminal") || id.contains("iterm") { return .terminal }
        if id.contains("twitter") || n.contains("twitter") || n.contains("/x.com") { return .twitter }
        if id.contains("youtube") || n.contains("youtube") { return .youtube }
        if id.contains("reddit") || n.contains("reddit") { return .reddit }
        return .generic
    }
}
