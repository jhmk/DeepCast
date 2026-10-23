import Foundation
import FoundationModels

// Structured model outputs. Each type works for Apple Intelligence (@Generable) and for
// OpenRouter (JSON Schema derived from the same declaration, decoded via Codable).

@Generable
struct ResearchPlanOutput: Codable, Sendable {
    @Guide(description: "3 bis 6 konkrete Teilfragen, die der Podcast beantworten soll")
    var subquestions: [String]
    @Guide(description: "Kurze Websuchanfragen (2 bis 6 Wörter), keine Sätze")
    var webQueries: [String]
    @Guide(description: "Titel passender Wikipedia-Artikel, genau wie bei Wikipedia geschrieben")
    var wikipediaTitles: [String]
    @Guide(description: "2 kurze englische Fachbegriff-Suchen für wissenschaftliche Literatur, z.B. tardigrade anhydrobiosis")
    var paperQueries: [String]
    @Guide(description: "5 bis 12 Schlüsselwörter, die in relevanten Textstellen vorkommen")
    var keywords: [String]
}

@Generable
struct ClaimExtractionOutput: Codable, Sendable {
    @Guide(description: "Überprüfbare Aussagen aus den Textabschnitten")
    var claims: [ExtractedClaimOutput]
}

@Generable
struct ExtractedClaimOutput: Codable, Sendable {
    @Guide(description: "ID des Textabschnitts, aus dem die Aussage stammt, z.B. S1-C2")
    var chunkID: String
    @Guide(description: "Die Aussage als eigenständiger, verständlicher Satz")
    var text: String
    @Guide(description: "Art der Aussage", .anyOf(["number", "quote", "causal", "historical", "scientific_consensus", "definition", "opinion", "anecdote", "fact"]))
    var type: String
    @Guide(description: "Wörtliches, zusammenhängendes Zitat aus dem Abschnitt (ein bis zwei Sätze), das die Aussage belegt")
    var quote: String
    @Guide(description: "Nur bei type quote: vollständiger Name der zitierten Person, sonst leer")
    var speaker: String
}

@Generable
struct VerificationOutput: Codable, Sendable {
    var results: [VerificationItemOutput]
}

@Generable
struct VerificationItemOutput: Codable, Sendable {
    @Guide(description: "ID der Aussage, z.B. K3")
    var claimID: String
    @Guide(description: "Urteil", .anyOf(["supported", "partially_supported", "contradicted", "not_enough_info"]))
    var verdict: String
    @Guide(description: "Kurze Begründung, ein Satz")
    var reason: String
}

@Generable
struct OutlineOutput: Codable, Sendable {
    @Guide(description: "Prägnanter Episodentitel")
    var title: String
    @Guide(description: "Zusammenfassung in zwei Sätzen")
    var summary: String
    var sections: [OutlineSectionOutput]
}

@Generable
struct OutlineSectionOutput: Codable, Sendable {
    @Guide(description: "Kapitelname, kurz")
    var title: String
    @Guide(description: "Was in diesem Kapitel passiert, ein Satz")
    var goal: String
    @Guide(description: "IDs der Aussagen, die in diesem Kapitel vorkommen")
    var claimIDs: [String]
}

@Generable
struct ScriptSectionOutput: Codable, Sendable {
    var segments: [ScriptSegmentOutput]
}

@Generable
struct ScriptSegmentOutput: Codable, Sendable {
    @Guide(description: "ID der sprechenden Persona")
    var speaker: String
    @Guide(description: "Gesprochener Text, natürlich und mündlich")
    var text: String
    @Guide(description: "IDs aller Aussagen, auf die sich dieser Beitrag stützt; leer nur bei Fragen, Überleitungen oder Meinungen ohne Fakten")
    var claimIDs: [String]
}

// MARK: - Narrative script (ADR-012)

@Generable
struct NarrativePlanOutput: Codable, Sendable {
    @Guide(description: "Prägnanter Episodentitel, neugierig machend")
    var title: String
    @Guide(description: "Zusammenfassung in zwei Sätzen")
    var summary: String
    @Guide(description: "Aufhänger für die ersten 30–60 Sekunden: überraschende Tatsache (mit Aussage-ID) oder kleine Szene")
    var hook: String
    @Guide(description: "Die Leitfrage der Folge in einem Satz")
    var guidingQuestion: String
    @Guide(description: "3 bis 5 Kernerkenntnisse in Lernreihenfolge, je ein Satz")
    var keyInsights: [String]
    var sections: [NarrativeSectionOutput]
    @Guide(description: "Wie der Schluss auf den Aufhänger zurückgreift, ein Satz")
    var callback: String
}

@Generable
struct NarrativeSectionOutput: Codable, Sendable {
    @Guide(description: "Kapitelname, kurz")
    var title: String
    @Guide(description: "Was die Hörer nach diesem Kapitel verstanden haben, ein Satz")
    var goal: String
    @Guide(description: "Erklärkette: Was? Warum wichtig? Wie? Was folgt? – in Stichworten")
    var explanation: String
    @Guide(description: "Ein Bild oder Vergleich zum Vorstellen, als Vergleich erkennbar; leer wenn keiner passt")
    var analogy: String
    @Guide(description: "Wegweiser-Satz zum nächsten Kapitel; leer beim letzten Kapitel")
    var transition: String
    @Guide(description: "IDs der Aussagen für dieses Kapitel; jede Aussage nur in einem Kapitel")
    var claimIDs: [String]
}

@Generable
struct FullScriptOutput: Codable, Sendable {
    var segments: [FullScriptSegmentOutput]
}

@Generable
struct FullScriptSegmentOutput: Codable, Sendable {
    @Guide(description: "Kapitelname genau wie im Erzählplan")
    var section: String
    @Guide(description: "ID der sprechenden Persona")
    var speaker: String
    @Guide(description: "Gesprochener Text, natürlich und mündlich, ohne Sprechernamen")
    var text: String
    @Guide(description: "IDs aller Aussagen, auf die sich dieser Beitrag stützt; leer bei Reaktionen, Fragen, Überleitungen, Meinungen")
    var claimIDs: [String]
}

@Generable
struct ScriptReviewOutput: Codable, Sendable {
    @Guide(description: "Verständlichkeit 1–10", .range(1...10))
    var clarity: Int
    @Guide(description: "Roter Faden und Struktur 1–10", .range(1...10))
    var structure: Int
    @Guide(description: "Natürlichkeit des Gesprächs 1–10", .range(1...10))
    var naturalness: Int
    @Guide(description: "Konkrete Probleme mit Beitragsnummer, höchstens 12")
    var issues: [ScriptReviewIssueOutput]
    @Guide(description: "Gesamturteil in zwei Sätzen")
    var verdict: String
}

@Generable
struct ScriptReviewIssueOutput: Codable, Sendable {
    @Guide(description: "Nummer des betroffenen Beitrags, -1 wenn es die ganze Folge betrifft")
    var segment: Int
    @Guide(description: "Problem und konkreter Verbesserungsvorschlag, ein bis zwei Sätze")
    var problem: String
}

@Generable
struct GuideRulesOutput: Codable, Sendable {
    @Guide(description: "1 bis 4 allgemeingültige, kurze Regeln für künftige Folgen")
    var rules: [String]
}
