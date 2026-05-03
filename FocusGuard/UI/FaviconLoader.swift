import SwiftUI
import AppKit

/// Loads and caches favicons for hostnames. Used by the distraction list to
/// render real site icons (github.com, youtube.com, etc.) instead of the
/// generic blue tile.
///
/// Resolution strategy: try `https://{host}/favicon.ico` first, fall back to
/// Google's S2 favicon service if that fails (or is too small) — the S2
/// service produces a clean PNG for any host.
///
/// Cache: in-memory + on-disk under `~/Library/Caches/{bundle}/favicons/`.
@MainActor
final class FaviconLoader: ObservableObject {
    static let shared = FaviconLoader()

    @Published private(set) var images: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

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
        guard !inFlight.contains(host) else { return }
        inFlight.insert(host)
        Task {
            let img = await Self.fetch(host: host)
            await MainActor.run {
                self.inFlight.remove(host)
                if let img {
                    self.images[host] = img
                    self.saveToDisk(host: host, image: img)
                }
            }
        }
    }

    nonisolated private static func fetch(host: String) async -> NSImage? {
        // Google S2 — most reliable, returns 32px PNG for any host.
        let urlString = "https://www.google.com/s2/favicons?sz=64&domain=\(host)"
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return NSImage(data: data)
        } catch {
            return nil
        }
    }

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
