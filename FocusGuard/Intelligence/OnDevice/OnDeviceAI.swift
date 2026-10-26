import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Pro AI runs on Apple's on-device model (FoundationModels, macOS 26 with
/// Apple Intelligence): nothing leaves the Mac. Features ask it through
/// `OnDeviceModel`, so tests can pass a fake, and fall back to doing things
/// by hand when it isn't available.
enum OnDeviceAI {
    enum Availability: Equatable {
        case available
        /// Before macOS 26, or a Mac that can't run Apple Intelligence.
        case unsupported
        /// Apple Intelligence is off in System Settings.
        case turnedOff
        /// The model is still downloading or getting ready.
        case notReady
    }

    static var availability: Availability {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ai.debugUnavailable") { return .unsupported }
        #endif
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.appleIntelligenceNotEnabled): return .turnedOff
            case .unavailable(.modelNotReady): return .notReady
            case .unavailable: return .unsupported
            }
        }
        #endif
        return .unsupported
    }

    static var isAvailable: Bool { availability == .available }

    /// What a feature shows while the model isn't available.
    static let unavailableNote = "Needs Apple Intelligence (macOS 26)"

    /// Apple's model, or nil while it isn't available.
    static func model() -> (any OnDeviceModel)? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), isAvailable { return SystemOnDeviceModel() }
        #endif
        return nil
    }
}

/// The model as features see it. Each call is one question with its own
/// instructions; the answer comes back as JSON in the shape asked for.
protocol OnDeviceModel: Sendable {
    func respond(instructions: String, prompt: String, shape: AnswerShape) async throws -> String
}

extension OnDeviceModel {
    /// Asks once and decodes the answer.
    func respond<Answer: Decodable>(_ type: Answer.Type, instructions: String, prompt: String,
                                    shape: AnswerShape) async throws -> Answer {
        let json = try await respond(instructions: instructions, prompt: prompt, shape: shape)
        do {
            return try JSONDecoder().decode(Answer.self, from: Data(json.utf8))
        } catch {
            throw OnDeviceAIError.unreadableAnswer
        }
    }
}

enum OnDeviceAIError: Error {
    case unreadableAnswer
}

/// What the answer looks like. The model fills it in (guided generation)
/// instead of writing free text, so it always parses.
indirect enum AnswerShape: Sendable {
    /// Free text.
    case text
    /// One of these words.
    case choice([String])
    /// A whole number in the range.
    case number(ClosedRange<Int>)
    /// A list with this many items.
    case list(of: AnswerShape, count: ClosedRange<Int>)
    /// Named fields, each saying what goes in it.
    case object([Field])

    struct Field: Sendable {
        let name: String
        let description: String
        let shape: AnswerShape

        init(_ name: String, _ description: String, _ shape: AnswerShape) {
            self.name = name
            self.description = description
            self.shape = shape
        }
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
private struct SystemOnDeviceModel: OnDeviceModel {
    func respond(instructions: String, prompt: String, shape: AnswerShape) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let schema = try GenerationSchema(root: shape.schema(named: "Answer"), dependencies: [])
        let response = try await session.respond(to: prompt, schema: schema, includeSchemaInPrompt: true,
                                                 options: GenerationOptions(temperature: 0.3))
        return response.content.jsonString
    }
}

@available(macOS 26, *)
private extension AnswerShape {
    /// Objects and choices need names unique in the schema; the path gives them.
    func schema(named name: String) -> DynamicGenerationSchema {
        switch self {
        case .text:
            return DynamicGenerationSchema(type: String.self)
        case .choice(let words):
            return DynamicGenerationSchema(name: name, anyOf: words)
        case .number(let range):
            return DynamicGenerationSchema(type: Int.self, guides: [.range(range)])
        case .list(let item, let count):
            return DynamicGenerationSchema(arrayOf: item.schema(named: name + "Item"),
                                           minimumElements: count.lowerBound, maximumElements: count.upperBound)
        case .object(let fields):
            return DynamicGenerationSchema(name: name, properties: fields.map { field in
                DynamicGenerationSchema.Property(name: field.name, description: field.description,
                                                 schema: field.shape.schema(named: name + "_" + field.name))
            })
        }
    }
}
#endif
