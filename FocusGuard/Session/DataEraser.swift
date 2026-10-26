import Foundation
import SwiftData

/// Destructive data actions, shared by Settings → Privacy and the menu's
/// quick settings. Tracking pauses while rows are deleted so no new events
/// land mid-delete.
@MainActor
enum DataEraser {
    /// Today's activity and today's finished sessions. A running session is
    /// kept (its tracked events are still removed).
    static func deleteToday(appState: AppState, now: Date = .now) {
        defer { NotificationCenter.default.post(name: .activityTotalsChanged, object: nil) }
        let context = appState.container.mainContext
        let dayStart = Calendar.current.startOfDay(for: now)
        let running = appState.sessionManager.currentSession?.id

        appState.tracker.stop()
        defer { appState.tracker.start() }

        Persistence.deleteAll(ActivityEvent.self, where: #Predicate { $0.startedAt >= dayStart }, in: context)
        let sessions = Persistence.fetch(context, FetchDescriptor<Session>(predicate: #Predicate { $0.startedAt >= dayStart }))
        for session in sessions where session.id != running {
            context.delete(session)
        }
        Persistence.save(context)
        appState.recap = nil
    }

    /// Everything: activity, sessions and rules. Default rules are re-seeded
    /// so classification keeps working.
    static func eraseAll(appState: AppState) {
        defer { NotificationCenter.default.post(name: .activityTotalsChanged, object: nil) }
        let context = appState.container.mainContext
        if appState.sessionManager.currentSession != nil {
            appState.sessionManager.stopSession(status: .abandoned)
        }

        appState.tracker.stop()
        defer { appState.tracker.start() }

        Persistence.deleteAll(Session.self, in: context)        // cascades to their events
        Persistence.deleteAll(ActivityEvent.self, in: context)  // events outside sessions
        Persistence.deleteAll(AppRule.self, in: context)

        DefaultRules.seedIfNeeded(in: context)
        appState.classifier.invalidate()
        appState.smartCategories.erase()
        appState.recap = nil
        WeeklyCoach.shared.erase()
    }
}

/// One-tap presets for how hard FocusGuard pushes back when you drift. They
/// write the same thresholds Settings → Escalation edits in detail.
enum DriftResponse: String, CaseIterable, Identifiable {
    case gentle, standard, strict

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gentle:   return "Gentle"
        case .standard: return "Standard"
        case .strict:   return "Strict"
        }
    }

    var summary: String {
        switch self {
        case .gentle:   return "Nudge after 1 min · block after 3 min"
        case .standard: return "Nudge after 30 s · block after 90 s"
        case .strict:   return "Block the screen as soon as you drift"
        }
    }

    var values: (silence: Int, notify: Int, block: Int, strict: Bool) {
        switch self {
        case .gentle:   return (20, 60, 180, false)
        case .standard: return (Constants.Escalation.defaultSilenceSeconds,
                                Constants.Escalation.defaultNotifySeconds,
                                Constants.Escalation.defaultBlockSeconds, false)
        case .strict:   return (Constants.Escalation.defaultSilenceSeconds,
                                Constants.Escalation.defaultNotifySeconds,
                                Constants.Escalation.defaultBlockSeconds, true)
        }
    }

    /// The preset matching the stored settings, or nil if they were tuned by hand.
    static var current: DriftResponse? {
        let d = UserDefaults.standard
        func int(_ key: String, _ fallback: Int) -> Int { d.object(forKey: key) as? Int ?? fallback }
        let stored = (
            int(SettingsKeys.Escalation.silenceThreshold, Constants.Escalation.defaultSilenceSeconds),
            int(SettingsKeys.Escalation.notifyThreshold, Constants.Escalation.defaultNotifySeconds),
            int(SettingsKeys.Escalation.blockThreshold, Constants.Escalation.defaultBlockSeconds),
            d.bool(forKey: SettingsKeys.Escalation.strictMode)
        )
        return allCases.first { $0.values == stored }
    }

    @MainActor
    func apply(to engine: EscalationEngine) {
        let v = values
        let d = UserDefaults.standard
        d.set(v.silence, forKey: SettingsKeys.Escalation.silenceThreshold)
        d.set(v.notify, forKey: SettingsKeys.Escalation.notifyThreshold)
        d.set(v.block, forKey: SettingsKeys.Escalation.blockThreshold)
        d.set(v.strict, forKey: SettingsKeys.Escalation.strictMode)
        engine.silenceThreshold = TimeInterval(v.silence)
        engine.notifyThreshold = TimeInterval(v.notify)
        engine.blockThreshold = TimeInterval(v.block)
        engine.strictMode = v.strict
    }
}
