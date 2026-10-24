import AppKit
import SwiftUI

/// Add the browser extension. Free, and it never starts a trial. The rows
/// at the bottom turn to "Connected" as soon as a browser's extension
/// says hello to the app.
struct ExtensionSheet: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// Chromium browsers the extension runs in, by bundle id.
    static let browsers: [(name: String, bundleId: String)] = [
        ("Chrome", "com.google.Chrome"),
        ("Arc", "company.thebrowser.Browser"),
        ("Brave", "com.brave.Browser"),
        ("Edge", "com.microsoft.edgemac"),
    ]

    /// The Chrome Web Store listing, once there is one.
    static var storeURL: URL? {
        BrowserExtensionIDs.store.flatMap { URL(string: "https://chromewebstore.google.com/detail/\($0)") }
    }

    /// How to add it by hand until the listing exists.
    static let guideURL = URL(string: "https://github.com/anarzone/FocusGuard/tree/main/extension/chrome#try-it")!

    private var installed: [(name: String, bundleId: String)] {
        let found = Self.browsers.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) != nil }
        return found.isEmpty ? [Self.browsers[0]] : found
    }

    private var first: String { installed.first?.name ?? "Chrome" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            steps
            browserRows
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield").foregroundStyle(Theme.focus)
                Text("\(first) will say the extension can “read your browsing history”. It only checks each address against your rules, on this Mac, and never reads what's on the page.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.bodyText)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.focus.opacity(0.07)))

            HStack {
                Button("Having trouble?") { NSWorkspace.shared.open(Self.guideURL) }.buttonStyle(.textLink)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.capsule(.secondary, height: 32))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(EdgeInsets(top: 24, leading: 28, bottom: 22, trailing: 28))
        .frame(width: 560)
        .background(Theme.windowBackground)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 17))
                .foregroundStyle(Theme.focus)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.focusTint))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Add FocusGuard to \(first)")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    FreeBadge()
                }
                Text("Free to add, and it never starts a trial. It makes tracking sharper and pauses tabs straight away. With Pro, pages never load and you can block parts of sites. One extension covers Chrome, Arc, Brave and Edge.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var steps: some View {
        VStack(spacing: 10) {
            step(1, title: Self.storeURL == nil ? "Load the extension in \(first)" : "Open the extension's page in \(first)",
                 detail: Self.storeURL == nil ? "Not in the Chrome Web Store yet; the guide shows how" : "On the Chrome Web Store",
                 current: true) {
                Button(Self.storeURL == nil ? "Open the guide" : "Open in \(first)") { openFirstStep() }
                    .buttonStyle(.capsule(.primary, height: 28))
            }
            step(2, title: Self.storeURL == nil ? "Turn on Developer mode, then Load unpacked" : "Click Add to \(first), then Add extension",
                 detail: "\(first) lists what it can see; the box below explains it", current: false) { EmptyView() }
            step(3, title: "Come back here", detail: "FocusGuard notices the extension by itself", current: false) { EmptyView() }
        }
    }

    private func step<Trailing: View>(_ n: Int, title: String, detail: String, current: Bool,
                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return HStack(spacing: 12) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(current ? .white : Theme.secondaryText)
                .frame(width: 22, height: 22)
                .background(Circle().fill(current ? Theme.focusFill : .clear))
                .overlay(Circle().strokeBorder(current ? .clear : Theme.lockedStroke, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: current ? .semibold : .regular)).foregroundStyle(Theme.primaryText)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(shape.fill(current ? Theme.windowCard : Theme.windowCard.opacity(0.6)))
        .overlay(shape.strokeBorder(Theme.moduleStroke, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    private var browserRows: some View {
        let connected = appState.extensionBridge.connectedBrowsers
        return VStack(spacing: 0) {
            ForEach(Array(installed.enumerated()), id: \.element.bundleId) { index, browser in
                HStack(spacing: 10) {
                    AppGlyph(kind: .generic, bundleId: browser.bundleId, size: 18).accessibilityHidden(true)
                    Text(browser.name).font(.system(size: 12)).foregroundStyle(Theme.primaryText)
                    Spacer(minLength: 8)
                    if connected.contains(browser.bundleId) {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.bodyText)
                    } else if index == 0 {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Waiting for the extension")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.bodyText)
                    } else {
                        Text("Add it in \(browser.name) too, same steps")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .overlay(alignment: .top) {
                    if index > 0 { Rectangle().fill(Theme.moduleStroke).frame(height: 0.5) }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.inset))
    }

    private func openFirstStep() {
        guard let store = Self.storeURL else {
            NSWorkspace.shared.open(Self.guideURL)
            return
        }
        let chromeLike = installed.first.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) }
        if let app = chromeLike {
            NSWorkspace.shared.open([store], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(store)
        }
    }
}
