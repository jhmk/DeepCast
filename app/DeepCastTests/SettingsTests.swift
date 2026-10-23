import Foundation
import Testing
@testable import DeepCast

struct ModelCatalogTests {
    @Test func parsesStorageAndLegacyValues() {
        #expect(ModelRef(storage: "openrouter|qwen/qwen3.8-27b:free") == ModelRef(provider: .openRouter, model: "qwen/qwen3.8-27b:free"))
        #expect(ModelRef(storage: "qwen/qwen3.8-27b:free")?.provider == .openRouter)
        #expect(ModelRef(storage: "gemini-3.8-flash")?.provider == .google)
        #expect(ModelRef(storage: "apple-on-device") == .apple)
        #expect(ModelRef(storage: "  ") == nil)
    }

    @Test func keepsOnlyFreeOpenRouterTextModels() {
        let json = #"""
        {"data":[
          {"id":"qwen/qwen3.8-27b:free","pricing":{"prompt":"0","completion":"0"},"architecture":{"output_modalities":["text"]}},
          {"id":"qwen/qwen3.8-27b","pricing":{"prompt":"0.0000002","completion":"0.000001"}},
          {"id":"x/paid:free","pricing":{"prompt":"0.1","completion":"0"}},
          {"id":"y/image:free","pricing":{"prompt":"0","completion":"0"},"architecture":{"output_modalities":["image"]}}
        ]}
        """#
        #expect(ModelCatalog.parseOpenRouter(Data(json.utf8)).map(\.model) == ["qwen/qwen3.8-27b:free"])
    }

    @Test func keepsOnlyGoogleTextModels() {
        let json = #"""
        {"models":[
          {"name":"models/gemini-3.5-flash-lite","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-3.8-flash-tts","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-2.5-flash-native-audio-latest","supportedGenerationMethods":["bidiGenerateContent"]},
          {"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]}
        ]}
        """#
        #expect(ModelCatalog.parseGoogle(Data(json.utf8)).map(\.model) == ["gemini-3.5-flash-lite"])
    }

    @Test func chainsUseAvailableKeysAndEndWithApple() {
        let keys: [ModelProvider: String] = [.openRouter: "a", .google: "b"]
        let chains = AppSettings.chains(writer: AppSettings.defaultWriter, verifier: AppSettings.defaultVerifier, keys: keys)
        #expect(chains[.writer]?.map(\.id) == ["qwen/qwen3.8-27b:free", "google/gemini-3.5-flash-lite", "apple-on-device"])
        #expect(chains[.verifier]?.first?.id == "google/gemini-3.5-flash-lite")

        let noKeys = AppSettings.chains(writer: AppSettings.defaultWriter, verifier: AppSettings.defaultVerifier, keys: [:])
        #expect(noKeys[.writer]?.map(\.id) == ["apple-on-device"])
        #expect(noKeys[.verifier]?.map(\.id) == ["apple-on-device"])
    }

    @Test func chosenGoogleWriterComesFirst() {
        let writer = ModelRef(provider: .google, model: "gemini-3.8-flash")
        let chains = AppSettings.chains(writer: writer, verifier: nil, keys: [.openRouter: "a", .google: "b"])
        #expect(chains[.writer]?.first?.id == "google/gemini-3.8-flash")
        #expect(chains[.verifier]?.first?.id == "google/gemini-3.8-flash")
    }
}

struct DomainRuleTests {
    let rules = DomainRules(rules: [
        DomainRule(domain: "blog.example.org", action: .trust),
        DomainRule(domain: "example.org", action: .block),
        DomainRule(domain: "spiegel.de", action: .downgrade),
    ])

    @Test func normalizesInput() {
        #expect(DomainRules.normalize(" https://www.Example.org/path ") == "example.org")
        #expect(DomainRules.normalize("www.spiegel.de") == "spiegel.de")
    }

    @Test func mostSpecificRuleWins() {
        #expect(rules.isBlocked("www.example.org"))
        #expect(!rules.isBlocked("blog.example.org"))
        #expect(rules.tier(forHost: "blog.example.org") == .b)
    }

    @Test func downgradeLowersTier() {
        #expect(SourceTrust.tier(forHost: "www.spiegel.de") == .b)
        #expect(rules.tier(forHost: "www.spiegel.de") == .c)
        #expect(rules.tier(forHost: "nature.com") == .a)
    }
}

@MainActor
struct PreferencesStoreTests {
    @Test func persistsAndReloads() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "prefs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = PreferencesStore(fileURL: file)
        #expect(store.pronunciationMap["DNA"] == "D N A")
        store.addRule(domain: "https://www.bild.de", action: .block)
        store.defaultSources = [.wikipedia, .paper]
        store.pronunciations.append(PronunciationEntry(written: "NASA", spoken: "Nasa"))

        let reloaded = PreferencesStore(fileURL: file)
        #expect(reloaded.rulesSnapshot.isBlocked("bild.de"))
        #expect(reloaded.defaultSources == [.wikipedia, .paper])
        #expect(reloaded.pronunciationMap["NASA"] == "Nasa")
    }
}

struct EpisodeStyleTests {
    @Test func everyStyleHasInstruction() {
        for style in EpisodeStyle.allCases { #expect(!style.instruction.isEmpty) }
    }

    @Test func shortFollowUpHasThreeSections() {
        var options = EpisodeOptions(topic: "x")
        options.minutes = 3
        #expect(options.sectionCount == 3)
        options.minutes = 8
        #expect(options.sectionCount >= 4)
    }

    @Test func styleAndSpeechSurviveEncoding() throws {
        var options = EpisodeOptions(topic: "x")
        options.style = .mythCheck
        options.simpleSpeech = true
        options.followUpOf = "Parent"
        let decoded = try JSONDecoder().decode(EpisodeOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded.style == .mythCheck && decoded.simpleSpeech && decoded.followUpOf == "Parent")
        #expect(decoded.speechInstruction.contains("kurze Sätze"))
    }
}

struct ModelAvailabilityTests {
    let qwen = ModelRef(provider: .openRouter, model: "qwen/qwen3.8-27b:free")
    let gone = ModelRef(provider: .openRouter, model: "old/model:free")
    let lite = ModelRef(provider: .google, model: "gemini-3.5-flash-lite")

    @Test func reportsMissingModelWithReplacement() {
        let result = ModelCatalog.check(selected: [("Schreiber", gone), ("Prüfer", lite)], fetched: [qwen, lite])
        #expect(result.missing.count == 1)
        #expect(result.missing.first?.replacement == qwen)
        #expect(result.message?.contains("„model“") == true)
    }

    @Test func noVerdictForProvidersWithoutList() {
        // Google list missing (no key/offline) → Google models are not reported.
        let result = ModelCatalog.check(selected: [("Prüfer", lite)], fetched: [qwen])
        #expect(result.missing.isEmpty && result.message == nil)
    }

    @Test func appleIsAlwaysAvailable() {
        #expect(ModelCatalog.check(selected: [("Schreiber", .apple)], fetched: [qwen]).missing.isEmpty)
    }
}

struct AIChoiceTests {
    let keys: [ModelProvider: String] = [.openRouter: "a", .google: "b"]

    @Test func researchScriptAndVerifierHaveOwnChains() {
        let research = ModelRef(provider: .google, model: "gemini-3.8-flash")
        let chains = AppSettings.chains(research: research, script: AppSettings.defaultWriter, verifier: AppSettings.defaultVerifier, keys: keys)
        #expect(chains[.research]?.first?.id == "google/gemini-3.8-flash")
        #expect(chains[.research]?.last?.id == "apple-on-device")
        #expect(chains[.writer]?.first?.id == "qwen/qwen3.8-27b:free")
        #expect(chains[.verifier]?.first?.id == "google/gemini-3.5-flash-lite")
    }

    @MainActor
    @Test func episodeOverrideWinsOverSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "deepcast-test-\(UUID().uuidString)"))
        let file = FileManager.default.temporaryDirectory.appending(path: "p-\(UUID().uuidString).json")
        let settings = AppSettings(defaults: defaults, preferences: PreferencesStore(fileURL: file))
        var options = EpisodeOptions(topic: "x")
        #expect(settings.resolvedAI(for: options).speechMode == .fishWithAppleFallback)
        options.aiOverride = AIChoice(llmMode: .appleOnly, research: .apple, script: .apple, verifier: nil, speechMode: .appleOnly)
        #expect(settings.resolvedAI(for: options).speechMode == .appleOnly)
        #expect(settings.resolvedAI(for: options).llmMode == .appleOnly)
        let decoded = try JSONDecoder().decode(EpisodeOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded.aiOverride == options.aiOverride)
    }
}
