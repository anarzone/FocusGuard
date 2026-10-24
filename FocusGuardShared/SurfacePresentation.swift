import Foundation

/// How the widgets and the control put times into words.
enum SurfaceWords {
    /// "2h 15m", "45m", "4h".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// "18 min", rounded up so time left never reads 0 early.
    static func minutesLeft(_ seconds: TimeInterval) -> String {
        "\(seconds <= 0 ? 0 : Int((seconds / 60).rounded(.up))) min"
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "18:24", for a paused session, which doesn't count down.
    static func stopwatch(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// What the Control Center control shows.
struct FocusControlValue: Equatable {
    let isOn: Bool
    let title: String
    let detail: String
    /// SF Symbol for the shield's state.
    let symbol: String

    static func from(_ snapshot: SurfaceSnapshot?, at date: Date) -> FocusControlValue {
        guard let snapshot else {
            return FocusControlValue(isOn: false, title: "FocusGuard", detail: "Start 50 min", symbol: "shield")
        }
        switch snapshot.phase {
        case .ready:
            return FocusControlValue(isOn: false, title: "FocusGuard", detail: "Start \(snapshot.usualMinutes) min",
                                     symbol: "shield")
        case .focusing, .paused:
            let detail: String
            if snapshot.phase == .paused {
                detail = "Paused"
            } else if let left = snapshot.timeLeft(at: date) {
                detail = "\(SurfaceWords.minutesLeft(left)) left"
            } else {
                detail = "\(Int(snapshot.running(at: date) / 60)) min so far"
            }
            return FocusControlValue(isOn: true, title: snapshot.session?.name ?? "Focusing", detail: detail,
                                     symbol: snapshot.phase == .paused ? "pause.circle" : "shield.lefthalf.filled")
        case .onBreak:
            let detail = snapshot.onBreak.map { "back at \(SurfaceWords.clock($0.endsAt))" } ?? "On a break"
            return FocusControlValue(isOn: true, title: "Break", detail: detail, symbol: "cup.and.saucer")
        }
    }
}

extension SurfaceSnapshot {
    /// What flipping the control asks for: on starts a session of the
    /// usual length; off ends the session, or a break that may end early.
    static func controlAction(turningOn: Bool, snapshot: SurfaceSnapshot?) -> SurfaceCommand.Action? {
        let phase = snapshot?.phase ?? .ready
        switch (turningOn, phase) {
        case (true, .ready):    return .start(minutes: snapshot?.usualMinutes ?? 50)
        case (true, _):         return nil
        case (false, .onBreak): return snapshot?.onBreak?.canEndEarly == false ? nil : .endBreak
        case (false, .ready):   return nil
        case (false, _):        return .end
        }
    }

    /// When a widget timeline needs an entry: now, every minute of the
    /// next hour while a session or a break runs, the moment it ends, and
    /// midnight.
    func timelineDates(now: Date, calendar: Calendar = .current) -> [Date] {
        var dates = [now]
        let end: Date?
        switch phase {
        case .focusing:       end = sessionEndsAt ?? now.addingTimeInterval(60 * 60)
        case .onBreak:        end = onBreak?.endsAt
        case .ready, .paused: end = nil
        }
        let horizon = now.addingTimeInterval(60 * 60)
        if let end, end > now {
            var next = now.addingTimeInterval(60)
            while next < min(end, horizon) {
                dates.append(next)
                next = next.addingTimeInterval(60)
            }
            if end <= horizon { dates.append(end) }
        }
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            dates.append(midnight)
        }
        return Array(Set(dates)).sorted()
    }
}
