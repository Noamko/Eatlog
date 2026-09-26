import Foundation
import Observation

enum AIProvider: String, CaseIterable, Identifiable {
    case openAI = "openai"
    case gemini = "gemini"
    case claude = "claude"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        }
    }

    var keychainAccount: String { rawValue + "-api-key" }
    var modelKey: String { rawValue + "-model" }
    var modelsCacheKey: String { rawValue + "-available-models" }

    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .gemini: return "gemini-3.5-flash"
        case .claude: return "claude-opus-5"
        }
    }

    /// Shown until the account's real model list has been fetched with an API key.
    var fallbackModels: [String] {
        switch self {
        case .openAI:
            return [
                "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano",
                "gpt-4o", "gpt-4o-mini",
                "gpt-5", "gpt-5-mini", "gpt-5-nano",
            ]
        case .gemini:
            return [
                "gemini-3.5-flash", "gemini-3.5-flash-lite", "gemini-3.8-flash",
            ]
        case .claude:
            return [
                "claude-haiku-4-5", "claude-opus-5", "claude-sonnet-5",
            ]
        }
    }
}

@Observable
final class AppSettings {
    private static let providerKey = "ai-provider"
    private static let webSearchKey = "openai-web-search"

    var provider: AIProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey) }
    }

    var useWebSearch: Bool {
        didSet { UserDefaults.standard.set(useWebSearch, forKey: Self.webSearchKey) }
    }

    // Per-provider state, so switching providers never loses keys or model choices.
    private var keys: [AIProvider: String]
    private var models: [AIProvider: String]
    private var modelLists: [AIProvider: [String]]

    var apiKey: String {
        get { keys[provider] ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            keys[provider] = trimmed
            if trimmed.isEmpty {
                KeychainStore.delete(provider.keychainAccount)
            } else {
                KeychainStore.set(trimmed, account: provider.keychainAccount)
            }
        }
    }

    var model: String {
        get { models[provider] ?? provider.defaultModel }
        set {
            models[provider] = newValue
            UserDefaults.standard.set(newValue, forKey: provider.modelKey)
        }
    }

    var availableModels: [String] {
        get { modelLists[provider] ?? provider.fallbackModels }
        set {
            modelLists[provider] = newValue
            UserDefaults.standard.set(newValue, forKey: provider.modelsCacheKey)
        }
    }

    var hasAPIKey: Bool {
        hasAPIKey(for: provider)
    }

    /// Whether the active provider can run an analysis right now — via a saved
    /// key, or keylessly through Firebase for Gemini.
    var canAnalyze: Bool {
        hasAPIKey || (provider == .gemini && FirebaseGeminiClient.isAvailable)
    }

    func model(for provider: AIProvider) -> String {
        models[provider] ?? provider.defaultModel
    }

    func hasAPIKey(for provider: AIProvider) -> Bool {
        !(keys[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: Self.providerKey) ?? "") ?? .openAI
        useWebSearch = UserDefaults.standard.object(forKey: Self.webSearchKey) as? Bool ?? true
        var keys: [AIProvider: String] = [:]
        var models: [AIProvider: String] = [:]
        var modelLists: [AIProvider: [String]] = [:]
        for provider in AIProvider.allCases {
            keys[provider] = KeychainStore.get(provider.keychainAccount) ?? ""
            models[provider] = UserDefaults.standard.string(forKey: provider.modelKey) ?? provider.defaultModel
            modelLists[provider] = UserDefaults.standard.stringArray(forKey: provider.modelsCacheKey) ?? provider.fallbackModels
        }
        // Gemini flash models below 3.5 are retired from the picker; migrate any
        // cached list or stored selection that still references one.
        if let cached = modelLists[.gemini] {
            let filtered = cached.filter(GeminiClient.meetsVersionPolicy)
            let sanitized = filtered.isEmpty ? AIProvider.gemini.fallbackModels : filtered
            modelLists[.gemini] = sanitized
            UserDefaults.standard.set(sanitized, forKey: AIProvider.gemini.modelsCacheKey)
        }
        if let stored = models[.gemini], !GeminiClient.meetsVersionPolicy(stored) {
            models[.gemini] = AIProvider.gemini.defaultModel
            UserDefaults.standard.set(AIProvider.gemini.defaultModel, forKey: AIProvider.gemini.modelKey)
        }
        self.keys = keys
        self.models = models
        self.modelLists = modelLists
    }

    @MainActor
    func refreshAvailableModels() async throws {
        let provider = provider
        let list = try await client().listModels()
        guard !list.isEmpty else { return }
        modelLists[provider] = list
        UserDefaults.standard.set(list, forKey: provider.modelsCacheKey)
    }

    func client() -> any AnalysisClient {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .openAI:
            return OpenAIClient(apiKey: key, model: model, useWebSearch: useWebSearch)
        case .gemini:
            if key.isEmpty && FirebaseGeminiClient.isAvailable {
                return FirebaseGeminiClient(model: model, useWebSearch: useWebSearch)
            }
            return GeminiClient(apiKey: key, model: model, useWebSearch: useWebSearch)
        case .claude:
            return ClaudeClient(apiKey: key, model: model, useWebSearch: useWebSearch)
        }
    }
}
