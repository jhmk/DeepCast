import Foundation

/// Result of rendering one segment.
struct RenderedSpeech: Sendable {
    let url: URL
    let provider: SpeechProviderKind
    let voiceName: String
    let fromCache: Bool
    /// Set when the preferred provider failed and Apple was used instead.
    let fallbackReason: String?
}

/// Decides which provider renders a persona and falls back to Apple when Fish fails.
/// After a permanent Fish error (missing key, 401, 402) Fish is skipped for the rest of the run.
actor SpeechRenderer {
    private let apple: AppleSpeechProvider
    private let fish: FishAudioProvider?
    private let cache: SpeechCache
    private let mode: SpeechMode
    private var fishDisabledReason: String?
    private let pronunciations: [String: String]
    private let language: String
    /// 1.0 = normal; < 1 slower (e.g. "Entspannt").
    private let speechRate: Double

    init(mode: SpeechMode, fishAPIKey: String?, cache: SpeechCache = SpeechCache(), apple: AppleSpeechProvider = AppleSpeechProvider(),
         pronunciations: [String: String] = [:], language: String = "de", speechRate: Double = 1.0) {
        self.speechRate = speechRate
        self.mode = mode
        self.pronunciations = pronunciations
        self.language = language
        self.apple = apple
        self.cache = cache
        self.fish = fishAPIKey.map { FishAudioProvider(apiKey: $0) }
        if mode == .fishWithAppleFallback, fishAPIKey == nil {
            fishDisabledReason = FishAudioError.missingKey.localizedDescription
        }
    }

    /// The provider that will be tried first for a persona.
    nonisolated static func preferredProvider(for persona: Persona, mode: SpeechMode) -> SpeechProviderKind {
        guard mode == .fishWithAppleFallback, persona.preferredProvider == .fish, persona.fishVoice != nil else {
            return .apple
        }
        return .fish
    }

    func render(text rawText: String, persona: Persona) async throws -> RenderedSpeech {
        let text = TextNormalizer.normalize(rawText, pronunciations: pronunciations)
        try cache.prepare()

        var fallbackReason: String?
        if Self.preferredProvider(for: persona, mode: mode) == .fish, let voice = persona.fishVoice {
            if let reason = fishDisabledReason {
                fallbackReason = reason
            } else if let fish {
                do {
                    // Fish normalizes numbers only for English/Chinese; spell out German numbers.
                    let fishText = language == "de" ? NumberSpeller.spellOut(text) : text
                    return try await renderFish(text: fishText, voice: voice, fish: fish)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    fallbackReason = error.localizedDescription
                    if let fishError = error as? FishAudioError, fishError.isPermanent {
                        fishDisabledReason = fishError.localizedDescription
                    }
                }
            }
        }
        let result = try await renderApple(text: text, voiceName: persona.appleVoiceName)
        return RenderedSpeech(
            url: result.url, provider: .apple, voiceName: result.voiceName,
            fromCache: result.fromCache, fallbackReason: fallbackReason
        )
    }

    enum DialogError: LocalizedError {
        case notAllFish, fishDisabled(String)
        var errorDescription: String? {
            switch self {
            case .notAllFish: String(localized: "nicht alle Sprecher haben eine Fish-Stimme")
            case .fishDisabled(let reason): reason
            }
        }
    }

    /// Renders several consecutive lines as one natural Fish dialogue (one request).
    func renderDialog(_ lines: [(text: String, persona: Persona)]) async throws -> URL {
        guard let fish else { throw DialogError.fishDisabled(fishDisabledReason ?? FishAudioError.missingKey.localizedDescription) }
        if let reason = fishDisabledReason { throw DialogError.fishDisabled(reason) }
        guard lines.allSatisfy({ Self.preferredProvider(for: $0.persona, mode: mode) == .fish }) else { throw DialogError.notAllFish }
        try cache.prepare()
        var voiceIDs: [String] = []
        var tagged: [(speaker: Int, text: String)] = []
        for line in lines {
            guard let voice = line.persona.fishVoice else { throw DialogError.notAllFish }
            if !voiceIDs.contains(voice.id) { voiceIDs.append(voice.id) }
            var text = TextNormalizer.normalize(line.text, pronunciations: pronunciations)
            if language == "de" { text = NumberSpeller.spellOut(text) }
            tagged.append((voiceIDs.firstIndex(of: voice.id) ?? 0, text))
        }
        let combined = FishAudioProvider.dialogText(tagged)
        let key = SpeechCache.key(provider: .fish, voiceID: voiceIDs.joined(separator: "+"),
                                  model: FishAudioProvider.model + "-dialog" + rateSuffix, text: combined)
        if let cached = cache.cachedFile(forKey: key, fileExtension: "mp3") { return cached }
        let url = cache.url(forKey: key, fileExtension: "mp3")
        do {
            try await fish.synthesizeDialog(lines: tagged, voiceIDs: voiceIDs, speed: speechRate, to: url)
        } catch let error as FishAudioError where error.isPermanent {
            fishDisabledReason = error.localizedDescription
            throw error
        }
        return url
    }

    /// Cache keys of normal-speed renders stay unchanged.
    private var rateSuffix: String { speechRate == 1.0 ? "" : "@\(speechRate)" }

    private func renderFish(text: String, voice: FishVoiceRef, fish: FishAudioProvider) async throws -> RenderedSpeech {
        let key = SpeechCache.key(provider: .fish, voiceID: voice.id, model: FishAudioProvider.model + rateSuffix, text: text)
        if let cached = cache.cachedFile(forKey: key, fileExtension: "mp3") {
            return RenderedSpeech(url: cached, provider: .fish, voiceName: voice.title, fromCache: true, fallbackReason: nil)
        }
        let url = cache.url(forKey: key, fileExtension: "mp3")
        try await fish.synthesize(text: text, voiceID: voice.id, speed: speechRate, to: url)
        return RenderedSpeech(url: url, provider: .fish, voiceName: voice.title, fromCache: false, fallbackReason: nil)
    }

    private func renderApple(text: String, voiceName: String) async throws -> (url: URL, voiceName: String, fromCache: Bool) {
        guard let identifier = apple.voiceIdentifier(forBaseName: voiceName) else {
            throw AppleSpeechError.voiceNotFound(voiceName)
        }
        let key = SpeechCache.key(provider: .apple, voiceID: identifier, model: "avspeech" + rateSuffix, text: text)
        if let cached = cache.cachedFile(forKey: key, fileExtension: "caf") {
            return (cached, voiceName, true)
        }
        let url = cache.url(forKey: key, fileExtension: "caf")
        try await apple.synthesize(text: text, voiceIdentifier: identifier, rate: speechRate, to: url)
        return (url, voiceName, false)
    }
}
