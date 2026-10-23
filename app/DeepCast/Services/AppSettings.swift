import Foundation
import Observation

/// Global speech mode. "Fish with Apple fallback" is the default.
enum SpeechMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case fishWithAppleFallback
    case appleOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fishWithAppleFallback: String(localized: "Fish Audio (Apple als Fallback)")
        case .appleOnly: String(localized: "Nur Apple-Stimmen (offline)")
        }
    }
}

/// Which language models do the research and writing.
enum LLMMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case openRouter
    case appleOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openRouter: String(localized: "Gratis-Cloud-Modelle (OpenRouter/Google, Apple als Fallback)")
        case .appleOnly: String(localized: "Nur Apple Intelligence (offline, kürzere Folgen)")
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    nonisolated static let defaultWriter = ModelRef(provider: .openRouter, model: "qwen/qwen3.8-27b:free")
    /// Script (narrative plan, dialogue, revision): stronger free model via Google (ADR-012).
    nonisolated static let defaultScript = ModelRef(provider: .google, model: "gemini-3.8-flash")
    /// Verifier via Google AI Studio (own free quota, fast); see ADR-007/008.
    nonisolated static let defaultVerifier = ModelRef(provider: .google, model: "gemini-3.5-flash-lite")
    /// Backup writer with its own quota when OpenRouter's daily limit is used up.
    nonisolated static let backupWriter = ModelRef(provider: .google, model: "gemini-3.5-flash-lite")

    nonisolated static var defaultWriterModel: String { defaultWriter.model }
    nonisolated static var defaultVerifierModel: String { defaultVerifier.model }

    private let defaults: UserDefaults
    /// Domain rules, pronunciation dictionary, default sources.
    let preferences: PreferencesStore
    /// Podcast-Leitfaden (editable style guide).
    let styleGuide: StyleGuideStore

    var speechMode: SpeechMode {
        didSet { defaults.set(speechMode.rawValue, forKey: Keys.speechMode) }
    }
    var llmMode: LLMMode {
        didSet { defaults.set(llmMode.rawValue, forKey: Keys.llmMode) }
    }
    /// Planning and claim extraction.
    var researcher: ModelRef {
        didSet { defaults.set(researcher.storage, forKey: Keys.researchModel) }
    }
    /// Outline and script ("Skript").
    var writer: ModelRef {
        didSet { defaults.set(writer.storage, forKey: Keys.writerModel) }
    }
    var verifier: ModelRef {
        didSet { defaults.set(verifier.storage, forKey: Keys.verifierModel) }
    }
    /// Use a second, independent model as verifier (falls back to the writer chain).
    var useSeparateVerifier: Bool {
        didSet { defaults.set(useSeparateVerifier, forKey: Keys.useSeparateVerifier) }
    }
    /// Fish multi-speaker requests per chapter ("natürlicher Dialog"); off by default.
    var naturalDialog: Bool { didSet { defaults.set(naturalDialog, forKey: Keys.naturalDialog) } }
    var soundProfile: SoundProfile { didSet { defaults.set(soundProfile.rawValue, forKey: Keys.soundProfile) } }
    var paywallEnabled: Bool { didSet { defaults.set(paywallEnabled, forKey: Keys.paywallEnabled) } }
    var paywallUseArchive: Bool { didSet { defaults.set(paywallUseArchive, forKey: Keys.paywallUseArchive) } }
    var paywallUseWaterfox: Bool { didSet { defaults.set(paywallUseWaterfox, forKey: Keys.paywallUseWaterfox) } }
    var waterfoxBinary: String { didSet { defaults.set(waterfoxBinary, forKey: Keys.waterfoxBinary) } }
    var waterfoxProfile: String { didSet { defaults.set(waterfoxProfile, forKey: Keys.waterfoxProfile) } }

    var paywallConfig: PaywallConfig {
        var config = PaywallConfig()
        config.enabled = paywallEnabled
        config.useArchive = paywallUseArchive
        config.useWaterfox = paywallUseWaterfox
        config.waterfoxBinary = waterfoxBinary
        config.profilePath = waterfoxProfile
        return config
    }

    /// Warning from the daily startup check (nil = all chosen models available).
    private(set) var modelAvailability = ModelCatalog.Availability()

    /// Once per day at launch: are the chosen free models still offered?
    func checkModelsIfDue(force: Bool = false) async {
        guard !KeychainStore.isDisabled, llmMode == .openRouter else { return }
        if !force, let last = defaults.object(forKey: Keys.lastModelCheck) as? Date, Date().timeIntervalSince(last) < 86_400 {
            return
        }
        let fetched = await ModelCatalog.fetchFreeModels(googleKey: KeychainStore.read(.googleAI))
        guard !fetched.isEmpty else { return } // offline: try again next launch
        defaults.set(Date(), forKey: Keys.lastModelCheck)
        defaults.set(fetched.map(\.storage), forKey: Keys.fetchedModels)
        availableModels = ModelCatalog.merged(fetched)
        var selected: [(role: String, model: ModelRef)] = [(String(localized: "Schreiber"), writer)]
        if useSeparateVerifier { selected.append((String(localized: "Prüfer"), verifier)) }
        modelAvailability = ModelCatalog.check(selected: selected, fetched: fetched)
    }

    /// Applies the suggested replacements of the startup check.
    func applyModelReplacements() {
        for item in modelAvailability.missing {
            guard let replacement = item.replacement else { continue }
            if item.model == writer { writer = replacement }
            if item.model == verifier { verifier = replacement }
        }
        modelAvailability = ModelCatalog.Availability()
    }

    /// Models offered in Settings (curated + last fetched list).
    private(set) var availableModels: [ModelRef]

    init(defaults: UserDefaults = .standard, preferences: PreferencesStore? = nil) {
        self.defaults = defaults
        self.preferences = preferences ?? PreferencesStore()
        self.styleGuide = StyleGuideStore()
        speechMode = defaults.string(forKey: Keys.speechMode).flatMap(SpeechMode.init) ?? .fishWithAppleFallback
        llmMode = defaults.string(forKey: Keys.llmMode).flatMap(LLMMode.init) ?? .openRouter
        writer = defaults.string(forKey: Keys.writerModel).flatMap(ModelRef.init(storage:)) ?? Self.defaultScript
        researcher = defaults.string(forKey: Keys.researchModel).flatMap(ModelRef.init(storage:))
            ?? defaults.string(forKey: Keys.writerModel).flatMap(ModelRef.init(storage:)) ?? Self.defaultWriter
        let storedVerifier = defaults.string(forKey: Keys.verifierModel).flatMap(ModelRef.init(storage:))
        // Earlier builds defaulted to gemma (overloaded) or gemini-3.8-flash; move to the new default once.
        if defaults.bool(forKey: Keys.verifierMigrated) == false {
            verifier = Self.defaultVerifier
            defaults.set(true, forKey: Keys.verifierMigrated)
        } else {
            verifier = storedVerifier ?? Self.defaultVerifier
        }
        useSeparateVerifier = defaults.object(forKey: Keys.useSeparateVerifier) as? Bool ?? true
        naturalDialog = defaults.object(forKey: Keys.naturalDialog) as? Bool ?? true
        soundProfile = defaults.string(forKey: Keys.soundProfile).flatMap(SoundProfile.init(rawValue:)) ?? .table
        paywallEnabled = defaults.bool(forKey: Keys.paywallEnabled)
        paywallUseArchive = defaults.object(forKey: Keys.paywallUseArchive) as? Bool ?? true
        paywallUseWaterfox = defaults.object(forKey: Keys.paywallUseWaterfox) as? Bool ?? true
        waterfoxBinary = defaults.string(forKey: Keys.waterfoxBinary) ?? PaywallConfig().waterfoxBinary
        waterfoxProfile = defaults.string(forKey: Keys.waterfoxProfile) ?? PaywallConfig.defaultProfilePath
        let fetched = (defaults.stringArray(forKey: Keys.fetchedModels) ?? []).compactMap(ModelRef.init(storage:))
        availableModels = ModelCatalog.merged(fetched)
        defaults.set(verifier.storage, forKey: Keys.verifierModel)
        // ADR-012: script moves to Gemini 3.8 Flash once (research keeps Qwen).
        if !defaults.bool(forKey: Keys.scriptMigrated) {
            if writer == Self.defaultWriter { writer = Self.defaultScript }
            defaults.set(true, forKey: Keys.scriptMigrated)
        }
    }

    func resetModels() {
        researcher = Self.defaultWriter
        writer = Self.defaultScript
        verifier = Self.defaultVerifier
        useSeparateVerifier = true
    }

    /// Fetches the current free model lists (network; only on user request).
    func refreshModelList() async -> Int {
        let fetched = await ModelCatalog.fetchFreeModels(googleKey: KeychainStore.read(.googleAI))
        guard !fetched.isEmpty else { return 0 }
        defaults.set(fetched.map(\.storage), forKey: Keys.fetchedModels)
        availableModels = ModelCatalog.merged(fetched)
        return fetched.count
    }

    /// Models for a picker, always including the current selection.
    func pickerModels(including current: ModelRef) -> [ModelRef] {
        availableModels.contains(current) ? availableModels : [current] + availableModels
    }

    func hasKey(for provider: ModelProvider) -> Bool {
        provider.keyAccount.map { KeychainStore.read($0) != nil } ?? true
    }

    /// Creates a client, or nil if the provider's key is missing.
    nonisolated static func client(for ref: ModelRef, keys: [ModelProvider: String], maxAttempts: Int = 3) -> (any LLMClient)? {
        switch ref.provider {
        case .apple: return AppleIntelligenceClient()
        case .openRouter:
            return keys[.openRouter].map { OpenRouterClient(model: ref.model, apiKey: $0, endpoint: .openRouter, maxAttempts: maxAttempts) }
        case .google:
            return keys[.google].map { OpenRouterClient(model: ref.model, apiKey: $0, endpoint: .googleAI, maxAttempts: maxAttempts) }
        }
    }

    /// Fallback chain for one role: chosen model → Qwen → Gemini Flash-Lite → Apple.
    nonisolated static func fallbackChain(_ chosen: ModelRef, keys: [ModelProvider: String]) -> [any LLMClient] {
        var seen = Set<String>()
        return [chosen, defaultWriter, backupWriter, .apple]
            .filter { seen.insert($0.storage).inserted }
            .compactMap { client(for: $0, keys: keys, maxAttempts: $0 == chosen ? 3 : 2) }
    }

    /// Model chains for one run: research, script (writer) and verifier (first, then script chain).
    nonisolated static func chains(research: ModelRef, script: ModelRef, verifier: ModelRef?, keys: [ModelProvider: String]) -> [LLMRole: [any LLMClient]] {
        let scriptChain = fallbackChain(script, keys: keys)
        var verifierChain: [any LLMClient] = []
        if let verifier, verifier != script, let client = client(for: verifier, keys: keys) {
            verifierChain.append(client)
        }
        verifierChain += scriptChain
        return [.research: fallbackChain(research, keys: keys), .writer: scriptChain, .verifier: verifierChain]
    }

    nonisolated static func chains(writer: ModelRef, verifier: ModelRef?, keys: [ModelProvider: String]) -> [LLMRole: [any LLMClient]] {
        chains(research: writer, script: writer, verifier: verifier, keys: keys)
    }

    /// Effective AI choice for an episode: per-episode override, else the global settings.
    func resolvedAI(for options: EpisodeOptions?) -> AIChoice {
        let global = AIChoice(llmMode: llmMode, research: researcher, script: writer,
                              verifier: useSeparateVerifier ? verifier : nil, speechMode: speechMode)
        return options?.aiOverride ?? global
    }

    /// Builds the model chains for one pipeline run (episode override wins).
    func makeRouter(for options: EpisodeOptions? = nil) -> LLMRouter {
        let choice = resolvedAI(for: options)
        guard choice.llmMode == .openRouter else {
            let apple = AppleIntelligenceClient()
            return LLMRouter(chains: [.research: [apple], .writer: [apple], .verifier: [apple]])
        }
        var keys: [ModelProvider: String] = [:]
        if let key = KeychainStore.read(.openRouter) { keys[.openRouter] = key }
        if let key = KeychainStore.read(.googleAI) { keys[.google] = key }
        return LLMRouter(chains: Self.chains(research: choice.research, script: choice.script, verifier: choice.verifier, keys: keys))
    }

    private enum Keys {
        static let speechMode = "speechMode"
        static let llmMode = "llmMode"
        static let writerModel = "writerModel"
        static let researchModel = "researchModel"
        static let scriptMigrated = "scriptMigrated.v3"
        static let verifierModel = "verifierModel"
        static let verifierMigrated = "verifierMigrated.v2"
        static let useSeparateVerifier = "useSeparateVerifier"
        static let fetchedModels = "fetchedModels"
        static let lastModelCheck = "lastModelCheck"
        static let paywallEnabled = "paywallEnabled"
        static let naturalDialog = "naturalDialog"
        static let soundProfile = "soundProfile"
        static let paywallUseArchive = "paywallUseArchive"
        static let paywallUseWaterfox = "paywallUseWaterfox"
        static let waterfoxBinary = "waterfoxBinary"
        static let waterfoxProfile = "waterfoxProfile"
    }
}

/// Which AI does what – globally (Settings → KI) or per episode ("KI für diese Folge").
struct AIChoice: Codable, Sendable, Hashable {
    var llmMode: LLMMode
    var research: ModelRef
    var script: ModelRef
    /// nil = no separate verifier (script chain verifies).
    var verifier: ModelRef?
    var speechMode: SpeechMode
}
