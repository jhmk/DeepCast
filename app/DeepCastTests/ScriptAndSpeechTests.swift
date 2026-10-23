import Foundation
import Testing
@testable import DeepCast

struct ScriptParserTests {
    let personas = Persona.defaults

    @Test func parsesSpeakersAndSections() {
        let script = """
        ## Intro
        Max: Hallo!
        Dr. Lena: Guten Tag.
        ## Hauptteil
        Tobi: Wow.
        """
        let parsed = ScriptParser.parse(script, personas: personas)
        #expect(parsed.segments == [
            ParsedSegment(speakerID: "max", text: "Hallo!", section: "Intro"),
            ParsedSegment(speakerID: "lena", text: "Guten Tag.", section: "Intro"),
            ParsedSegment(speakerID: "tobi", text: "Wow.", section: "Hauptteil"),
        ])
        #expect(parsed.unknownSpeakers.isEmpty)
    }

    @Test func matchesNameWithoutTitle() {
        let parsed = ScriptParser.parse("Lena: Hallo", personas: personas)
        #expect(parsed.segments.first?.speakerID == "lena")
    }

    @Test func continuationLinesJoinPreviousSegment() {
        let parsed = ScriptParser.parse("Max: Erster Satz.\nZweiter Satz.", personas: personas)
        #expect(parsed.segments.count == 1)
        #expect(parsed.segments[0].text == "Erster Satz. Zweiter Satz.")
    }

    @Test func colonInsideSentenceIsNotASpeaker() {
        let parsed = ScriptParser.parse("Max: Wichtig ist: Das gilt nur für Kryptobiose.", personas: personas)
        #expect(parsed.segments.count == 1)
        #expect(parsed.segments[0].text == "Wichtig ist: Das gilt nur für Kryptobiose.")
    }

    @Test func unknownSpeakerIsReported() {
        let parsed = ScriptParser.parse("Gast: Hallo", personas: personas)
        #expect(parsed.unknownSpeakers == ["Gast"])
        #expect(parsed.segments.first?.speakerID == "max")
    }

    @Test func exampleScriptIsValid() {
        let parsed = ScriptParser.parse(ScriptParser.exampleScript, personas: personas)
        #expect(parsed.segments.count == 9)
        #expect(parsed.unknownSpeakers.isEmpty)
        #expect(Set(parsed.segments.map(\.section)) == ["Intro", "Überlebenskünstler"])
    }
}

struct TextNormalizerTests {
    @Test func stripsMarkdownAndStageDirections() {
        #expect(TextNormalizer.normalize("**Wichtig:** das [lacht] ist  so.") == "Wichtig: das ist so.")
    }

    @Test func appliesPronunciationAsWholeWords() {
        let result = TextNormalizer.normalize("Die DNA und DNAse", pronunciations: ["DNA": "D N A"])
        #expect(result == "Die D N A und DNAse")
    }
}

struct SpeechSelectionTests {
    @Test func fishIsPreferredByDefault() {
        let lena = Persona.defaults[1]
        #expect(SpeechRenderer.preferredProvider(for: lena, mode: .fishWithAppleFallback) == .fish)
    }

    @Test func appleOnlyOverridesPersona() {
        #expect(SpeechRenderer.preferredProvider(for: Persona.defaults[0], mode: .appleOnly) == .apple)
    }

    @Test func personaWithoutFishVoiceUsesApple() {
        var persona = Persona.defaults[0]
        persona.fishVoice = nil
        #expect(SpeechRenderer.preferredProvider(for: persona, mode: .fishWithAppleFallback) == .apple)
    }

    @Test func allDefaultPersonasHaveDistinctFishVoices() {
        let ids = Persona.defaults.compactMap(\.fishVoice?.id)
        #expect(ids.count == 5)
        #expect(Set(ids).count == 5)
    }

    @Test func cacheKeyChangesWithEveryInput() {
        let base = SpeechCache.key(provider: .fish, voiceID: "a", model: "m", text: "t")
        #expect(base == SpeechCache.key(provider: .fish, voiceID: "a", model: "m", text: "t"))
        #expect(base != SpeechCache.key(provider: .apple, voiceID: "a", model: "m", text: "t"))
        #expect(base != SpeechCache.key(provider: .fish, voiceID: "b", model: "m", text: "t"))
        #expect(base != SpeechCache.key(provider: .fish, voiceID: "a", model: "m", text: "t2"))
    }

    @Test func fishErrorsClassifiedForFallback() {
        #expect(FishAudioError.http(status: 402, message: "").isPermanent)
        #expect(FishAudioError.missingKey.isPermanent)
        #expect(!FishAudioError.http(status: 429, message: "").isPermanent)
        #expect(!FishAudioError.http(status: 503, message: "").isPermanent)
    }

    @Test func parsesFishVoiceList() throws {
        let json = """
        {"total":2,"items":[
          {"_id":"abc","title":" Ben ","description":"calm","languages":["de"],"samples":[{"audio":"https://x/y.mp3"}],"task_count":12,"licensed":true,"state":"trained"},
          {"_id":"def","title":"Broken","state":"failed"}
        ]}
        """
        let voices = try FishAudioProvider.parseVoices(Data(json.utf8))
        #expect(voices.count == 1)
        #expect(voices[0].title == "Ben")
        #expect(voices[0].sampleURL?.absoluteString == "https://x/y.mp3")
        #expect(voices[0].licensed)
    }
}
