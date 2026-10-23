import Testing
@testable import DeepCast

struct VoiceCatalogTests {
    private let voices = [
        VoiceInfo(identifier: "anna.compact", name: "Anna", language: "de-DE", quality: .standard),
        VoiceInfo(identifier: "anna.premium", name: "Anna (Premium)", language: "de-DE", quality: .premium),
        VoiceInfo(identifier: "martin.enhanced", name: "Martin (Enhanced)", language: "de-DE", quality: .enhanced),
        VoiceInfo(identifier: "samantha", name: "Samantha", language: "en-US", quality: .standard),
    ]

    @Test func picksHighestQualityVariant() {
        let anna = VoiceCatalog.bestVoice(named: "Anna", language: "de", in: voices)
        #expect(anna?.identifier == "anna.premium")
    }

    @Test func matchesNameWithQualitySuffix() {
        let martin = VoiceCatalog.bestVoice(named: "Martin", language: "de", in: voices)
        #expect(martin?.identifier == "martin.enhanced")
        #expect(martin?.baseName == "Martin")
    }

    @Test func respectsLanguage() {
        #expect(VoiceCatalog.bestVoice(named: "Samantha", language: "de", in: voices) == nil)
    }

    @Test func sortsByQualityThenName() {
        let german = VoiceCatalog.voices(forLanguage: "de", in: voices)
        #expect(german.map(\.identifier) == ["anna.premium", "martin.enhanced", "anna.compact"])
    }
}
