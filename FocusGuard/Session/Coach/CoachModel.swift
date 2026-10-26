import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The model the coach rewords its note with: Apple's on-device model, on
/// macOS 26 with Apple Intelligence on. Nothing leaves the Mac. Elsewhere
/// there's none, and the note keeps its template words.
enum CoachModels {
    static var onDevice: CoachLanguageModel? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return OnDeviceCoachModel() }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
struct OnDeviceCoachModel: CoachLanguageModel {
    func respond(to prompt: String, instructions: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        return try? await session.respond(to: prompt).content
    }
}
#endif
