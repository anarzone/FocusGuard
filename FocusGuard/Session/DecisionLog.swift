import Foundation
import os

/// What FocusGuard decided and what the user did about it, kept on this Mac so
/// the rules can be judged by how they do: suggestions picked or passed over,
/// goals done, cards answered, blocks gone back from. Kinds and outcomes only,
/// never a goal, a title or a site. Erased with everything else.
@MainActor
final class DecisionLog {
    static let shared = DecisionLog()

    enum Kind: String, Codable, CaseIterable {
        /// A session started: with no goal, a typed one, or a suggestion.
        case goal
        /// The user said how a goal went.
        case verdict
        /// A card on the island: shown, pressed, closed.
        case island
        /// The Mac's block screen: shown, and what was pressed.
        case block
        /// The browser's block page: shown, and what was pressed.
        case browserBlock
        /// A wait on a tool: reached for a distraction in it, and how it ended.
        case wait
        /// The Analyzer: a moment ruled out as not a distraction, or put back.
        case analyzer
    }

    struct Entry: Codable, Equatable {
        let at: Date
        let kind: Kind
        let outcome: String
        /// A suggestion's kind and place, a card's kind: never content.
        var detail: String?
        var session: UUID?
    }

    /// How long the tracker's look at the front app took, per day.
    struct Timing: Codable, Equatable {
        var count = 0
        var total: TimeInterval = 0
        var longest: TimeInterval = 0

        var average: TimeInterval { count > 0 ? total / Double(count) : 0 }
    }

    /// Entries older than this go.
    static let keptDays = 90
    static let keptEntries = 5_000

    private(set) var entries: [Entry] = []
    private(set) var timings: [String: Timing] = [:]
    private let url: URL?
    /// Kept in a file: the real app's log, not a test's.
    var isKept: Bool { url != nil }
    private var dirty = false
    private var lastSaved = Date.distantPast
    private let now: () -> Date

    /// What was offered under the goal field when the session started, and
    /// what was picked, until the session takes them.
    private var offered: [String] = []
    private var picked: (kind: String, position: Int, text: String)?

    static let signposter = OSSignposter(subsystem: "com.anar.focusguard", category: "tracking")

    /// - Parameter url: nil keeps it in memory only, as the UI tests' copy does.
    init(url: URL? = DecisionLog.defaultURL, now: @escaping () -> Date = { .now }) {
        self.url = url
        self.now = now
        load()
    }

    nonisolated static var defaultURL: URL? {
        // The UI tests' copy and the unit tests keep it in memory: neither
        // should add to the real log.
        guard !UITestMode.isOn, NSClassFromString("XCTestCase") == nil else { return nil }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/FocusGuard/decisions.json")
    }

    // MARK: - Recording

    func record(_ kind: Kind, _ outcome: String, detail: String? = nil, session: UUID? = nil) {
        entries.append(Entry(at: now(), kind: kind, outcome: outcome, detail: detail, session: session))
        dirty = true
        saveSoon()
    }

    /// The suggestions under the goal field as a session is started from the menu.
    func noteOffered(_ kinds: [String]) { offered = kinds }

    /// One was picked: its kind and place, kept to tell a picked goal from a typed one.
    func notePicked(kind: String, position: Int, text: String) { picked = (kind, position, text) }

    /// A session took its goal: `goal` is what it ended up with.
    func sessionStarted(_ session: UUID, goal: String?) {
        let shown = offered.isEmpty ? "none" : offered.joined(separator: ",")
        let outcome: String
        var detail = "offered:\(shown)"
        if let goal, !goal.isEmpty {
            if let picked, picked.text == goal {
                outcome = "suggestion"
                detail += " picked:\(picked.kind)#\(picked.position + 1)"
            } else {
                outcome = "typed"
            }
        } else {
            outcome = "none"
        }
        record(.goal, outcome, detail: detail, session: session)
        offered = []
        picked = nil
    }

    func noteTick(_ duration: TimeInterval) {
        let day = Self.dayKey(now())
        var timing = timings[day] ?? Timing()
        timing.count += 1
        timing.total += duration
        timing.longest = max(timing.longest, duration)
        timings[day] = timing
        dirty = true
        saveSoon()
    }

