import Foundation

/// What smart categories decided about one app or site.
struct SmartRecord: Codable, Equatable, Identifiable {
    enum Status: String, Codable {
        /// Sure enough: its category was set, with Undo.
        case applied
        /// Not sure: waits for the person, with the guess shown.
        case needsYou
        /// The person picked a category from the suggestion.
        case accepted
        /// The person undid it or turned the guess down; never suggested again.
        case dismissed
    }

    /// The host for a site, the bundle id for an app.
    let key: String
    let name: String
    /// The app, or for a site the browser it was used in.
    let bundleId: String
    let host: String?
    let suggested: Classification
    /// How sure the model was, 0...100.
    let sure: Int
    /// "Open next to Xcode while you code".
    let reason: String
    /// "mostly 10:00 to 12:00", when its use bunches up.
    let hours: String?
    var status: Status
    let decidedAt: Date

    var id: String { key }
    var isSite: Bool { host != nil }
}

/// A YouTube video's verdict, by its id.
struct VideoVerdict: Codable, Equatable, Identifiable {
    let videoId: String
    let title: String
    /// "coding tutorial", "race highlights".
    let kind: String
    var classification: Classification
    /// The person corrected it; it stays as they said.
    var byUser: Bool
    var at: Date

    var id: String { videoId }
}

/// Smart categories' memory: every decision, so nothing is asked twice and
/// the reasons stay on screen. Kept as JSON in UserDefaults (it's small);
/// "Erase everything" clears it.
struct SmartCategoryStore: Codable, Equatable {
    var records: [String: SmartRecord] = [:]
    var videos: [String: VideoVerdict] = [:]
    /// The banner covers decisions after this.
    var bannerClosedAt: Date?

    /// Oldest verdicts go past this many videos.
    static let videoLimit = 300

    static let defaultsKey = "smartCategories.store"

    static func load(from defaults: UserDefaults) -> SmartCategoryStore {
        guard let data = defaults.data(forKey: defaultsKey),
              let store = try? JSONDecoder().decode(SmartCategoryStore.self, from: data) else { return SmartCategoryStore() }
        return store
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    mutating func remember(_ verdict: VideoVerdict) {
        videos[verdict.videoId] = verdict
        guard videos.count > Self.videoLimit else { return }
        let oldest = videos.values.sorted { $0.at < $1.at }.prefix(videos.count - Self.videoLimit)
        for verdict in oldest { videos[verdict.videoId] = nil }
    }

    /// Videos most recent first.
    func recentVideos(limit: Int) -> [VideoVerdict] {
        Array(videos.values.sorted { $0.at > $1.at }.prefix(limit))
    }
}

/// "Sorted 19 of 21 new apps and sites · 2 need you".
struct SmartBanner: Equatable {
    /// Put in place on their own.
    let sorted: Int
    /// Everything decided in the stretch the banner covers.
    let total: Int
    /// Still waiting for the person.
    let needYou: Int

    /// The banner covers the last week, or since it was last closed.
    static let window: TimeInterval = 7 * 86_400

    init(sorted: Int, total: Int, needYou: Int) {
        self.sorted = sorted
        self.total = total
        self.needYou = needYou
    }

    /// Nil when there's nothing to say. `stillOpen` tells whether a
    /// "needs you" record is still unsorted.
    init?(records: [SmartRecord], closedAt: Date?, now: Date, stillOpen: (SmartRecord) -> Bool) {
        let since = max(closedAt ?? .distantPast, now.addingTimeInterval(-Self.window))
        let recent = records.filter { $0.decidedAt > since && $0.status != .dismissed }
        guard !recent.isEmpty else { return nil }
        sorted = recent.filter { $0.status == .applied }.count
        needYou = recent.filter { $0.status == .needsYou && stillOpen($0) }.count
        total = recent.count
        guard sorted + needYou > 0 else { return nil }
    }

    var text: String {
        let things = total == 1 ? "new app or site" : "new apps and sites"
        let head = sorted == total ? "Sorted \(total) \(things)" : "Sorted \(sorted) of \(total) \(things)"
        switch needYou {
        case 0:  return head
        case 1:  return head + " · 1 needs you"
        default: return head + " · \(needYou) need you"
        }
    }
}
