import Foundation

enum SpeechProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case fish
    case apple

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fish: "Fish Audio"
        case .apple: "Apple"
        }
    }
}

/// A voice from the Fish Audio library.
struct FishVoiceRef: Codable, Hashable, Sendable {
    var id: String
    var title: String
}

struct Persona: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var role: String
    var style: String
    var expertise: String
    var sampleLine: String
    /// Preferred speech provider for this persona. The global setting can override it.
    var preferredProvider: SpeechProviderKind
    var fishVoice: FishVoiceRef?
    /// Base name of the Apple voice, e.g. "Anna". Always used as fallback.
    var appleVoiceName: String
}

extension Persona {
    /// Default cast. Fish voices are generic community voices from the public library
    /// (no clones of real persons); they can be changed in the persona editor.
    static let defaults: [Persona] = [
        Persona(
            id: "max", name: "Max", role: "Moderator",
            style: "neugierig, locker, stellt die Fragen, die ein Laie stellen würde",
            expertise: "Allgemeinwissen",
            sampleLine: "Moment mal – heißt das, die überleben wirklich im Weltall?",
            preferredProvider: .fish,
            fishVoice: FishVoiceRef(id: "90042f762dbf49baa2e7776d011eee6b", title: "Vorlesen Stimlagen"),
            appleVoiceName: "Martin"
        ),
        Persona(
            id: "lena", name: "Dr. Lena", role: "Wissenschaftlerin",
            style: "präzise, ruhig, erklärt Methodik und nennt Quellen",
            expertise: "Naturwissenschaften",
            sampleLine: "Eine Studie aus dem Jahr 2016 hat genau das untersucht.",
            preferredProvider: .fish,
            fishVoice: FishVoiceRef(id: "285f00e53ff14eb1b111532fb39569d3", title: "Nachrichtensendung"),
            appleVoiceName: "Anna"
        ),
        Persona(
            id: "tobi", name: "Tobi", role: "Nerd",
            style: "begeistert, detailverliebt, erzählt Anekdoten",
            expertise: "Technik und Kurioses",
            sampleLine: "Und jetzt kommt das Verrückteste an der ganzen Sache!",
            preferredProvider: .fish,
            fishVoice: FishVoiceRef(id: "80dd7cfef59f470991827c6856ba7c7e", title: "Banker"),
            appleVoiceName: "Martin"
        ),
        Persona(
            id: "sabine", name: "Sabine", role: "Skeptikerin",
            style: "hinterfragt, benennt Gegenpositionen und Unsicherheiten",
            expertise: "Methodenkritik",
            sampleLine: "Aber wie sicher ist das eigentlich? Das war doch nur eine Studie.",
            preferredProvider: .fish,
            fishVoice: FishVoiceRef(id: "88b18e0d81474a0ca08e2ea6f9df5ff4", title: "Christa deutsch"),
            appleVoiceName: "Anna"
        ),
        Persona(
            id: "jonas", name: "Jonas", role: "Praktiker",
            style: "bodenständig, fragt nach dem Alltagsbezug",
            expertise: "Alltag und Praxis",
            sampleLine: "Und was heißt das jetzt konkret für mich?",
            preferredProvider: .fish,
            fishVoice: FishVoiceRef(id: "a20517d0d23048319e4ced960899187e", title: "Ben"),
            appleVoiceName: "Martin"
        ),
    ]
}
