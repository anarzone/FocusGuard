import Foundation

/// Whether a session reached its goal. Stored on the session as its raw
/// value; the user can correct the debrief's call.
enum GoalVerdict: String, Codable, CaseIterable {
    case done, partly, notYet

    /// "Looks done": the debrief's own call reads as a guess.
    var debriefText: String {
        switch self {
        case .done:   return "Looks done"
        case .partly: return "Partly done"
        case .notYet: return "Not yet"
        }
    }

    /// The work log's chip.
    var chipText: String {
        switch self {
        case .done:   return "Done"
        case .partly: return "Partly"
        case .notYet: return "Not yet"
        }
    }
}

/// The part of a debrief that only the model can write, kept on the
/// session as JSON (`Session.debriefData`). Everything else is worked out
/// from the session's activity each time it's shown.
struct StoredDebrief: Codable, Equatable {
    struct Line: Codable, Equatable {
        /// An app or site from the session, as `DebriefFacts` names it.
        let app: String
        /// "SessionNamer.swift and its 13 tests"
        let what: String
    }

    /// The model's call on the goal; the session's `goalVerdictRaw` starts
    /// out as this and follows the user's correction after that.
    var verdict: GoalVerdict?
    /// "PR #49 was merged on github.com at 19:41."
    var evidence: String?
    /// "PR #49 merged", for the menu's debrief row.
    var evidenceShort: String?
    var workedOn: [Line] = []
    /// "At 19:23, while a build was running."
    var driftDetail: String?
    /// "Keep the build log in view", and why.
    var tip: String?
    var tipDetail: String?
    var project: String?
    var standup: String?
    var writtenAt: Date = .now
}

extension Session {
    var goalVerdict: GoalVerdict? {
        get { goalVerdictRaw.flatMap(GoalVerdict.init(rawValue:)) }
        set { goalVerdictRaw = newValue?.rawValue }
    }

    var storedDebrief: StoredDebrief? {
        get { debriefData.flatMap { try? JSONDecoder().decode(StoredDebrief.self, from: $0) } }
        set { debriefData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
}

/// What the debrief pane shows for a finished session: the model's write-up
/// when there is one, else a plain summary (time, focus rate, top apps).
struct SessionDebrief: Equatable {
    struct Item: Equatable, Identifiable {
        var id: String { app }
        let app: String
        /// "SessionNamer.swift and its 13 tests"; empty in a plain summary.
        let what: String
        let seconds: TimeInterval
    }

    let sessionLabel: String
    let start: Date
    let end: Date
    let goal: String?
    /// Nil when there's no goal, or nothing to judge it with.
    var verdict: GoalVerdict?
    let evidence: String?
    let evidenceShort: String?
    let workedOn: [Item]
    /// "x.com · 3 min"
    let drift: String?
    let driftDetail: String?
    let tip: String?
    let tipDetail: String?
    let standup: String?
    let project: String?
    let focused: TimeInterval
    let focusRate: Double
    /// Written on this Mac by the model; false for the plain summary.
    let isWritten: Bool

    var focusPercent: Int { Int((focusRate * 100).rounded()) }

    /// The facts on their own, for Macs without Apple Intelligence and for
    /// the moments before the model is done.
    static func plain(_ facts: DebriefFacts, label: String) -> SessionDebrief {
        let worked = facts.apps.filter { $0.classification == .focus }
        let items = (worked.isEmpty ? facts.apps.filter { $0.classification != .distraction } : worked)
            .prefix(3)
            .map { Item(app: $0.name, what: "", seconds: $0.seconds) }
        let top = facts.topDrift
        return SessionDebrief(
            sessionLabel: label, start: facts.start, end: facts.end,
            goal: facts.goal, verdict: nil, evidence: nil, evidenceShort: nil,
            workedOn: Array(items),
            drift: top.map(Self.driftText),
            driftDetail: facts.drifts.first(where: { $0.name == top?.name }).map { "At \(Self.clock($0.start))." },
            tip: nil, tipDetail: nil, standup: nil, project: nil,
            focused: facts.focused, focusRate: facts.focusRate, isWritten: false
        )
    }

    /// The model's write-up over the facts. Names it gave that aren't in
    /// the session are dropped, and times always come from the facts.
    static func written(_ stored: StoredDebrief, facts: DebriefFacts, label: String,
                        verdict: GoalVerdict?) -> SessionDebrief {
        let plain = plain(facts, label: label)
        let seconds = Dictionary(facts.apps.map { ($0.name.lowercased(), $0.seconds) }, uniquingKeysWith: +)
        var seen = Set<String>()
        let items = stored.workedOn.compactMap { line -> Item? in
            let key = line.app.lowercased()
            guard let time = seconds[key], seen.insert(key).inserted else { return nil }
            let name = facts.apps.first { $0.name.lowercased() == key }?.name ?? line.app
            return Item(app: name, what: line.what, seconds: time)
        }
        return SessionDebrief(
            sessionLabel: label, start: facts.start, end: facts.end,
            goal: facts.goal, verdict: facts.goal == nil ? nil : verdict,
            evidence: stored.evidence, evidenceShort: stored.evidenceShort,
            workedOn: items.isEmpty ? plain.workedOn : items,
            drift: plain.drift,
            driftDetail: plain.drift == nil ? nil : (stored.driftDetail ?? plain.driftDetail),
            tip: stored.tip, tipDetail: stored.tipDetail, standup: stored.standup,
            project: stored.project,
            focused: facts.focused, focusRate: facts.focusRate, isWritten: true
        )
    }

    /// "x.com · 3 min"
    static func driftText(_ drift: (name: String, seconds: TimeInterval)) -> String {
        "\(drift.name) · \(max(1, Int((drift.seconds / 60).rounded()))) min"
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
