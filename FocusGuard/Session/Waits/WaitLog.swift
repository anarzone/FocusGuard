import Foundation

/// What's known of how much longer a tool's run has to go.
enum WaitEstimate: Equatable {
    /// Too few runs of its own to say.
    case unknown
    /// Its runs that got this far usually went on this much longer.
    case left(TimeInterval)
    /// It has worked longer than most of its runs did.
    case overdue(worked: TimeInterval)
}

/// The waits that ended and the runs each tool timed itself, kept on this
/// Mac: how long each tool takes on each project, and what the waits turned
/// into, for the card and the Analyzer. A tool's and a project's names,
/// times and the site drifted to; never a title or what was typed. Erased
/// with everything else.
@MainActor
final class WaitLog {
    static let shared = WaitLog()

    static let keptDays = 90
    static let keptRecords = 5_000

    private(set) var records: [WaitRecord] = []
    /// Every run a tool started and finished by its own word, waited on or not.
    private(set) var runs: [RunRecord] = []
    private let url: URL?
    private let runsURL: URL?
    private let now: () -> Date

    /// - Parameter url: nil keeps it in memory only, as the tests and the UI tests' copy do.
    init(url: URL? = WaitLog.defaultURL, now: @escaping () -> Date = { .now }) {
        self.url = url
        self.runsURL = url.map(Self.runsURL(beside:))
        self.now = now
        load()
    }

    /// The runs' file, beside the waits': "waits.json" has "runs.json".
    nonisolated static func runsURL(beside url: URL) -> URL {
        let name = url.lastPathComponent
        let runs = name.hasPrefix("waits") ? "runs" + name.dropFirst(5) : "runs-" + name
        return url.deletingLastPathComponent().appendingPathComponent(runs)
    }

    nonisolated static var defaultURL: URL? {
        guard !UITestMode.isOn, NSClassFromString("XCTestCase") == nil else { return nil }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/FocusGuard/waits.json")
    }

    func add(_ record: WaitRecord) {
        records.append(record)
        save()
    }

    func add(_ run: RunRecord) {
        runs.append(run)
        saveRuns()
    }

    /// How long this tool usually takes, for a tool that doesn't say when it
    /// starts: the median of the waits the user stayed with (a drift says
    /// how long the drift was, not the tool). Nil until there are enough.
    func usualWait(for tool: String) -> TimeInterval? {
        // How long the tool said it worked, where it said; else how long the user stayed away.
        let stayed = records.filter { $0.tool == tool && ($0.worked != nil || !$0.drifted) }.map { $0.worked ?? $0.seconds }.sorted()
        guard stayed.count >= WaitRules.enoughWaits else { return nil }
        return min(max(Self.median(stayed), WaitRules.usualWaitRange.lowerBound), WaitRules.usualWaitRange.upperBound)
    }

    /// The run times to go by: the project's own once it has enough, else
    /// the tool's on every project. The latest ones only.
    func runTimes(tool: String, project: String?) -> [TimeInterval] {
        let ofTool = runs.filter { $0.tool == tool }
        if let project {
            let own = ofTool.filter { $0.project == project }
            if own.count >= WaitRules.enoughRuns { return own.suffix(WaitRules.recentRuns).map(\.seconds) }
        }
        return ofTool.suffix(WaitRules.recentRuns).map(\.seconds)
    }

    /// How much longer a run that has worked for `elapsed` has to go, going
    /// by the tool's own past runs that got this far.
    func estimate(tool: String, project: String?, elapsed: TimeInterval) -> WaitEstimate {
        let times = runTimes(tool: tool, project: project)
        guard times.count >= WaitRules.enoughRuns else { return .unknown }
        let left = times.filter { $0 > elapsed }.map { $0 - elapsed }.sorted()
        let over = Double(times.count - left.count) / Double(times.count)
        guard !left.isEmpty, over < WaitRules.longRunShare else { return .overdue(worked: elapsed) }
        return .left(Self.median(left))
    }

    /// The longest of the tool's recent runs here: how long a start with no
    /// finish can still be believed.
    func longestRun(tool: String, project: String?) -> TimeInterval? {
        runTimes(tool: tool, project: project).max()
    }

    private static func median(_ sorted: [TimeInterval]) -> TimeInterval {
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
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
        runs = []
        if let url { try? FileManager.default.removeItem(at: url) }
        if let runsURL { try? FileManager.default.removeItem(at: runsURL) }
    }

    // MARK: - Keeping

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let runsURL, let data = try? Data(contentsOf: runsURL) {
            runs = (try? decoder.decode([RunRecord].self, from: data)) ?? []
        }
        guard let url, let data = try? Data(contentsOf: url) else { return }
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
        write(records, to: url)
    }

    private func saveRuns() {
        prune()
        write(runs, to: runsURL)
    }

    private func write<Kept: Encodable>(_ kept: [Kept], to url: URL?) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(kept) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Double(Self.keptDays) * 86_400)
        records.removeAll { $0.start < cutoff }
        if records.count > Self.keptRecords { records.removeFirst(records.count - Self.keptRecords) }
        runs.removeAll { $0.start < cutoff }
        if runs.count > Self.keptRecords { runs.removeFirst(runs.count - Self.keptRecords) }
    }
}
