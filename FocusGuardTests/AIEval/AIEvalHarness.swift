import Foundation
import SwiftData
import XCTest
@testable import FocusGuard

// The parts the AI evaluation (AIEvalTests) stands on: a model that records
// every call, seeded scenarios, a ground truth that doesn't use the code under
// test, and a checker for numbers and names in generated text.

/// Where results go, and whether to run at all. CI has no Apple Intelligence
/// and never sets `AI_EVAL`: run with `TEST_RUNNER_AI_EVAL=1 xcodebuild test`.
enum EvalEnv {
    static var isOn: Bool { ProcessInfo.processInfo.environment["AI_EVAL"] == "1" }
    static var runs: Int { Int(ProcessInfo.processInfo.environment["AI_EVAL_RUNS"] ?? "") ?? 5 }
    static var outDir: URL {
        let path = ProcessInfo.processInfo.environment["AI_EVAL_OUT"] ?? (NSTemporaryDirectory() + "ai-eval")
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// One JSON object per line.
final class EvalLog: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    let url: URL

    init(_ name: String) throws {
        url = EvalEnv.outDir.appendingPathComponent(name + ".jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        lock.lock()
        handle.write(data)
        handle.write(Data("\n".utf8))
        lock.unlock()
    }

    deinit { try? handle.close() }
}

struct EvalTimeout: Error {}

/// One call as the model saw it.
struct EvalCall {
    let instructions: String
    let prompt: String
    let raw: String?
    let error: String?
    let ms: Int

    var json: [String: Any] {
        var out: [String: Any] = ["prompt": prompt, "instructions": instructions, "ms": ms]
        if let raw { out["raw"] = raw }
        if let error { out["error"] = error }
        return out
    }
}

/// The real model, recorded call by call, with a watchdog.
final class RecordingModel: OnDeviceModel, @unchecked Sendable {
    private let base: any OnDeviceModel
    private let lock = NSLock()
    private var calls: [EvalCall] = []
    let timeout: TimeInterval

    init(base: any OnDeviceModel, timeout: TimeInterval = 90) {
        self.base = base
        self.timeout = timeout
    }

    func take() -> [EvalCall] {
        lock.lock()
        defer { lock.unlock() }
        let out = calls
        calls = []
        return out
    }

    private func note(_ call: EvalCall) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    func respond(instructions: String, prompt: String, shape: AnswerShape) async throws -> String {
        let started = Date()
        let base = self.base, limit = timeout
        func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        do {
            let out = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await base.respond(instructions: instructions, prompt: prompt, shape: shape) }
                group.addTask {
                    try await Task.sleep(for: .seconds(limit))
                    throw EvalTimeout()
                }
                let first = try await group.next() ?? ""
                group.cancelAll()
                return first
            }
            note(EvalCall(instructions: instructions, prompt: prompt, raw: out, error: nil, ms: elapsed()))
            return out
        } catch {
            note(EvalCall(instructions: instructions, prompt: prompt, raw: nil, error: String(describing: error), ms: elapsed()))
            throw error
        }
    }
}

// MARK: - Scenarios

struct EvalApp: Equatable {
    let bundle: String
    let name: String
    let host: String?

    static func app(_ name: String, _ bundle: String) -> EvalApp { EvalApp(bundle: bundle, name: name, host: nil) }
    static func site(_ host: String) -> EvalApp { EvalApp(bundle: "com.google.Chrome", name: "Google Chrome", host: host) }

    static let xcode = app("Xcode", "com.apple.dt.Xcode")
    static let terminal = app("Terminal", "com.apple.Terminal")
    static let slack = app("Slack", "com.tinyspeck.slackmacgap")
    static let zoom = app("zoom.us", "us.zoom.xos")
    static let steam = app("Steam", "com.valvesoftware.steam")
    static let youtube = site("youtube.com")
    static let reddit = site("reddit.com")
    static let x = site("x.com")

    /// What Ask and the coach call it.
    var shown: String { host ?? name }
}

