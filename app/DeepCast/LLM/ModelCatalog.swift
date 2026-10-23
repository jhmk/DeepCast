import Foundation

enum ModelProvider: String, Codable, Sendable, CaseIterable {
    case openRouter = "openrouter"
    case google
    case apple

    var label: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .google: "Google AI Studio"
        case .apple: "Apple"
        }
    }

    var keyAccount: KeychainStore.Account? {
        switch self {
        case .openRouter: .openRouter
        case .google: .googleAI
        case .apple: nil
        }
    }
}

/// A model at a provider. Stored as "provider|model" in UserDefaults.
struct ModelRef: Hashable, Codable, Sendable, Identifiable {
    var provider: ModelProvider
    var model: String

    var id: String { storage }
    var storage: String { "\(provider.rawValue)|\(model)" }

    static let apple = ModelRef(provider: .apple, model: "apple-on-device")

    /// Parses the storage format, plus legacy values from earlier builds
    /// ("qwen/qwen3.8-27b:free" = OpenRouter, "gemini-…" without slash = Google).
    init?(storage: String) {
        let value = storage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
        if parts.count == 2, let provider = ModelProvider(rawValue: parts[0]), !parts[1].isEmpty {
            self.init(provider: provider, model: parts[1])
        } else if value == "apple-on-device" {
            self = .apple
        } else {
            self.init(provider: value.contains("/") ? .openRouter : .google, model: value)
        }
    }

    init(provider: ModelProvider, model: String) {
        self.provider = provider
        self.model = model
    }

    var displayName: String {
        switch provider {
        case .apple: "Apple Intelligence"
        case .openRouter: (model.split(separator: "/").last.map(String.init) ?? model).replacingOccurrences(of: ":free", with: "")
        case .google: model
        }
    }

    /// ID as recorded by the router (`LLMClient.id`), used to label verdicts.
    var clientID: String {
        switch provider {
        case .apple: "apple-on-device"
        case .openRouter: model
        case .google: "google/\(model)"
        }
    }
}

/// Free models offered in Settings. A curated list ships with the app; "Liste aktualisieren"
/// adds the current free models from the providers (only on user request).
enum ModelCatalog {
    static let curated: [ModelRef] = [
        ModelRef(provider: .openRouter, model: "qwen/qwen3.8-27b:free"),
        ModelRef(provider: .openRouter, model: "google/gemma-4-31b-it:free"),
        ModelRef(provider: .openRouter, model: "google/gemma-4-26b-a4b-it:free"),
        ModelRef(provider: .google, model: "gemini-3.5-flash-lite"),
        ModelRef(provider: .google, model: "gemini-3.8-flash"),
        ModelRef(provider: .google, model: "gemma-4-31b-it"),
        .apple,
    ]

    /// Only text models that are free: OpenRouter ":free" variants with price 0; Google models
    /// with generateContent (free tier), excluding audio/image/live/tts/embedding variants.
    static func fetchFreeModels(googleKey: String?, session: URLSession = .shared) async -> [ModelRef] {
        var result: [ModelRef] = []
        if let (data, _) = try? await session.data(from: URL(string: "https://openrouter.ai/api/v1/models")!) {
            result += parseOpenRouter(data)
        }
        if let googleKey {
            var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")!)
            request.setValue(googleKey, forHTTPHeaderField: "x-goog-api-key")
            if let (data, _) = try? await session.data(for: request) { result += parseGoogle(data) }
        }
        return result
    }

    static func parseOpenRouter(_ data: Data) -> [ModelRef] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else { return [] }
        return models.compactMap { model in
            guard let id = model["id"] as? String, id.hasSuffix(":free"),
                  let pricing = model["pricing"] as? [String: Any],
                  Double("\(pricing["prompt"] ?? "1")") == 0, Double("\(pricing["completion"] ?? "1")") == 0 else { return nil }
            let modality = ((model["architecture"] as? [String: Any])?["output_modalities"] as? [String]) ?? ["text"]
            guard modality.contains("text") else { return nil }
            return ModelRef(provider: .openRouter, model: id)
        }.sorted { $0.model < $1.model }
    }

    static func parseGoogle(_ data: Data) -> [ModelRef] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        let excluded = ["tts", "image", "audio", "live", "embedding", "omni", "robotics", "computer-use", "aqa"]
        return models.compactMap { model in
            guard let name = (model["name"] as? String)?.replacingOccurrences(of: "models/", with: ""),
                  (model["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true,
                  name.hasPrefix("gemini") || name.hasPrefix("gemma"),
                  !excluded.contains(where: name.contains) else { return nil }
            return ModelRef(provider: .google, model: name)
        }.sorted { $0.model < $1.model }
    }

    /// Result of the startup check: chosen models that no longer exist, with a suggestion.
    struct Availability: Equatable, Sendable {
        var missing: [(role: String, model: ModelRef, replacement: ModelRef?)] = []
        var message: String? {
            guard !missing.isEmpty else { return nil }
            return missing.map { item in
                let suggestion = item.replacement.map { " – Vorschlag: \($0.displayName)" } ?? ""
                return "\(item.role) „\(item.model.displayName)“ ist nicht mehr verfügbar\(suggestion)."
            }.joined(separator: " ")
        }

        static func == (lhs: Availability, rhs: Availability) -> Bool {
            lhs.missing.map { "\($0.role)\($0.model.storage)\($0.replacement?.storage ?? "")" }
                == rhs.missing.map { "\($0.role)\($0.model.storage)\($0.replacement?.storage ?? "")" }
        }
    }

    /// Checks chosen models against a fetched list. Only providers that returned models are judged
    /// (no key or offline = no verdict). Apple is always available.
    static func check(selected: [(role: String, model: ModelRef)], fetched: [ModelRef]) -> Availability {
        let providers = Set(fetched.map(\.provider))
        var result = Availability()
        for (role, model) in selected where model.provider != .apple && providers.contains(model.provider) {
            guard !fetched.contains(model) else { continue }
            let replacement = curated.first { $0.provider == model.provider && $0 != model && fetched.contains($0) }
                ?? fetched.first { $0.provider == model.provider }
            result.missing.append((role, model, replacement))
        }
        return result
    }

    /// Curated first, then fetched, without duplicates.
    static func merged(_ fetched: [ModelRef]) -> [ModelRef] {
        var seen = Set<String>()
        return (curated + fetched).filter { seen.insert($0.storage).inserted }
    }
}
