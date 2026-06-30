import Foundation

/// Which LLM backend the insights feature talks to.
enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openAI
    case openAICompatible

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic:        return "Anthropic (Claude)"
        case .openAI:           return "OpenAI"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic:                  return AnthropicProvider.defaultModel
        case .openAI, .openAICompatible:  return OpenAIProvider.defaultModel
        }
    }
}

/// User-configurable AI settings. Non-secret fields are backed by UserDefaults;
/// the secret (an API key) is fetched from the Keychain on demand via
/// `keychainAccount`. All providers authenticate with an API key.
struct AISettings: Equatable {
    var enabled: Bool
    var provider: ProviderKind
    var model: String
    var baseURL: String

    static func load(_ defaults: UserDefaults = .standard) -> AISettings {
        let provider = ProviderKind(rawValue: defaults.string(forKey: SettingsKeys.AI.provider) ?? "")
            ?? .anthropic
        let model = defaults.string(forKey: SettingsKeys.AI.model).flatMap { $0.isEmpty ? nil : $0 }
            ?? provider.defaultModel
        let baseURL = defaults.string(forKey: SettingsKeys.AI.baseURL).flatMap { $0.isEmpty ? nil : $0 }
            ?? OpenAIProvider.defaultBaseURL
        return AISettings(
            enabled: defaults.bool(forKey: SettingsKeys.AI.enabled),
            provider: provider,
            model: model,
            baseURL: baseURL
        )
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: SettingsKeys.AI.enabled)
        defaults.set(provider.rawValue, forKey: SettingsKeys.AI.provider)
        defaults.set(model, forKey: SettingsKeys.AI.model)
        defaults.set(baseURL, forKey: SettingsKeys.AI.baseURL)
    }

    /// Keychain account for the current provider's API key. Distinct accounts
    /// mean switching providers doesn't overwrite another's key. (The Anthropic
    /// account keeps its historical ".apiKey" suffix so existing saved keys
    /// survive the removal of the subscription option.)
    var keychainAccount: String {
        switch provider {
        case .anthropic:        return "anthropic.apiKey"
        case .openAI:           return "openai"
        case .openAICompatible: return "openai-compatible"
        }
    }

    /// Whether a usable API key is present for the current selection.
    var hasSecret: Bool { KeychainStore.has(account: keychainAccount) }

    /// Builds the concrete provider for the current settings + stored key.
    /// Returns nil only when no key is stored (surface as missingCredential).
    func makeProvider(session: URLSession = .shared) -> LLMProvider? {
        let key = KeychainStore.get(account: keychainAccount) ?? ""
        guard !key.isEmpty else { return nil }
        switch provider {
        case .anthropic:
            return AnthropicProvider(model: model, apiKey: key, session: session)
        case .openAI:
            return OpenAIProvider(model: model, apiKey: key,
                                  baseURL: OpenAIProvider.defaultBaseURL, session: session)
        case .openAICompatible:
            return OpenAIProvider(model: model, apiKey: key, baseURL: baseURL, session: session)
        }
    }
}
