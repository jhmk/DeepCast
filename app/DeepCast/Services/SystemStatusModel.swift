import Foundation
import FoundationModels
import Observation

/// Checks the local prerequisites of the PoC: Apple Intelligence, voices and ffmpeg.
@MainActor
@Observable
final class SystemStatusModel {
    enum AIState: Equatable {
        case unknown
        case available(contextSize: Int, supportsGerman: Bool)
        case unavailable(reason: String)
    }

    private(set) var aiState: AIState = .unknown
    private(set) var germanVoices: [VoiceInfo] = []
    private(set) var ffmpegURL: URL?
    private(set) var isRefreshing = false

    /// Default persona voices for the PoC (Max → Martin, Dr. Lena → Anna).
    static let requiredVoiceNames = ["Anna", "Martin"]

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        aiState = Self.checkAppleIntelligence()
        germanVoices = VoiceCatalog.voices(forLanguage: "de", in: VoiceCatalog.installedVoices())
        ffmpegURL = ExecutableLocator.locate("ffmpeg")
        storedKeys = Set(KeychainStore.Account.allCases.filter { KeychainStore.read($0) != nil })
    }

    private(set) var storedKeys: Set<KeychainStore.Account> = []

    func bestVoice(named name: String) -> VoiceInfo? {
        VoiceCatalog.bestVoice(named: name, language: "de", in: germanVoices)
    }

    var isReady: Bool {
        guard case .available(_, true) = aiState, ffmpegURL != nil else { return false }
        return Self.requiredVoiceNames.allSatisfy { bestVoice(named: $0) != nil }
    }

    private static func checkAppleIntelligence() -> AIState {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return .available(
                contextSize: model.contextSize,
                supportsGerman: model.supportsLocale(Locale(identifier: "de_DE"))
            )
        case .unavailable(let reason):
            let text: String = switch reason {
            case .deviceNotEligible: String(localized: "Dieser Mac unterstützt Apple Intelligence nicht.")
            case .appleIntelligenceNotEnabled: String(localized: "Apple Intelligence ist in den Systemeinstellungen deaktiviert.")
            case .modelNotReady: String(localized: "Das Modell wird noch geladen. Bitte später erneut prüfen.")
            @unknown default: String(localized: "Apple Intelligence ist nicht verfügbar.")
            }
            return .unavailable(reason: text)
        }
    }
}
