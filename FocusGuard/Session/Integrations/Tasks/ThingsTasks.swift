import AppKit
import Foundation

/// To-dos in Things' Today list, read with AppleScript while Things is
/// open (it's never opened just to read). No account: macOS asks once
/// whether FocusGuard may control Things. Scripts run off the main thread
/// (`AppleScript`).
final class ThingsTasks: TaskStore {
    static let bundleID = "com.culturedcode.ThingsMac"

    let source = TaskSource.things

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func openTasks() async throws -> [TaskItem] {
        guard Self.isRunning else { throw TaskSourceProblem.unreachable }
        switch await AppleScript.run(ThingsScripts.today) {
        case .output(let text): return ThingsScripts.parse(text, now: .now)
        case .notAuthorized:    throw TaskSourceProblem.notAllowed
        default:                throw TaskSourceProblem.unreachable
        }
    }

    func setCompleted(_ task: TaskItem, _ completed: Bool) async -> Bool {
        await AppleScript.run(ThingsScripts.setStatus(of: task.id, completed: completed)) == .output("ok")
    }
}

/// The AppleScript FocusGuard sends Things, and reading what comes back.
enum ThingsScripts {
    /// Between a to-do's fields, and between to-dos: control characters
    /// no title has.
    static let field: Character = "\u{1F}"
    static let record: Character = "\u{1E}"
    /// At most this many are read.
    static let limit = 50

    /// The open to-dos in Today (not projects): id, name, project or area,
    /// deadline and when it was made, a line each. "Today" is found by its
    /// id, so it works in any language.
    static let today = """
    on stamp(d)
        if d is missing value then return ""
        return ((year of d) as text) & "-" & ((month of d as integer) as text) & "-" & ((day of d) as text) & "-" & ((time of d) as text)
    end stamp

    set fs to character id 31
    set rs to character id 30
    set out to ""
    set n to 0
    tell application id "\(ThingsTasks.bundleID)"
        repeat with t in to dos of list id "TMTodayListSource"
            if n ≥ \(limit) then exit repeat
            try
                if completion date of t is missing value and cancellation date of t is missing value and class of t is not project then
                    set place to ""
                    try
                        set place to name of project of t
                    end try
                    if class of place is not text or place is "" then
                        set place to ""
                        try
                            set place to name of area of t
                        end try
                    end if
                    if class of place is not text then set place to ""
                    set out to out & (id of t) & fs & (name of t) & fs & place & fs & my stamp(due date of t) & fs & my stamp(creation date of t) & rs
                    set n to n + 1
                end if
            end try
        end repeat
    end tell
    return out
    """

    /// Ticks a to-do off, or opens it again.
    static func setStatus(of id: String, completed: Bool) -> String {
        """
        tell application id "\(ThingsTasks.bundleID)"
            set status of to do id "\(quoted(id))" to \(completed ? "completed" : "open")
        end tell
        return "ok"
        """
    }

    /// Safe inside a string literal in a script.
    static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// `today`'s output as tasks. Everything in Today is for today: one
    /// with an earlier deadline is overdue.
    static func parse(_ output: String, now: Date, calendar: Calendar = .current) -> [TaskItem] {
        let startOfToday = calendar.startOfDay(for: now)
        return output.split(separator: record).compactMap { line in
            let fields = line.split(separator: field, omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard fields.count >= 5, !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
            let deadline = date(fields[3], calendar: calendar)
            return TaskItem(source: .things, id: fields[0], title: fields[1], list: fields[2],
                            due: deadline.map { min($0, startOfToday) } ?? startOfToday,
                            created: date(fields[4], calendar: calendar))
        }
    }

    /// "2026-10-26-34200": the date, and seconds into the day.
    static func date(_ stamp: String, calendar: Calendar = .current) -> Date? {
        let parts = stamp.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 4,
              let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return day.addingTimeInterval(TimeInterval(parts[3]))
    }
}