struct EvalBlock {
    let start: Date
    let end: Date
    let kind: Classification
    let app: EvalApp
    let session: Int?

    var minutes: Double { end.timeIntervalSince(start) / 60 }
}

struct EvalSessionSeed {
    let start: Date
    var end: Date?
    var planned: Int?
    var goal: String?
}

/// A seeded history. Days are counted from `anchor`'s start, so one history
/// can be looked at from different moments: anything after `now` is left out.
struct EvalScenario {
    let name: String
    var calendar: Calendar
    var locale: Locale
    let anchor: Date
    var now: Date
    var blocks: [EvalBlock] = []
    var sessions: [EvalSessionSeed] = []
    var busy: [DateInterval] = []

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        let start = calendar.startOfDay(for: anchor)
        let dayStart = calendar.date(byAdding: .day, value: day, to: start)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: dayStart)!
    }

    func weekday(_ day: Int) -> Int { calendar.component(.weekday, from: at(day, 12)) }
    func isWeekend(_ day: Int) -> Bool { [1, 7].contains(weekday(day)) }

    @discardableResult
    mutating func session(_ day: Int, _ hour: Int, _ minute: Int = 0, planned: Int? = nil, goal: String? = nil, open: Bool = false,
                          _ parts: [(Classification, Int, EvalApp)]) -> Date {
        var cursor = at(day, hour, minute)
        let index = sessions.count
        let start = cursor
        for (kind, minutes, app) in parts {
            let end = cursor.addingTimeInterval(TimeInterval(minutes * 60))
            blocks.append(EvalBlock(start: cursor, end: end, kind: kind, app: app, session: index))
            cursor = end
        }
        sessions.append(EvalSessionSeed(start: start, end: open ? nil : cursor, planned: planned, goal: goal))
        return cursor
    }

    mutating func loose(_ day: Int, _ hour: Int, _ minute: Int = 0, minutes: Int, _ kind: Classification, _ app: EvalApp) {
        let start = at(day, hour, minute)
        blocks.append(EvalBlock(start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)), kind: kind, app: app, session: nil))
    }

    mutating func looseAt(_ start: Date, seconds: Int, _ kind: Classification, _ app: EvalApp) {
        blocks.append(EvalBlock(start: start, end: start.addingTimeInterval(TimeInterval(seconds)), kind: kind, app: app, session: nil))
    }

    /// The history up to `now`, in a store of its own. Nothing here touches
    /// the app's real store.
    @MainActor
    func container() throws -> ModelContainer {
        let schema = Schema([Session.self, ActivityEvent.self, TitleOptOut.self, AppRule.self, DailyLimit.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        var stored: [Int: Session] = [:]
        for (index, seed) in sessions.enumerated() where seed.start <= now {
            let session = Session(startedAt: seed.start, plannedDurationMinutes: seed.planned)
            session.endedAt = seed.end.flatMap { $0 <= now ? $0 : nil }
            session.goal = seed.goal
            context.insert(session)
            stored[index] = session
        }
        for block in blocks where block.start < now {
            let event = ActivityEvent(startedAt: block.start, endedAt: min(block.end, now),
                                      bundleIdentifier: block.app.bundle, appName: block.app.name)
            event.url = block.app.host.map { "https://www.\($0)/page" }
            event.classification = block.kind
            event.session = block.session.flatMap { stored[$0] }
            context.insert(event)
        }
        try context.save()
        return container
    }
}

enum EvalCalendars {
    /// UTC, weeks from Monday, as the committed tests use.
    static let gb: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    static let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 1
        calendar.minimumDaysInFirstWeek = 1
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    static func date(_ calendar: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
}

// MARK: - The ground truth

/// Totals worked out from the seeded blocks, minute by minute. It uses nothing
/// from the app but the `Classification` cases.
struct EvalTruth {
    let scenario: EvalScenario

    private var calendar: Calendar { scenario.calendar }
    private var now: Date { scenario.now }
    private var today: Date { calendar.startOfDay(for: now) }

    /// Calls `body` for each whole minute of each block in `[from, to)`.
    private func forEachMinute(from: Date, to: Date, _ body: (EvalBlock, Date) -> Void) {
        for block in scenario.blocks {
            var t = max(block.start, from)
            let end = min(block.end, to, now)
            while t < end {
                body(block, t)
                t = t.addingTimeInterval(60)
            }
        }
    }

    private var monthStart: Date { calendar.date(byAdding: .day, value: -27, to: today)! }

    struct BestHours {
        var from = 0, to = 0, rate = 0, held = 0, overall = 0
        var weakFrom: Int?, weakTo: Int?, weakRate: Int?
    }

    func bestHours() -> BestHours? {
        var focus = [Double](repeating: 0, count: 24), drift = focus
        var trackedByDay: [Date: Double] = [:]
        forEachMinute(from: monthStart, to: now) { block, t in
            let hour = calendar.component(.hour, from: t)
            if block.kind == .focus { focus[hour] += 1 }
            if block.kind == .distraction { drift[hour] += 1 }
            trackedByDay[calendar.startOfDay(for: t), default: 0] += 1
        }
        let active = (0..<24).filter { focus[$0] + drift[$0] >= 30 }
        let activeDays = trackedByDay.values.filter { $0 >= 10 }.count
        guard activeDays >= 3, active.count >= 2, focus.reduce(0, +) > 0 else { return nil }
        func rate(_ r: Range<Int>) -> Double {
            let f = r.reduce(0) { $0 + focus[$1] }, d = r.reduce(0) { $0 + drift[$1] }
            return f + d > 0 ? f / (f + d) : 0
        }
        var list: [Range<Int>] = []
        for length in [3, 2, 1] {
            list = (0...(24 - length)).map { $0..<($0 + length) }.filter { $0.allSatisfy(active.contains) }
            if !list.isEmpty { break }
        }
        guard let best = list.max(by: { rate($0) < rate($1) }) else { return nil }
        var out = BestHours()
        out.from = best.lowerBound
        out.to = best.upperBound
        out.rate = Int((rate(best) * 100).rounded())
        let bestFocus = best.reduce(0.0) { $0 + focus[$1] }
        let allFocus: Double = focus.reduce(0, +), allDrift: Double = drift.reduce(0, +)
        out.held = Int((bestFocus / allFocus * 100).rounded())
        out.overall = Int((allFocus / (allFocus + allDrift) * 100).rounded())
        if let weak = list.filter({ !$0.overlaps(best) }).min(by: { rate($0) < rate($1) }) {
            out.weakFrom = weak.lowerBound
            out.weakTo = weak.upperBound
            out.weakRate = Int((rate(weak) * 100).rounded())
        }
        return out
    }

    /// Drift by what it was on, in minutes, over the last 28 days, within
    /// `hours` when given.
    func driftByTarget(hours: Range<Int>? = nil) -> [(name: String, minutes: Double)] {
        var totals: [String: Double] = [:]
        forEachMinute(from: monthStart, to: now) { block, t in
            guard block.kind == .distraction else { return }
            if let hours, !hours.contains(calendar.component(.hour, from: t)) { return }
            totals[block.app.shown, default: 0] += 1
        }
        return totals.map { (name: $0.key, minutes: $0.value) }.sorted { $0.minutes > $1.minutes }
    }

    struct Week {
        var thisFocus = 0.0, sameFocus = 0.0, lastFocus = 0.0, thisDrift = 0.0, sameDrift = 0.0
        var thisRate: Int { thisFocus + thisDrift > 0 ? Int((thisFocus / (thisFocus + thisDrift) * 100).rounded()) : 0 }
        var sameRate: Int { sameFocus + sameDrift > 0 ? Int((sameFocus / (sameFocus + sameDrift) * 100).rounded()) : 0 }
    }

    func week() -> Week {
        let start = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let lastStart = calendar.date(byAdding: .weekOfYear, value: -1, to: start)!
        // By the clock: the same weekday and time last week.
        let same = calendar.date(byAdding: .weekOfYear, value: -1, to: now)!
        var out = Week()
        forEachMinute(from: start, to: now) { block, _ in
            if block.kind == .focus { out.thisFocus += 1 }
            if block.kind == .distraction { out.thisDrift += 1 }
        }
        forEachMinute(from: lastStart, to: start) { block, t in
            if block.kind == .focus { out.lastFocus += 1 }
            guard t < same else { return }
            if block.kind == .focus { out.sameFocus += 1 }
            if block.kind == .distraction { out.sameDrift += 1 }
        }
        return out
    }

    struct DriftDays {
        var worstWeekday = 0
        var worstAverage = 0.0, othersAverage = 0.0
    }

    /// Finished days of the last 28, days with 10 minutes or more tracked.
    func driftDays() -> DriftDays? {
        let from = calendar.date(byAdding: .day, value: -28, to: today)!
        var tracked: [Date: Double] = [:], drift: [Date: Double] = [:]
        forEachMinute(from: from, to: today) { block, t in
            let day = calendar.startOfDay(for: t)
            tracked[day, default: 0] += 1
            if block.kind == .distraction { drift[day, default: 0] += 1 }
        }
        var sum: [Int: Double] = [:], seen: [Int: Int] = [:]
        for (day, time) in tracked where time >= 10 {
            let weekday = calendar.component(.weekday, from: day)
            sum[weekday, default: 0] += drift[day] ?? 0
            seen[weekday, default: 0] += 1
        }
        guard seen.count >= 3, seen.values.reduce(0, +) >= 5 else { return nil }
        let averages = sum.map { (key: $0.key, value: $0.value / Double(seen[$0.key] ?? 1)) }
        let eligible = averages.filter { (seen[$0.key] ?? 0) >= 2 }
        guard let worst = (eligible.isEmpty ? averages : eligible).max(by: { $0.value < $1.value }) else { return nil }
        var out = DriftDays()
        out.worstWeekday = worst.key
        out.worstAverage = worst.value
        let otherDays = seen.values.reduce(0, +) - (seen[worst.key] ?? 0)
        out.othersAverage = otherDays > 0 ? (sum.values.reduce(0, +) - (sum[worst.key] ?? 0)) / Double(otherDays) : 0
        return out
    }

    struct Lengths {
        var groups: [(name: String, sessions: Int, rate: Int)] = []
        var best: String?
        var bestRate: Int?
        var bestCount: Int?
    }

    func lengths() -> Lengths {
        let bands: [(String, Range<Int>)] = [("under 25", 5..<25), ("of 25 to 44", 25..<45), ("of 45 to 74", 45..<75), ("of 75 minutes or more", 75..<100_000)]
        var focus = [Int: Double](), drift = [Int: Double]()
        for block in scenario.blocks {
            guard let index = block.session else { continue }
            if block.kind == .focus { focus[index, default: 0] += block.minutes }
            if block.kind == .distraction { drift[index, default: 0] += block.minutes }
        }
        var out = Lengths()
        var bestRate = -1.0
        for (name, range) in bands {
            var count = 0
            var f = 0.0, d = 0.0
            for (index, seed) in scenario.sessions.enumerated() {
                guard let end = seed.end, end <= now, seed.start >= monthStart else { continue }
                let minutes = Int(end.timeIntervalSince(seed.start) / 60)
                guard range.contains(minutes) else { continue }
                count += 1
                f += focus[index] ?? 0
                d += drift[index] ?? 0
            }
            guard count > 0 else { continue }
            let rate = f + d > 0 ? f / (f + d) : 0
            out.groups.append((name, count, Int((rate * 100).rounded())))
            if count >= 2, f + d >= 10, rate > bestRate {
                bestRate = rate
                out.best = name
                out.bestRate = Int((rate * 100).rounded())
                out.bestCount = count
            }
        }
        return out
    }

    /// Minutes on an app or site in `[from, to)`, up to now.
    func minutes(on shown: String, from: Date, to: Date) -> Double {
        var total = 0.0
        forEachMinute(from: from, to: to) { block, _ in
            if block.app.shown == shown { total += 1 }
        }
        return total
    }

    var weekStart: Date { calendar.dateInterval(of: .weekOfYear, for: now)!.start }
    var lastWeekStart: Date { calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart)! }
}

/// "14h 15m" as Ask writes it, from whole minutes.
func evalHM(_ minutes: Double) -> String {
    let total = Int(minutes)
    let h = total / 60, m = total % 60
    if h == 0 { return "\(m)m" }
    if m == 0 { return "\(h)h" }
    return String(format: "%dh %02dm", h, m)
}

// MARK: - The checker

/// Pulls numbers, durations, percentages, clock times and names out of text,
/// and flags anything in generated text that the facts don't have.
enum EvalCheck {
    struct Tokens {
        var durations = Set<Int>()
        var percents = Set<Int>()
        var clocks = Set<String>()
        var numbers = Set<Int>()
    }

    static func tokens(_ source: String) -> Tokens {
        var out = Tokens()
        var text = source.lowercased()
            .replacingOccurrences(of: "\u{202f}", with: " ")
            .replacingOccurrences(of: "\u{a0}", with: " ")

        // Clock times: 09:00, 9.00, 9 am.
        while let m = text.firstMatch(of: /\b(\d{1,2})[:.](\d{2})\s*(am|pm|a\.m\.|p\.m\.|uhr)?/) {
            var hour = Int(m.1) ?? 0
            if let suffix = m.3, suffix.hasPrefix("p"), hour < 12 { hour += 12 }
            if let suffix = m.3, suffix.hasPrefix("a"), hour == 12 { hour = 0 }
            out.clocks.insert(String(format: "%d:%@", hour, String(m.2)))
            text.replaceSubrange(m.range, with: " ¦ ")
        }
        while let m = text.firstMatch(of: /\b(\d{1,2})\s*(am|pm|a\.m\.|p\.m\.|uhr)\b/) {
            var hour = Int(m.1) ?? 0
            if m.2.hasPrefix("p"), hour < 12 { hour += 12 }
            if m.2.hasPrefix("a"), hour == 12 { hour = 0 }
            out.clocks.insert("\(hour):00")
            text.replaceSubrange(m.range, with: " ¦ ")
        }
        // Percentages.
        while let m = text.firstMatch(of: /(\d+)\s*(%|percent\b|per cent\b|prozent\b)/) {
            out.percents.insert(Int(m.1) ?? -1)
            text.replaceSubrange(m.range, with: " ¦ ")
        }
        // Hours, with or without minutes.
        while let m = text.firstMatch(of: /(\d+)\s*(?:h|hr|hrs|hours?|std\.?|stunden?)\b\.?(?:\s*(?:and|und|,)?\s*(\d+)\s*(?:m|min|mins|minutes?|minuten?)\b\.?)?/) {
            let hours = Int(m.1) ?? 0, minutes = m.2.flatMap { Int($0) } ?? 0
            out.durations.insert(hours * 60 + minutes)
            text.replaceSubrange(m.range, with: " ¦ ")
        }
        while let m = text.firstMatch(of: /(\d+)(?:-|\s*)(?:m|min|mins|minutes?|minuten?)\b\.?/) {
            out.durations.insert(Int(m.1) ?? -1)
            text.replaceSubrange(m.range, with: " ¦ ")
        }
        // Everything else that's a number.
        for m in text.matches(of: /\d+/) { out.numbers.insert(Int(m.0) ?? -1) }
        return out
    }

    private static let stop: Set<String> = [
        "you", "your", "the", "a", "an", "focus", "focused", "drift", "drifted", "sessions", "session", "it", "that", "these", "those", "this",
        "most", "in", "on", "at", "between", "from", "and", "but", "for", "with", "they", "there", "days", "day", "hours", "time", "try", "if",
        "when", "over", "last", "week", "weeks", "about", "only", "so", "no", "not", "yes", "because", "what", "which", "shorter", "longer", "best", "weak", "weakest",
    ]
    static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                           "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonntag"]
    static let months = ["january", "february", "march", "april", "june", "july", "august", "september", "october", "november", "december",
                         "januar", "februar", "märz", "juni", "juli", "oktober", "dezember"]
    static let parts = ["morning", "afternoon", "evening", "night", "noon", "lunch", "midnight",
                        "vormittag", "morgen", "nachmittag", "abend", "nacht", "mittag"]
    static let spelled = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "twenty", "thirty", "forty", "fifty",
                          "half", "quarter", "twice", "double", "triple", "dozen", "third", "hundred",
                          "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn", "halb", "hälfte", "doppelt"]
    static let causal = ["because", "due to", "caused", "causes", "leads to", "as a result", "therefore", "weil", "deshalb", "wegen"]
    static let advice = ["should", "consider", "recommend", "try to", "sollten", "empfehle"]
    static let judging = ["great", "excellent", "amazing", "well done", "good job", "terrible", "bad", "impressive", "wonderful", "congratulations"]

    /// What's wrong with `text`, as short tags. "!" tags are hard errors: a
    /// number or name the facts don't have. "?" tags are for a person to read.
    static func flags(_ text: String, facts: [String]) -> [String] {
        let source = facts.joined(separator: " ")
        let known = tokens(source), said = tokens(text)
        let lower = text.lowercased(), sourceLower = source.lowercased()
        var out: [String] = []
        let allNumbers = known.numbers.union(known.durations).union(known.percents)
        for value in said.durations.sorted() where !known.durations.contains(value) { out.append("!duration:\(value)m") }
        for value in said.percents.sorted() where !known.percents.contains(value) { out.append("!percent:\(value)") }
        for value in said.clocks.sorted() where !known.clocks.contains(value) { out.append("!clock:\(value)") }
        for value in said.numbers.sorted() where !allNumbers.contains(value) { out.append("!number:\(value)") }
        for word in weekdays where lower.contains(word) && !sourceLower.contains(word) { out.append("!weekday:\(word)") }
        for word in months where lower.contains(word) && !sourceLower.contains(word) { out.append("!month:\(word)") }
        for word in spelled where hasWord(lower, word) && !hasWord(sourceLower, word) { out.append("?spelled:\(word)") }
        for word in parts where lower.contains(word) && !sourceLower.contains(word) { out.append("?part:\(word)") }
        for word in causal where lower.contains(word) && !sourceLower.contains(word) { out.append("?causal:\(word)") }
        for word in advice where lower.contains(word) && !sourceLower.contains(word) { out.append("?advice:\(word)") }
        for word in judging where hasWord(lower, word) && !sourceLower.contains(word) { out.append("?judging:\(word)") }
        // Sites.
        for token in lower.split(whereSeparator: { $0.isWhitespace || ",;:()\"".contains($0) }) {
            let word = token.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            if word.contains("."), word.rangeOfCharacter(from: .letters) != nil, !sourceLower.contains(word) { out.append("!site:\(word)") }
        }
        // Capitalised words mid-sentence that the facts don't have.
        let words = text.split(whereSeparator: { $0.isWhitespace })
        for (index, word) in words.enumerated() where index > 0 {
            let previous = words[index - 1]
            if previous.hasSuffix(".") || previous.hasSuffix(":") { continue }
            let clean = word.trimmingCharacters(in: .punctuationCharacters)
            guard let first = clean.first, first.isUppercase, clean.count > 1,
                  !sourceLower.contains(clean.lowercased()), !stop.contains(clean.lowercased()) else { continue }
            out.append("?name:\(clean)")
        }
        if text.contains("!") { out.append("?exclamation") }
        if text.contains("\"") || text.contains("“") { out.append("?quote") }
        if text.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { out.append("?emoji") }
        return out
    }

    private static func hasWord(_ text: String, _ word: String) -> Bool {
        text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b", options: .regularExpression) != nil
    }
}
