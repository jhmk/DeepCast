import Foundation

/// Conversation format derived from the podcast models (ADR-012).
enum DialogFormat: String, Codable, Sendable, CaseIterable {
    /// Narrator + listener (default; "Was bisher geschah", "Überlebt").
    case narrator
    /// Explainer + questioner (science, how-to; "Tim Gabel").
    case explainer
    /// Equal conversation (discussion, curiosities; "Freak Show", tighter).
    case conversation
    /// Single speaker.
    case monologue

    static func choose(for options: EpisodeOptions) -> DialogFormat {
        if options.speakerIDs.count <= 1 { return .monologue }
        let categories = Set(options.categories)
        if !categories.isDisjoint(with: [.scientific, .howTo]) || options.style == .explainLike12 { return .explainer }
        if categories.contains(.curiosities) || options.style == .debate { return .conversation }
        return .narrator
    }

    /// Main voice: narrator/explainer = expert persona if present, else the first speaker.
    static func mainVoice(_ format: DialogFormat, cast: [Persona]) -> Persona? {
        switch format {
        case .narrator: return cast.first
        case .explainer: return cast.first { !$0.role.localizedCaseInsensitiveContains("moderator") } ?? cast.first
        case .conversation, .monologue: return cast.first
        }
    }

    struct Targets: Sendable, Equatable {
        let mainShare: ClosedRange<Double>?
        let turnsPerMinute: ClosedRange<Double>
        let shortReactionShare: ClosedRange<Double>
        let longTurnWords: ClosedRange<Int>
    }

    var targets: Targets {
        switch self {
        case .narrator: Targets(mainShare: 0.6...0.8, turnsPerMinute: 1.5...3.5, shortReactionShare: 0.15...0.35, longTurnWords: 40...130)
        case .explainer: Targets(mainShare: 0.55...0.75, turnsPerMinute: 2...4, shortReactionShare: 0.15...0.35, longTurnWords: 30...110)
        case .conversation: Targets(mainShare: nil, turnsPerMinute: 3...5.5, shortReactionShare: 0.2...0.4, longTurnWords: 15...70)
        case .monologue: Targets(mainShare: nil, turnsPerMinute: 0...1, shortReactionShare: 0...0.1, longTurnWords: 40...150)
        }
    }

    func instruction(cast: [Persona]) -> String {
        let main = Self.mainVoice(self, cast: cast)?.name ?? "die erste Person"
        let others = cast.filter { $0.name != main }.map(\.name).joined(separator: ", ")
        switch self {
        case .narrator:
            return "Format „Erzähler + Zuhörer“: \(main) erzählt wie eine Geschichte (ca. 60–75 % der Worte, Erzählpassagen 40–120 Wörter, Szenen und Personen). \(others) reagiert, fragt nach, ordnet ein und bringt Querverbindungen. Etwa jeder vierte Beitrag ist eine kurze Reaktion."
        case .explainer:
            return "Format „Erklärer + Fragende“: \(main) erklärt in Ketten (Was? Warum? Wie? Was folgt?). \(others) stellt die Fragen, die Hörer hätten, und fasst in eigenen Worten zusammen („Also heißt das …“). Etwa jeder vierte Beitrag ist eine kurze Reaktion."
        case .conversation:
            return "Format „Gespräch“: gleichberechtigt, viele kurze Wechsel (3–5 pro Minute), Einwürfe und Pointen, aber immer beim Thema."
        case .monologue:
            return "Format „Erzähler-Monolog“: \(main) erzählt allein, spricht die Hörer direkt an und stellt rhetorische Fragen."
        }
    }

    var label: String {
        switch self {
        case .narrator: "Erzähler + Zuhörer"
        case .explainer: "Erklärer + Fragende"
        case .conversation: "Gespräch"
        case .monologue: "Monolog"
        }
    }
}
