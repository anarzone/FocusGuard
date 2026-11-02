import Foundation

/// Whether a session reached its goal: the person's own pick, stored on the
/// session as its raw value. The model never decides this.
enum GoalVerdict: String, Codable, CaseIterable {
    case done, partly, notYet

    /// The goal card's and the work log's chip.
    var chipText: String {
        switch self {
        case .done:   return String(localized: "goalVerdict.done", defaultValue: "Done", comment: "Whether a session's goal was reached: it was. Not the button that closes a sheet")
        case .partly: return String(localized: "Partly", comment: "Whether a session's goal was reached")
        case .notYet: return String(localized: "Not yet", comment: "Whether a session's goal was reached")
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
        /// Words from that app's window titles; empty when it has none.
        let what: String
    }

    /// What a window title shows about the goal, and when.
    var evidence: String?
    /// The same in a few words, for the menu's debrief row.
    var evidenceShort: String?
    var workedOn: [Line] = []
    var driftDetail: String?
    var project: String?
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
        /// Words from its window titles; empty when there are none, and in a plain summary.
        let what: String
        let seconds: TimeInterval
    }

    let sessionLabel: String
    let start: Date
    let end: Date
    let goal: String?
    /// The person's own pick. Nil when there's no goal, or they haven't said.
    var verdict: GoalVerdict?
    let evidence: String?
    let evidenceShort: String?
    let workedOn: [Item]
    /// "x.com · 3 min"
    let drift: String?
    let driftDetail: String?
    /// For next time, from the biggest drift. By rule: the model's tips were
    /// things like "Use Mail more clearly".
    let tip: String?
    let tipDetail: String?
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
        let tip = top.flatMap { Self.tip(for: $0) }
        return SessionDebrief(
            sessionLabel: label, start: facts.start, end: facts.end,
            goal: facts.goal, verdict: nil, evidence: nil, evidenceShort: nil,
            workedOn: Array(items),
            drift: top.map(Self.driftText),
            driftDetail: facts.drifts.first(where: { $0.name == top?.name }).map { String(localized: "At \(Self.clock($0.start)).", comment: "When a drift happened") },
            tip: tip?.0, tipDetail: tip?.1, project: nil,
            focused: facts.focused, focusRate: facts.focusRate, isWritten: false
        )
    }

    /// The model's write-up over the facts. What the session doesn't back up
    /// is dropped (`DebriefCheck`), even from a debrief written before that
    /// check, and times always come from the facts.
    static func written(_ written: StoredDebrief, facts: DebriefFacts, label: String,
                        verdict: GoalVerdict?) -> SessionDebrief {
        let stored = DebriefCheck(facts: facts).clean(written)
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
            tip: plain.tip, tipDetail: plain.tipDetail,
            project: stored.project,
            focused: facts.focused, focusRate: facts.focusRate, isWritten: true
        )
    }

    /// Something to try, once a drift took a couple of minutes.
    private static func tip(for drift: (name: String, seconds: TimeInterval)) -> (String, String)? {
        guard drift.seconds >= 2 * 60 else { return nil }
        let minutes = Int((drift.seconds / 60).rounded())
        return (String(localized: "Keep \(drift.name) closed next session"),
                String(localized: "It took \(minutes) min of this one.", comment: "Of this session"))
    }

    /// "x.com · 3 min"
    static func driftText(_ drift: (name: String, seconds: TimeInterval)) -> String {
        let minutes = max(1, Int((drift.seconds / 60).rounded()))
        return "\(drift.name) · " + String(localized: "\(minutes) min", comment: "Compact minutes")
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
