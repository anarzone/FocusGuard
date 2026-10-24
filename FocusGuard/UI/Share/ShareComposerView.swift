import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Share your focus week": a preview of the image on the left, what it
/// shows on the right, and Copy image, Save… and Share…. The image is made
/// on this Mac; nothing leaves it until the user shares it.
struct ShareComposerView: View {
    let week: FocusWeek
    @State private var options = ShareOptions()
    @State private var copied = false
    @State private var anchor = SharingAnchor()

    private let icon = NSApp.applicationIconImage

    var body: some View {
        HStack(spacing: 0) {
            preview
                .frame(width: 500)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(LinearGradient(colors: [Self.previewTop, Self.previewBottom], startPoint: .top, endPoint: .bottom))
            controls
                .padding(.horizontal, 40)
                .padding(.top, 40)
                .padding(.bottom, 28)
        }
        .frame(width: 1000, height: 660)
        .background(Theme.windowBackground)
        .ignoresSafeArea()
    }

    // MARK: - Preview

    private var preview: some View {
        let pixels = options.size.pixels
        let scale: CGFloat = 0.4
        return ShareWeekImage(week: week, options: options, icon: icon)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: pixels.width * scale, height: pixels.height * scale, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color(red: 75 / 255, green: 63 / 255, blue: 217 / 255).opacity(0.18), radius: 22, y: 18)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
            .padding(.top, 58)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview of the image")
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Share your focus week")
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(Theme.primaryText)
            Text("\(week.rangeLabel(wideMonth: true)). The image is made on this Mac, and nothing leaves it until you share it.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            HStack(alignment: .top, spacing: 16) {
                choice("Size", selection: $options.size)
                choice("Look", selection: $options.look)
            }
            .padding(.top, 24)

            Text("Show on the image")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .padding(.top, 22)
            VStack(spacing: 0) {
                toggle("Time per day", detail: nil, isOn: $options.timePerDay)
                Divider().padding(.leading, 14)
                toggle("Session names", detail: "Like Locked-in Deep Dive. They never say what you worked on.",
                       isOn: $options.sessionNames)
                Divider().padding(.leading, 14)
                toggle("Top apps and sites", detail: "Off unless you turn it on. Adds names like Xcode or github.com.",
                       isOn: $options.topPlaces)
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.windowCard))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.separator, lineWidth: 0.5))
            .padding(.top, 8)

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy image", action: copy)
                    .buttonStyle(.capsule(.secondary, height: 36))
                Button("Save…", action: save)
                    .buttonStyle(.capsule(.secondary, height: 36))
                Spacer()
                Button("Share…", action: share)
                    .buttonStyle(.capsule(.primary, height: 36))
                    .background(SharingAnchorView(anchor: anchor))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choice<Value: Hashable & Identifiable & RawRepresentable & CaseIterable>(
        _ title: String, selection: Binding<Value>
    ) -> some View where Value.RawValue == String, Value.AllCases: RandomAccessCollection {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Picker(title, selection: selection) {
                ForEach(Value.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ title: String, detail: String?, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primaryText)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Export

    private var exporter: ShareImageExporter {
        ShareImageExporter(week: week, options: options, icon: icon)
    }

    private func copy() {
        guard exporter.copyToPasteboard() else { return }
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = exporter.fileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? exporter.write(to: url)
    }

    private func share() {
        guard let url = exporter.temporaryFile(), let view = anchor.view else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    // MARK: - Colours

    private static let previewTop = dynamic(light: NSColor(red: 0.965, green: 0.957, blue: 1, alpha: 1),
                                            dark: NSColor(red: 0.16, green: 0.15, blue: 0.24, alpha: 1))
    private static let previewBottom = dynamic(light: NSColor(red: 0.886, green: 0.871, blue: 1, alpha: 1),
                                               dark: NSColor(red: 0.12, green: 0.11, blue: 0.19, alpha: 1))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// Renders the share image and hands it on: the pasteboard, a file, or a
/// temporary file for the share sheet.
@MainActor
struct ShareImageExporter {
    let week: FocusWeek
    let options: ShareOptions
    let icon: NSImage?

    /// "My focus week, 12–18 Oct.png".
    var fileName: String { "My focus week, \(week.rangeLabel()).png" }

    /// The image at exactly 1080 px wide, in plain 8-bit sRGB. Drawn into
    /// an sRGB context: the renderer's own image can come back in an HDR
    /// colour space, which turns the whites grey once converted.
    func render() -> CGImage? {
        let renderer = ImageRenderer(content: ShareWeekImage(week: week, options: options, icon: icon))
        renderer.proposedSize = ProposedViewSize(options.size.pixels)
        let pixels = options.size.pixels
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        renderer.render { _, draw in draw(context) }
        return context.makeImage()
    }

    func pngData() -> Data? {
        guard let image = render() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    func copyToPasteboard() -> Bool {
        guard let data = pngData() else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        return board.setData(data, forType: .png)
    }

    func write(to url: URL) throws {
        guard let data = pngData() else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }

    /// A copy in the temporary folder, for the share sheet; replaced each time.
    func temporaryFile() -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FocusGuard Share", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName)
        return (try? write(to: url)).map { url }
    }
}

/// The Share… button's view, which the share sheet points at.
final class SharingAnchor {
    weak var view: NSView?
}

private struct SharingAnchorView: NSViewRepresentable {
    let anchor: SharingAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
