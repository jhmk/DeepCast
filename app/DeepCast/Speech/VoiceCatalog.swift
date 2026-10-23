import AVFoundation

/// Sendable snapshot of an installed system voice.
struct VoiceInfo: Sendable, Hashable, Identifiable {
    enum Quality: Int, Sendable, Comparable {
        case standard = 1
        case enhanced = 2
        case premium = 3

        static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .standard: "Standard"
            case .enhanced: "Erweitert"
            case .premium: "Premium"
            }
        }
    }

    let identifier: String
    /// Display name as reported by the system, e.g. "Anna (Premium)".
    let name: String
    let language: String
    let quality: Quality

    var id: String { identifier }

    /// Name without the quality suffix, e.g. "Anna".
    var baseName: String {
        guard let range = name.range(of: " (") else { return name }
        return String(name[..<range.lowerBound])
    }
}

enum VoiceCatalog {
    /// All installed voices, read from AVSpeechSynthesisVoice.
    static func installedVoices() -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            VoiceInfo(
                identifier: voice.identifier,
                name: voice.name,
                language: voice.language,
                quality: VoiceInfo.Quality(rawValue: voice.quality.rawValue) ?? .standard
            )
        }
    }

    /// Voices for a language prefix (e.g. "de"), best quality first, then by name.
    static func voices(forLanguage prefix: String, in voices: [VoiceInfo]) -> [VoiceInfo] {
        voices
            .filter { $0.language.hasPrefix(prefix) }
            .sorted { lhs, rhs in
                lhs.quality != rhs.quality ? lhs.quality > rhs.quality : lhs.name < rhs.name
            }
    }

    /// Best installed variant of a voice by base name ("Anna" matches "Anna (Premium)").
    /// System names carry a quality suffix, so exact name matching silently picks the
    /// low-quality variant – a pitfall found in the PoC spike.
    static func bestVoice(named baseName: String, language prefix: String, in voices: [VoiceInfo]) -> VoiceInfo? {
        voices
            .filter { $0.language.hasPrefix(prefix) && $0.baseName == baseName }
            .max { $0.quality < $1.quality }
    }
}
