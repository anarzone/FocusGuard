import SwiftUI

// MARK: - Session duration choice

enum SessionDurationChoice: Hashable, CaseIterable {
    case min25, min50, min90, custom

    var minutes: Int? {
        switch self {
        case .min25: return 25
        case .min50: return 50
        case .min90: return 90
        case .custom: return nil
        }
    }
    var shortLabel: String {
        switch self {
        case .min25: return "25m"
        case .min50: return "50m"
        case .min90: return "90m"
        case .custom: return ""
        }
    }
}

// MARK: - NowCard

struct NowCard: View {
    let snapshot: ActivitySnapshot?

    var body: some View {
        HStack(spacing: 10) {
            if let snapshot {
                AppGlyph(
                    kind: AppGlyph.kind(forBundleId: snapshot.bundleIdentifier, name: snapshot.appName),
                    bundleId: snapshot.bundleIdentifier,
                    size: 36
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.appName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle(for: snapshot))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(fullDetail(for: snapshot))
                }
                Spacer()
                ClassificationBadge(classification: snapshot.classification)
            } else {
                AppGlyph(kind: .generic, size: 36)
                Text("Detecting…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill3, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func subtitle(for snapshot: ActivitySnapshot) -> String {
        snapshot.detailLine
    }

    /// Used as the help/tooltip — gives the full URL or title.
    private func fullDetail(for snapshot: ActivitySnapshot) -> String {
        if let url = snapshot.url, !url.isEmpty { return url }
        if let title = snapshot.windowTitle, !title.isEmpty { return title }
        return snapshot.bundleIdentifier
    }
}

extension ActivitySnapshot {
    /// URL host > URL host+path > window title > bundle id.
    /// For browsers, the URL is the most informative thing; the window title
    /// is usually just "Page Title - Chrome" which duplicates the page.
    var detailLine: String {
        if let urlString = url, !urlString.isEmpty {
            if let url = URL(string: urlString), let host = url.host {
                let displayPath = url.path.count > 1 ? url.path : ""
                return host + displayPath
            }
            return urlString
        }
        if let title = windowTitle, !title.isEmpty {
            return title
        }
        return bundleIdentifier
    }
}

// MARK: - ClassificationBadge

struct ClassificationBadge: View {
    let classification: Classification

    var body: some View {
        Text(label)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.3)
            .textCase(.uppercase)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint, in: RoundedRectangle(cornerRadius: 4))
    }

    private var label: String {
        switch classification {
        case .focus:       return "Focus"
        case .neutral:     return "Neutral"
        case .distraction: return "Distraction"
        }
    }

    private var color: Color {
        switch classification {
        case .focus:       return Theme.focus
        case .neutral:     return .secondary
        case .distraction: return Theme.distraction
        }
    }

    private var tint: Color {
        switch classification {
        case .focus:       return Theme.focusTint
        case .neutral:     return Theme.fill1
        case .distraction: return Theme.distractionTint
        }
    }
}

// MARK: - PulsingDot

struct PulsingDot: View {
    let color: Color
    let size: CGFloat
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color, lineWidth: 1.5)
                .opacity(pulse ? 0 : 0.6)
                .scaleEffect(pulse ? 1.6 : 0.8)
                .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
            Circle()
                .fill(color)
                .overlay(Circle().stroke(color.opacity(0.18), lineWidth: 2))
        }
        .frame(width: size, height: size)
        .onAppear { pulse = true }
    }
}
