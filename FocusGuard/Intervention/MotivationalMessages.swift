import Foundation

enum MotivationalMessages {
    static let lines: [String] = [
        String(localized: "5 more minutes — you've got this."),
        String(localized: "Refocus. Your future self will thank you."),
        String(localized: "One more push. Progress over perfection."),
        String(localized: "You started for a reason. Pick it back up."),
        String(localized: "Distractions wait. Your goals don't."),
        String(localized: "Deep work pays. Surface scrolling doesn't."),
        String(localized: "Close the tab. Open the doc."),
        String(localized: "Come back to it — you were almost there."),
    ]

    static func random() -> String {
        lines.randomElement() ?? String(localized: "Refocus.")
    }
}
