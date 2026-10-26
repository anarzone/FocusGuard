import Foundation

/// What it takes to undo an experiment.
enum CoachUndo: Codable, Equatable, Sendable {
    /// Remove the daily limit the coach added.
    case limit(UUID)
    /// Remove a coach rule (`CoachRules`).
    case rule(UUID)
    /// Put the morning plan's hour and switch back; nil means unset.
    case morningPlan(hour: Int?, enabled: Bool?)
}

/// Puts experiments in place and takes them back.
@MainActor
protocol CoachApplying: AnyObject {
    /// Applies `experiment` until `until` (nil: for good). Nil when it can't
    /// be applied, such as a limit on a site that already has one.
    func apply(_ experiment: CoachExperiment, until: Date?) -> CoachUndo?
    /// Takes a change back. `weekOver`: its week has ended, so it goes now,
    /// even where Strict would make a change wait for tomorrow.
    func undo(_ undo: CoachUndo, weekOver: Bool)
    /// Makes a change stay after its week.
    func keep(_ undo: CoachUndo)
    /// The settings an experiment is planned against.
    func settings() -> CoachSettings
}

/// The real settings: daily limits, the coach's rules, the morning plan.
@MainActor
final class LiveCoachApplier: CoachApplying {
    private let limits: DailyLimitsEngine
    private let preset: () -> DriftResponse
    private let defaults: UserDefaults

    init(limits: DailyLimitsEngine, preset: @escaping () -> DriftResponse, defaults: UserDefaults = .standard) {
        self.limits = limits
        self.preset = preset
        self.defaults = defaults
    }

    func apply(_ experiment: CoachExperiment, until: Date?) -> CoachUndo? {
        switch experiment {
        case let .siteLimit(host, minutes):
            guard !limits.statuses.contains(where: { $0.isSite && Classifier.host(host, matches: $0.target) }),
                  let limit = limits.addLimit(target: host, isSite: true, minutes: minutes) else { return nil }
            return .limit(limit.id)
        case let .shorterSessions(hours, minutes):
            let rule = CoachRule(hours: hours, change: .sessionMinutes(minutes), until: until)
            CoachRules.add(rule, defaults)
            return .rule(rule.id)
        case let .stricterPreset(hours, preset):
            let rule = CoachRule(hours: hours, change: .preset(preset), until: until)
            CoachRules.add(rule, defaults)
            return .rule(rule.id)
        case let .earlierMorningPlan(hour):
            let undo = CoachUndo.morningPlan(hour: defaults.object(forKey: HabitSettings.morningPlanHour) as? Int,
                                             enabled: defaults.object(forKey: HabitSettings.morningPlan) as? Bool)
            defaults.set(hour, forKey: HabitSettings.morningPlanHour)
            defaults.set(true, forKey: HabitSettings.morningPlan)
            return undo
        }
    }

    func undo(_ undo: CoachUndo, weekOver: Bool) {
        switch undo {
        case .limit(let id):
            limits.removeLimit(id, evenOnStrict: weekOver)
        case .rule(let id):
            CoachRules.remove(id, defaults)
        case let .morningPlan(hour, enabled):
            restore(hour, HabitSettings.morningPlanHour)
            restore(enabled, HabitSettings.morningPlan)
        }
    }

    func keep(_ undo: CoachUndo) {
        if case .rule(let id) = undo { CoachRules.keep(id, defaults) }
    }

    func settings() -> CoachSettings {
        CoachSettings(limitedSites: Set(limits.statuses.filter(\.isSite).map(\.target)),
                      preset: preset(),
                      morningPlanHour: HabitSchedule.morningStartHour(defaults))
    }

    private func restore(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
