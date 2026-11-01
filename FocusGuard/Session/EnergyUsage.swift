import Darwin
import Foundation

/// What this run of the app has cost the Mac: CPU time and wakeups since
/// launch, per hour awake, for the diagnostics report. Read from the
/// kernel's own accounting (`proc_pid_rusage`), so it measures the app as
/// it really runs, with no profiler attached. An app that runs all day
/// should spend a few seconds of CPU an hour and wake the Mac rarely.
struct EnergyUsage: Equatable {
    /// CPU time used, user and system.
    let cpuSeconds: TimeInterval
    /// Times the app woke the processor package from idle — what costs
    /// battery on an otherwise quiet Mac.
    let idleWakeups: UInt64
    /// Interrupt wakeups: timers and other interrupts that ran the app.
    let interruptWakeups: UInt64
    /// Time since launch with the Mac awake; nothing runs during sleep.
    let awakeSeconds: TimeInterval

    /// This process since launch; nil if the kernel won't say.
    static func sinceLaunch() -> EnergyUsage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        // Both counted in Mach time, which stops while the Mac sleeps.
        let now = mach_absolute_time()
        return EnergyUsage(
            cpuSeconds: seconds(machTime: info.ri_user_time + info.ri_system_time),
            idleWakeups: info.ri_pkg_idle_wkups,
            interruptWakeups: info.ri_interrupt_wkups,
            awakeSeconds: seconds(machTime: now > info.ri_proc_start_abstime ? now - info.ri_proc_start_abstime : 0)
        )
    }

    /// `count` per hour of `duration`; nil under a minute, too short to say.
    static func perHour(_ count: Double, over duration: TimeInterval) -> Double? {
        guard duration >= 60 else { return nil }
        return count * 3600 / duration
    }

    var cpuSecondsPerHour: Double? { Self.perHour(cpuSeconds, over: awakeSeconds) }
    var idleWakeupsPerHour: Double? { Self.perHour(Double(idleWakeups), over: awakeSeconds) }
    var interruptWakeupsPerHour: Double? { Self.perHour(Double(interruptWakeups), over: awakeSeconds) }

    /// The diagnostics report's rows.
    var rows: [(String, String)] {
        func rate(_ value: Double?, _ format: String) -> String {
            value.map { String(format: format, $0) + " per hour" } ?? "too early to tell"
        }
        return [
            ("Awake since launch", String(format: "%.1f h", awakeSeconds / 3600)),
            ("CPU", rate(cpuSecondsPerHour, "%.1f s") + String(format: " (%.0f s in all)", cpuSeconds)),
            ("Idle wakeups", rate(idleWakeupsPerHour, "%.0f") + " (\(idleWakeups) in all)"),
            ("Interrupt wakeups", rate(interruptWakeupsPerHour, "%.0f") + " (\(interruptWakeups) in all)"),
        ]
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func seconds(machTime: UInt64) -> TimeInterval {
        Double(machTime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}
