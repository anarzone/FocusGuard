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
    static var unavailableNote: String {
        isAvailable && !writesAppLanguage ? String(localized: "Apple Intelligence doesn't write in this language yet")
            : String(localized: "Needs Apple Intelligence (macOS 26)")
    }

    /// Apple's model, or nil while it isn't available. For sorting, which
    /// needs no words from it; anything people read goes through `writer`.
    static func model() -> (any OnDeviceModel)? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), isAvailable { return SystemOnDeviceModel() }
        #endif
        return nil
    }

    /// Apple's model when it can write in the app's language, or nil, and
    /// then a feature keeps its template words. So English never shows up
    /// in an app running in a language the model doesn't have.
    static func writer() -> (any OnDeviceModel)? {
        writesAppLanguage ? model() : nil
    }

    /// The language the app runs in, the Mac's or the one picked for it in
    /// System Settings; English when it has no translation for the Mac's.
    static var appLanguage: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// Whether the model can write in the app's language. Azerbaijani isn't
    /// among Apple Intelligence's languages; its templates are used instead.
    static var writesAppLanguage: Bool {
        if appLanguage == "en" { return true }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return SystemLanguageModel.default.supportsLocale(Locale(identifier: appLanguage))
        }
        #endif
        return false
    }

    /// Added to the model's instructions to get its words in the app's
    /// language. Nothing in English, so those answers stay as they are.
    static var languageInstruction: String {
        guard appLanguage != "en", writesAppLanguage,
              let name = Locale(identifier: "en").localizedString(forLanguageCode: appLanguage) else { return "" }
        return " You MUST respond in \(name)."
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
        let session = LanguageModelSession(instructions: instructions + OnDeviceAI.languageInstruction)
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
