import Foundation

/// What the user has said about projects: whose they are, how hours round up
/// for clients, and where time without a goal belongs. A fix made once stays.
struct WeekProjectSettings: Codable, Equatable {
    /// Client by project.
    var clients: [String: String] = [:]
    /// Client reports round up to this many minutes; 0 doesn't round.
    var roundUp = 15
    /// Project by app or site, lowercased, for time without a goal or project.
    var moved: [String: String] = [:]
    /// Apps and sites, lowercased, not to ask about again.
    var ignored: [String] = []

    /// The clients named so far, in order.
    var clientNames: [String] { Array(Set(clients.values)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }

    static let roundings = [0, 6, 15]
}

struct WeekProjectStore {
    static let key = "yourWeek.projects"
    var defaults: UserDefaults = UITestMode.defaults

    func load() -> WeekProjectSettings {
        guard let data = defaults.data(forKey: Self.key) else { return WeekProjectSettings() }
        return (try? JSONDecoder().decode(WeekProjectSettings.self, from: data)) ?? WeekProjectSettings()
    }

    func save(_ settings: WeekProjectSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
    }

    func erase() { defaults.removeObject(forKey: Self.key) }
}

/// What a client gets: their projects, the work finished and the hours. Sites,
/// window titles, drift, focus rates and other clients never reach it, because
/// it's built from nothing else.
struct ClientReport: Equatable {
    struct Row: Equatable, Identifiable {
        let project: String
        /// Rounded up as set.
        let seconds: TimeInterval
        /// Goals done this week.
        let finished: [String]
        var id: String { project }
    }

    let client: String
    let interval: DateInterval
    let rows: [Row]

    var total: TimeInterval { rows.reduce(0) { $0 + $1.seconds } }

    /// Up to the next `minutes`. Half a minute over doesn't count: tracked
    /// time carries stray seconds, and 6h 00m 20s shouldn't bill as 6h 15m.
    static func roundedUp(_ seconds: TimeInterval, minutes: Int) -> TimeInterval {
        guard minutes > 0 else { return seconds }
        let step = TimeInterval(minutes * 60)
        return (max(0, seconds - 30) / step).rounded(.up) * step
    }

    static func make(client: String, model: WorkLogModel, settings: WeekProjectSettings) -> ClientReport {
        let entries = model.entries
        let rows = model.projects.compactMap { project -> Row? in
            guard let name = project.name, settings.clients[name] == client else { return nil }
            var seen = Set<String>()
            let finished = entries
                .filter { $0.project == name && $0.hasGoal && $0.state == .verdict(.done) }
                .sorted { $0.start < $1.start }
                .map(\.title)
                .filter { seen.insert($0.lowercased()).inserted }
            return Row(project: name, seconds: roundedUp(project.seconds, minutes: settings.roundUp), finished: finished)
        }
        return ClientReport(client: client, interval: model.interval, rows: rows)
    }
}
