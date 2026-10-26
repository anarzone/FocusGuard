import Foundation
@testable import FocusGuard

/// Stands in for Apple's on-device model: records each question and
/// answers with whatever JSON `reply` makes from it, on the main actor.
@MainActor
final class FakeOnDeviceModel: OnDeviceModel {
    struct Request {
        let instructions: String
        let prompt: String
        let shape: AnswerShape
    }

    private(set) var requests: [Request] = []
    var reply: (Request) throws -> String

    init(reply: @escaping (Request) throws -> String) {
        self.reply = reply
    }

    func respond(instructions: String, prompt: String, shape: AnswerShape) async throws -> String {
        let request = Request(instructions: instructions, prompt: prompt, shape: shape)
        requests.append(request)
        return try reply(request)
    }

    /// The ids and names in a numbered prompt: "a1. App: Figma · …".
    nonisolated static func items(in prompt: String) -> [(id: String, name: String)] {
        prompt.split(separator: "\n").compactMap { line in
            guard let match = line.firstMatch(of: /^([av]\d+)\. (?:App: |Website: )?(.+?)(?: · |$)/) else { return nil }
            var name = String(match.2)
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "“”"))
            return (String(match.1), name)
        }
    }

    nonisolated static func json(_ value: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
