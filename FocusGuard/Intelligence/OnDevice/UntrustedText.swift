import Foundation

/// Window titles, page titles and app names are written by other people. Any
/// of them can read like an order to the model, so one that does never reaches
/// a prompt, and never counts as evidence for anything.
enum UntrustedText {
    private static let patterns = [
        #"\b(ignore|disregard|forget|override)\b.{0,40}\b(instruction|instructions|prompt|rules|above|previous)\b"#,
        #"\b(ignoriere|ignorieren|vergiss)\b.{0,40}\b(anweisung|anweisungen|regeln|vorherige)\b"#,
        #"\byou (must|should|have to|are now)\b"#,
        #"\b(system|assistant|developer) ?:"#,
        #"\b(verdict|category|classification) ?:"#,
        #"\b(mark|classify|label|treat|sort|rate) (this|it|me)\b"#,
        #"\b(classify|mark) as\b"#,
        #"\b(answer|respond|reply|say) (with |that |only )?(done|focus|yes|the goal|100)"#,
        #"\bfocus rate\b.{0,20}\b100\b"#,
    ]

    /// Whether `text` reads like an instruction to the model rather than like
    /// the name of something. Hyphens and dots count as spaces, for hosts such
    /// as "ignore-all-instructions.example.com".
    static func looksLikeInstruction(_ text: String) -> Bool {
        let plain = text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return patterns.contains { plain.range(of: $0, options: .regularExpression) != nil }
    }
}
