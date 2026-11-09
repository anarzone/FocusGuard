import Foundation

/// The waits that ended, kept on this Mac: how long each tool usually takes,
/// and what the waits turned into, for the card and the Analyzer. A tool's
/// and a project's names, times and the site drifted to; never a title or
/// what was typed. Erased with everything else.
@MainActor
final class WaitLog {
    static let shared = WaitLog()

    static let keptDays = 90
    static let keptRecords = 5_000

    private(set) var records: [WaitRecord] = []
    private let url: URL?
    private let now: () -> Date

    /// - Parameter url: nil keeps it in memory only, as the tests and the UI tests' copy do.
    init(url: URL? = WaitLog.defaultURL, now: @escaping () -> Date = { .now }) {
        self.url = url
        self.now = now
        load()
    }

    nonisolated static var defaultURL: URL? {
        guard !UITestMode.isOn, NSClassFromString("XCTestCase") == nil else { return nil }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/FocusGuard/waits.json")
    }

    func add(_ record: WaitRecord) {
        records.append(record)
        save()
    }

    /// How long this tool usually takes: the median of the waits the user
    /// stayed with (a drift says how long the drift was, not the tool), or
    /// the default until there are enough of them.
    func usualWait(for tool: String) -> TimeInterval {
        // How long the tool said it worked, where it said; else how long the user stayed away.
        let stayed = records.filter { $0.tool == tool && ($0.worked != nil || !$0.drifted) }.map { $0.worked ?? $0.seconds }.sorted()
        guard stayed.count >= WaitRules.enoughWaits else { return WaitRules.usualWait }
        let middle = stayed.count / 2
        let median = stayed.count % 2 == 0 ? (stayed[middle - 1] + stayed[middle]) / 2 : stayed[middle]
        return min(max(median, WaitRules.usualWaitRange.lowerBound), WaitRules.usualWaitRange.upperBound)
    }

    /// The last drifted wait on this tool, for "Last time…" on the card.
    func lastDrift(for tool: String) -> WaitRecord? {
        records.last { $0.tool == tool && $0.drifted }
    }

    /// Of the recent waits on this tool, how many ended on a distraction.
    func driftShare(for tool: String, last count: Int = 5) -> (drifted: Int, of: Int) {
        let recent = records.filter { $0.tool == tool }.suffix(count)
        return (recent.filter(\.drifted).count, recent.count)
    }

    func records(from start: Date, to end: Date) -> [WaitRecord] {
        records.filter { $0.start >= start && $0.start < end }
    }

    func erase() {
        records = []
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Keeping

    private func load() {
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([WaitRecord].self, from: data)) ?? []
        // Waits guessed from a chat or an editor, before only working tools counted.
        let guessed = WaitTools.guessedOnly
        let before = records.count
        records.removeAll { !$0.exact && guessed.contains($0.tool) }
        prune()
        if records.count != before { save() }
    }

    private func save() {
        prune()
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Double(Self.keptDays) * 86_400)
        records.removeAll { $0.start < cutoff }
        if records.count > Self.keptRecords { records.removeFirst(records.count - Self.keptRecords) }
    }
}
