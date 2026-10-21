import SwiftUI
import AppKit
import ImageIO

/// Loads and caches favicons for hostnames. Used by the distraction list to
/// render real site icons (github.com, youtube.com, etc.) instead of the
/// generic blue tile.
///
/// Icons come from the sites themselves, so no third party learns which
/// sites you visit: `/apple-touch-icon.png` (crisp at tile size), then
/// `/favicon.ico`, then whatever icon the home page links to. Requests carry
/// no cookies. A site without a usable icon keeps the generic tile and isn't
/// asked again until the next launch.
///
/// Cache: in-memory + on-disk under `~/Library/Caches/{bundle}/favicons/`.
@MainActor
final class FaviconLoader: ObservableObject {
    static let shared = FaviconLoader()

    @Published private(set) var images: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    /// Hosts with no icon to be found, this launch.
    private var missing: Set<String> = []

    private lazy var cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Returns a cached image right away if available, or kicks off a fetch
    /// and returns nil. SwiftUI views observe `images` and re-render once it
    /// arrives.
    func image(for host: String) -> NSImage? {
        if let cached = images[host] { return cached }
        if let disk = loadFromDisk(host: host) {
            images[host] = disk
            return disk
        }
        fetchIfNeeded(host: host)
        return nil
    }

    private func fetchIfNeeded(host: String) {
        guard !inFlight.contains(host), !missing.contains(host) else { return }
        inFlight.insert(host)
        Task {
            // Fetch returns Data (Sendable) instead of NSImage so the result
            // can cross actor boundaries cleanly under Swift 6 strict
            // concurrency. We convert to NSImage on the MainActor.
            let data = await Self.fetchData(host: host)
            self.inFlight.remove(host)
            if let data, let img = NSImage(data: data) {
                self.images[host] = img
                self.saveToDisk(host: host, image: img)
            } else {
                self.missing.insert(host)
            }
        }
    }

    // MARK: - Fetching (off-main)

    /// No cookies, no cache shared with anything else, and a short timeout.
    nonisolated private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    nonisolated private static func fetchData(host: String) async -> Data? {
        guard isFetchable(host) else { return nil }
        let origin = "https://\(host)"
        for path in ["/apple-touch-icon.png", "/favicon.ico"] {
            if let url = URL(string: origin + path), let data = await imageData(from: url) {
                return data
            }
        }
        guard let home = URL(string: origin + "/"), let head = await pageHead(from: home) else { return nil }
        for url in iconLinks(in: head, base: home) {
            if let data = await imageData(from: url) { return data }
        }
        return nil
    }

    /// A plain public hostname: letters, digits, dots and dashes, with a dot.
    nonisolated static func isFetchable(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 253 && host.contains(".")
            && !host.hasPrefix(".") && !host.hasSuffix(".")
            && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    /// The body at `url` if it's an image ImageIO can read (not an HTML
    /// error page served with a 200).
    nonisolated private static func imageData(from url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              data.count < 1_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0 else { return nil }
        return data
    }

    /// The start of the home page, enough to hold its `<head>`.
    nonisolated private static func pageHead(from url: URL) async -> String? {
        guard let (bytes, response) = try? await session.bytes(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let headEnd = Data("</head>".utf8)
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 200_000 { break }
                if data.count % 4096 == 0, data.range(of: headEnd) != nil { break }
            }
        } catch {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Icons a page links to, largest kind first: `apple-touch-icon`, then
    /// `icon`. SVG is skipped (ImageIO can't draw it).
    nonisolated static func iconLinks(in html: String, base: URL) -> [URL] {
        guard let tagPattern = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var touch: [URL] = []
        var icons: [URL] = []
        for match in tagPattern.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon"),
                  let href = attribute("href", in: tag), !href.hasPrefix("data:"),
                  !(attribute("type", in: tag)?.lowercased().contains("svg") ?? false),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  url.scheme == "https" || url.scheme == "http",
                  !url.path.lowercased().hasSuffix(".svg") else { continue }
            if rel.contains("apple-touch-icon") { touch.append(url) } else { icons.append(url) }
        }
        return touch + icons
    }

    nonisolated private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: tag) {
                return String(tag[range]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - Disk cache

    private func loadFromDisk(host: String) -> NSImage? {
        let path = cacheDir.appendingPathComponent(diskFilename(host: host))
        guard let data = try? Data(contentsOf: path) else { return nil }
        return NSImage(data: data)
    }

    private func saveToDisk(host: String, image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let path = cacheDir.appendingPathComponent(diskFilename(host: host))
        try? png.write(to: path, options: .atomic)
    }

    private func diskFilename(host: String) -> String {
        let safe = host.replacingOccurrences(of: "/", with: "_")
        return "\(safe).png"
    }
}
