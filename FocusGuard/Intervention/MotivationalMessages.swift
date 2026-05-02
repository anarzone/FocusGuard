import Foundation

enum MotivationalMessages {
    static let lines: [String] = [
        "5 more minutes — you've got this.",
        "Refocus. Your future self will thank you.",
        "One more push. Progress over perfection.",
        "You started for a reason. Pick it back up.",
        "Distractions wait. Your goals don't.",
        "Deep work pays. Surface scrolling doesn't.",
        "Close the tab. Open the doc.",
        "Come back to it — you were almost there.",
    ]

    static func random() -> String {
        lines.randomElement() ?? "Refocus."
    }
}
