#!/usr/bin/env bash
#
# Measures the running FocusGuard's CPU time and wakeups over a stretch of
# time, read-only: it never launches, quits or touches the app. Note what
# you were doing meanwhile (a session or not, the menu or window open),
# since that sets the pace (see TrackingCadence).
#
# Usage:  ./scripts/measure-energy.sh [seconds]     (default 120)
#
# Prints CPU seconds per minute, idle wakeups and interrupt wakeups per
# second, from the kernel's accounting (proc_pid_rusage), plus the app's own
# windows on screen. The app's diagnostics report (Settings › Privacy ›
# Send diagnostics) shows the same counters per hour since launch.
#
set -euo pipefail

seconds="${1:-120}"
pid="$(pgrep -x FocusGuard | head -1 || true)"
if [[ -z "$pid" ]]; then
    echo "FocusGuard isn't running; start it yourself first." >&2
    exit 1
fi
echo "FocusGuard pid $pid, up $(ps -o etime= -p "$pid" | xargs), sampling ${seconds}s…"

xcrun swift - "$pid" "$seconds" <<'SWIFT'
import CoreGraphics
import Darwin
import Foundation

let pid = pid_t(CommandLine.arguments[1])!
let seconds = Double(CommandLine.arguments[2])!

func sample() -> rusage_info_v4 {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    guard result == 0 else { fatalError("proc_pid_rusage failed: \(errno)") }
    return info
}

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func secs(_ mach: UInt64) -> Double { Double(mach) * Double(timebase.numer) / Double(timebase.denom) / 1e9 }

let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
    .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
print("main window on screen: \(windows.isEmpty ? "no" : "yes")")

let a = sample()
let start = Date()
Thread.sleep(forTimeInterval: seconds)
let b = sample()
let elapsed = Date().timeIntervalSince(start)
let cpu = secs(b.ri_user_time + b.ri_system_time) - secs(a.ri_user_time + a.ri_system_time)
print(String(format: "CPU:               %.2f s per minute (%.1f%% of a core)", cpu / elapsed * 60, cpu / elapsed * 100))
print(String(format: "idle wakeups:      %.2f per second", Double(b.ri_pkg_idle_wkups - a.ri_pkg_idle_wkups) / elapsed))
print(String(format: "interrupt wakeups: %.2f per second", Double(b.ri_interrupt_wkups - a.ri_interrupt_wkups) / elapsed))
SWIFT
