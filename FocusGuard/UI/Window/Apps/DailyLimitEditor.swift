import SwiftUI

/// Free keeps one daily limit; Pro (or the trial) sets as many as you like.
@MainActor
enum LimitGate {
    /// Whether another limit can be added right now.
    static func canAdd(existing: Int, entitlements: Entitlements = .shared) -> Bool {
        guard let cap = entitlements.dailyLimitCap else { return true }
        return existing < cap
    }

    /// "When it runs out: 5 more minutes after a 5-second wait, once a day (Standard)."
    static func runsOut(_ policy: OverridePolicy, preset: DriftResponse) -> String {
        let extra = policy.extraTime
        guard extra.isOffered else {
            return policy.limitChangesWaitForTomorrow
                ? String(localized: "When it runs out: no extra time, and changes wait for tomorrow (\(preset.title)).", comment: "A daily limit. In brackets: the blocking level's name")
                : String(localized: "When it runs out: no extra time (\(preset.title)).", comment: "A daily limit. In brackets: the blocking level's name")
        }
        let times: String
        switch extra.timesPerDay {
        case 1: times = String(localized: "once a day")
        case 2: times = String(localized: "twice a day")
        default: times = String(localized: "up to \(extra.timesPerDay) times a day")
        }
        return extra.waitSeconds > 0
            ? String(localized: "When it runs out: \(extra.minutes) more minutes after a \(extra.waitSeconds)-second wait, \(times) (\(preset.title)).", comment: "A daily limit. Before the brackets: once a day, twice a day or up to 3 times a day. In brackets: the blocking level's name")
            : String(localized: "When it runs out: \(extra.minutes) more minutes, \(times) (\(preset.title)).", comment: "A daily limit. Before the brackets: once a day, twice a day or up to 3 times a day. In brackets: the blocking level's name")
    }

    /// "12 of 30 min today · resets at midnight", with any change that waits.
    static func usage(_ status: LimitStatus) -> String {
        var line = String(localized: "\(Int(status.used / 60)) of \(status.minutes + status.extraMinutes) min today · resets at midnight")
        switch status.pending {
        case .minutes(let m): line += " · " + String(localized: "\(m) min from tomorrow")
        case .removal: line += " · " + String(localized: "goes away tomorrow", comment: "A daily limit that was removed and ends tomorrow")
        case nil: break
        }
        return line
    }
}

/// The daily limit for one app or site: add it, change it in 5-minute
/// steps, take it away. Strict changes wait for tomorrow.
struct DailyLimitEditor: View {
    @Bindable var appState: AppState
    let target: String
    let isSite: Bool
    let name: String
    var entitlements: Entitlements = .shared

    @Environment(\.openWindowSheet) private var openSheet
    @State private var note: String?

    private var limits: DailyLimitsEngine { appState.limits }

    private var status: LimitStatus? {
        let key = isSite ? (DailyLimitsEngine.siteTarget(target) ?? target) : target
        return limits.statuses.first { $0.isSite == isSite && $0.target == key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Daily limit").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primaryText)
                        Text(LimitGate.usage(status)).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    LimitStepper(minutes: status.pending.flatMap { if case .minutes(let m) = $0 { return m } else { return nil } } ?? status.minutes) { minutes in
                        apply(limits.setMinutes(minutes, for: status.id))
                    }
                }
                if status.isPaused {
                    HStack(spacing: 8) {
                        Text(String(localized: "Paused: Free keeps one daily limit.", comment: "A daily limit that's off because the Free plan keeps only one"))
                            .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        Button(entitlements.canStartTrial ? "Try Pro free" : "See Pro") { openSheet(.upgrade(.unlimitedLimits)) }
                            .buttonStyle(.textLink)
                    }
                }
                Text(LimitGate.runsOut(limits.policy(for: status),
                                       preset: status.changesWaitForTomorrow ? .strict : appState.escalationEngine.preset))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Remove the limit") { apply(limits.removeLimit(status.id)) }
                    .buttonStyle(.textLink)
            } else if LimitGate.canAdd(existing: limits.statuses.count, entitlements: entitlements) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Daily limit").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primaryText)
                        Text("Allow a little each day, then pause it.").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 8)
                    Button("Add a limit") { add() }
                        .buttonStyle(.capsule(.secondary, height: 26))
                }
            } else if appState.sessionManager.currentSession != nil {
                // No upsell during a session.
                Text("Free keeps one daily limit. More are part of Pro.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            } else {
                LockedProRow(feature: .unlimitedLimits,
                             title: isSite ? String(localized: "Daily limits for any site") : String(localized: "Daily limits for any app"),
                             detail: String(localized: "Free keeps one daily limit. Pro sets one for every app and site."),
                             systemImage: "hourglass",
                             onTrialStarted: { add() },
                             onUpgrade: { openSheet(.upgrade(.unlimitedLimits)) },
                             entitlements: entitlements)
            }
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.bodyText)
            }
        }
    }

    private func add() {
        _ = limits.addLimit(target: target, isSite: isSite, name: name, minutes: 30)
    }

    private func apply(_ change: LimitChange?) {
        guard change == .fromTomorrow else { return note = nil }
        note = appState.escalationEngine.policy.limitChangesWaitForTomorrow
            ? String(localized: "Strict is on, so this takes effect tomorrow.")
            : String(localized: "Strict was on today, so this takes effect tomorrow.")
    }
}

/// − 30 min +, in 5-minute steps from 5 minutes to 4 hours.
struct LimitStepper: View {
    let minutes: Int
    let onChange: (Int) -> Void

    static let range = 5...240

    var body: some View {
        HStack(spacing: 0) {
            Button { onChange(max(Self.range.lowerBound, minutes - 5)) } label: {
                Text("−").frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .disabled(minutes <= Self.range.lowerBound)
            .accessibilityLabel("Shorter limit")
            Text("\(minutes) min")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(minWidth: 46)
            Button { onChange(min(Self.range.upperBound, minutes + 5)) } label: {
                Text("+").frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .disabled(minutes >= Self.range.upperBound)
            .accessibilityLabel("Longer limit")
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .foregroundStyle(Theme.primaryText)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.inset))
        .accessibilityElement(children: .contain)
        .accessibilityValue("\(minutes) minutes")
    }
}
