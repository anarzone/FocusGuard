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

/// How an Anthropic request authenticates. Other providers are API-key only.
enum AnthropicAuthMode: String, CaseIterable, Identifiable, Sendable {
    case apiKey
    case subscription

    var id: String { rawValue }
    var label: String {
        switch self {
        case .apiKey:       return "API key"
        case .subscription: return "Subscription token"
        }
    }
}

/// User-configurable AI settings. Non-secret fields are backed by UserDefaults;
/// the secret is fetched from the Keychain on demand via `keychainAccount`.
struct AISettings: Equatable {
    var enabled: Bool
    var provider: ProviderKind
    var model: String
    var baseURL: String
    var anthropicAuth: AnthropicAuthMode

    static func load(_ defaults: UserDefaults = .standard) -> AISettings {
        let provider = ProviderKind(rawValue: defaults.string(forKey: SettingsKeys.AI.provider) ?? "")
            ?? .anthropic
        let auth = AnthropicAuthMode(rawValue: defaults.string(forKey: SettingsKeys.AI.anthropicAuth) ?? "")
            ?? .apiKey
        let model = defaults.string(forKey: SettingsKeys.AI.model).flatMap { $0.isEmpty ? nil : $0 }
            ?? provider.defaultModel
        let baseURL = defaults.string(forKey: SettingsKeys.AI.baseURL).flatMap { $0.isEmpty ? nil : $0 }
            ?? OpenAIProvider.defaultBaseURL
        return AISettings(
            enabled: defaults.bool(forKey: SettingsKeys.AI.enabled),
            provider: provider,
            model: model,
            baseURL: baseURL,
            anthropicAuth: auth
        )
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: SettingsKeys.AI.enabled)
        defaults.set(provider.rawValue, forKey: SettingsKeys.AI.provider)
        defaults.set(model, forKey: SettingsKeys.AI.model)
        defaults.set(baseURL, forKey: SettingsKeys.AI.baseURL)
        defaults.set(anthropicAuth.rawValue, forKey: SettingsKeys.AI.anthropicAuth)
    }

    /// Keychain account for the current provider/auth combination. Distinct
    /// accounts mean switching providers doesn't overwrite another's secret.
    var keychainAccount: String {
        switch provider {
        case .anthropic:        return "anthropic.\(anthropicAuth.rawValue)"
        case .openAI:           return "openai"
        case .openAICompatible: return "openai-compatible"
        }
    }

    /// Whether a usable secret is present for the current selection.
    var hasSecret: Bool { KeychainStore.has(account: keychainAccount) }

    /// Builds the concrete provider for the current settings + stored secret.
    /// Returns nil only when no secret is stored (surface as missingCredential).
    func makeProvider(session: URLSession = .shared) -> LLMProvider? {
        let secret = KeychainStore.get(account: keychainAccount) ?? ""
        guard !secret.isEmpty else { return nil }
        switch provider {
        case .anthropic:
            let auth: AnthropicProvider.Auth = anthropicAuth == .subscription
                ? .subscription(token: secret)
                : .apiKey(secret)
            return AnthropicProvider(model: model, auth: auth, session: session)
        case .openAI:
            return OpenAIProvider(model: model, apiKey: secret,
                                  baseURL: OpenAIProvider.defaultBaseURL, session: session)
        case .openAICompatible:
            return OpenAIProvider(model: model, apiKey: secret,
                                  baseURL: baseURL, session: session)
        }
    }
}