    func erase() {
        entries = []
        timings = [:]
        offered = []
        picked = nil
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Reading

    /// What the last `days` add up to, for Settings and the diagnostics report.
    func summary(days: Int = 7, calendar: Calendar = .current) -> DecisionSummary {
        let since = calendar.date(byAdding: .day, value: -days, to: now()) ?? .distantPast
        let recent = entries.filter { $0.at >= since }
        let dayKeys = Set((0..<days).compactMap { calendar.date(byAdding: .day, value: -$0, to: now()).map { Self.dayKey($0) } })
        let timing = timings.filter { dayKeys.contains($0.key) }.values.reduce(into: Timing()) { sum, day in
            sum.count += day.count
            sum.total += day.total
            sum.longest = max(sum.longest, day.longest)
        }
        return DecisionSummary(entries: recent, timing: timing)
    }

    func exportData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(Stored(entries: entries, timings: timings))) ?? Data()
    }

    // MARK: - Keeping

    private struct Stored: Codable {
        var entries: [Entry]
        var timings: [String: Timing]
    }

    private func load() {
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(Stored.self, from: data) else { return }
        entries = stored.entries
        timings = stored.timings
        prune()
    }

    /// At most every few minutes: the tracker notes a timing every second.
    private func saveSoon() {
        guard now().timeIntervalSince(lastSaved) >= 300 else { return }
        save()
    }

    func save() {
        guard dirty, let url else { return }
        prune()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Stored(entries: entries, timings: timings)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        dirty = false
        lastSaved = now()
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Double(Self.keptDays) * 86_400)
        entries.removeAll { $0.at < cutoff }
        if entries.count > Self.keptEntries { entries.removeFirst(entries.count - Self.keptEntries) }
        let oldest = Self.dayKey(cutoff)
        timings = timings.filter { $0.key >= oldest }
    }

    nonisolated static func dayKey(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// The log, added up.
struct DecisionSummary: Equatable {
    let sessions: Int
    let withGoal: Int
    let fromSuggestion: Int
    /// Sessions started from the menu with suggestions under the field.
    let offeredSuggestions: Int
    let verdicts: Int
    let done: Int
    /// Done among goals that came from a suggestion.
    let doneFromSuggestion: Int
    let verdictsFromSuggestion: Int
    let cardsShown: Int
    let cardsAnswered: Int
    let blocksShown: Int
    let backToWork: Int
    let letThrough: Int
    let timing: DecisionLog.Timing

    init(entries: [DecisionLog.Entry], timing: DecisionLog.Timing) {
        let goals = entries.filter { $0.kind == .goal }
        sessions = goals.count
        withGoal = goals.filter { $0.outcome != "none" }.count
        fromSuggestion = goals.filter { $0.outcome == "suggestion" }.count
        offeredSuggestions = goals.filter { !($0.detail ?? "").hasPrefix("offered:none") }.count
        let suggested = Set(goals.filter { $0.outcome == "suggestion" }.compactMap(\.session))
        // The last word on each session's goal counts.
        var last: [UUID: String] = [:]
        for entry in entries where entry.kind == .verdict {
            if let session = entry.session { last[session] = entry.outcome }
        }
        verdicts = last.count
        done = last.values.filter { $0 == GoalVerdict.done.rawValue }.count
        verdictsFromSuggestion = last.keys.filter { suggested.contains($0) }.count
        doneFromSuggestion = last.filter { suggested.contains($0.key) && $0.value == GoalVerdict.done.rawValue }.count
        let cards = entries.filter { $0.kind == .island }
        cardsShown = cards.filter { $0.outcome == "shown" }.count
        cardsAnswered = cards.filter { $0.outcome == "pressed" }.count
        let blocks = entries.filter { $0.kind == .block || $0.kind == .browserBlock }
        blocksShown = blocks.filter { $0.outcome == "shown" }.count
        backToWork = blocks.filter { $0.outcome == "backToWork" }.count
        letThrough = blocks.filter { $0.outcome == "letThrough" || $0.outcome == "forWork" }.count
        self.timing = timing
    }

    /// For the diagnostics report: numbers only, in English like the rest of it.
    var rows: [(String, String)] {
        [("Sessions", "\(sessions), \(withGoal) with a goal"),
         ("Goal from a suggestion", "\(fromSuggestion) of \(offeredSuggestions) offered"),
         ("Goals done", "\(done) of \(verdicts) judged; from a suggestion \(doneFromSuggestion) of \(verdictsFromSuggestion)"),
         ("Island cards answered", "\(cardsAnswered) of \(cardsShown)"),
         ("Blocks", "\(blocksShown) shown, \(backToWork) back to work, \(letThrough) let through or for work"),
         ("Tracking check", String(format: "%.2f ms average, %.1f ms longest, %d checks", timing.average * 1000, timing.longest * 1000, timing.count))]
    }
}
