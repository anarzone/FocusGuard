import Foundation

/// How hard a block is to get past on each preset. The block screen, the
/// menu, the daily limits and (later) the browser extension all read this,
/// so the rules live in one place.
///
/// - Gentle: "Let me through" right away; daily limits give +5 min up to 3 times a day.
/// - Standard: "Let me through" after a 5 s wait; +5 min once a day, after a 5 s wait.
/// - Strict: no "Let me through"; "It's for work" opens after 10 s; the
///   blocked list and the preset are locked until the session ends; no extra
///   time, and a limit can only be changed for tomorrow.
///
/// Every pass lasts 2 minutes and the time on the site counts as drift.
struct OverridePolicy: Equatable, Codable, Sendable {
    /// Whether the block screen offers "Let me through".
    let allowsPass: Bool
    /// Seconds before "Let me through" can be pressed; 0 is right away.
    let passWaitSeconds: Int
    /// How long a pass lasts.
    let passSeconds: TimeInterval
    /// Seconds before "It's for work" can be pressed.
    let forWorkWaitSeconds: Int
    /// The blocked list and the preset can't change until the session ends.
    let locksDuringSession: Bool
    /// Extra time on a daily limit once it runs out.
    let extraTime: ExtraTime
    /// A daily limit can only be changed (or removed) from tomorrow.
    let limitChangesWaitForTomorrow: Bool

    struct ExtraTime: Equatable, Codable, Sendable {
        /// Minutes each grant adds.
        let minutes: Int
        /// Grants per limit per day; 0 means none.
        let timesPerDay: Int
        /// Seconds before the button can be pressed.
        let waitSeconds: Int

        var isOffered: Bool { timesPerDay > 0 }
    }

    static let gentle = OverridePolicy(
        allowsPass: true, passWaitSeconds: 0, passSeconds: 120,
        forWorkWaitSeconds: 0, locksDuringSession: false,
        extraTime: ExtraTime(minutes: 5, timesPerDay: 3, waitSeconds: 0),
        limitChangesWaitForTomorrow: false
    )

    static let standard = OverridePolicy(
        allowsPass: true, passWaitSeconds: 5, passSeconds: 120,
        forWorkWaitSeconds: 0, locksDuringSession: false,
        extraTime: ExtraTime(minutes: 5, timesPerDay: 1, waitSeconds: 5),
        limitChangesWaitForTomorrow: false
    )

    static let strict = OverridePolicy(
        allowsPass: false, passWaitSeconds: 0, passSeconds: 120,
        forWorkWaitSeconds: 10, locksDuringSession: true,
        extraTime: ExtraTime(minutes: 5, timesPerDay: 0, waitSeconds: 0),
        limitChangesWaitForTomorrow: true
    )

    /// The policy for the preset in Settings right now.
    static var current: OverridePolicy { DriftResponse.effective.overridePolicy }
}

extension DriftResponse {
    var overridePolicy: OverridePolicy {
        switch self {
        case .gentle:   return .gentle
        case .standard: return .standard
        case .strict:   return .strict
        }
    }

    /// The preset in force. Thresholds tuned by hand in Settings → Escalation
    /// count as Strict when strict mode is on, otherwise as Standard.
    static var effective: DriftResponse {
        current ?? (UserDefaults.standard.bool(forKey: SettingsKeys.Escalation.strictMode) ? .strict : .standard)
    }

    /// The preset these engine settings match, falling back the same way as `effective`.
    static func matching(silence: Int, notify: Int, block: Int, strict: Bool) -> DriftResponse {
        allCases.first { $0.values == (silence, notify, block, strict) } ?? (strict ? .strict : .standard)
    }
}
