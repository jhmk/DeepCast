import Foundation

// MARK: - Options

enum EpisodeLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    case de, en
    var id: String { rawValue }
    var displayName: String { self == .de ? "Deutsch" : "English" }
    var promptName: String { self == .de ? "Deutsch" : "Englisch" }
    /// Planned speaking rate; adapts to the measured tempo of rendered episodes (ADR-012).
    var wordsPerMinute: Int {
        let fallback = self == .de ? 130 : 150
        guard !KeychainStore.isDisabled,
              let measured = UserDefaults.standard.object(forKey: "measuredWPM.\(rawValue)") as? Int,
              (110...190).contains(measured) else { return fallback }
        return measured
    }
}

/// Episode styles (spec 8).
enum EpisodeStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case discussion, interview, debate, narrative, explainLike12, mythCheck

    var id: String { rawValue }

    var label: String {
        switch self {
        case .discussion: String(localized: "Diskussion")
        case .interview: String(localized: "Interview")
        case .debate: String(localized: "Debatte (Pro/Contra)")
        case .narrative: String(localized: "Erzählung")
        case .explainLike12: String(localized: "Erklär es mir wie 12")
        case .mythCheck: String(localized: "Mythos-Check")
        }
    }

    var instruction: String {
        switch self {
        case .discussion:
            "Stil: lockere Diskussion unter Gleichberechtigten, alle bringen Fragen und Wissen ein."
        case .interview:
            "Stil: Interview. Die erste Person moderiert und fragt, die anderen sind Gäste und antworten ausführlich."
        case .debate:
            "Stil: Debatte. Zwei Seiten (Pro und Contra) tragen Argumente vor, die erste Person moderiert. Argumente nur aus belegten Aussagen; Meinungen klar als Meinung kennzeichnen. Am Ende eine faire Zusammenfassung beider Seiten."
        case .narrative:
            "Stil: Erzählung. Eine Geschichte mit Spannungsbogen (Einstieg, Entwicklung, Auflösung); die anderen Personen ergänzen nur kurz."
        case .explainLike12:
            "Stil: Erklär es mir, als wäre ich 12. Sehr einfache Sprache, Alltagsvergleiche, keine Fachbegriffe ohne Erklärung, kurze Sätze."
        case .mythCheck:
            "Stil: Mythos-Check. Verbreitete Annahmen nennen und anhand der Aussagen einordnen: was stimmt, was nicht, was ist unklar. Einen Mythos nur als widerlegt bezeichnen, wenn eine Aussage das belegt."
        }
    }
}

enum FactCheckStrictness: String, Codable, Sendable, CaseIterable, Identifiable {
    case standard, strict
    var id: String { rawValue }
    var displayName: String { self == .standard ? String(localized: "Standard") : String(localized: "Streng") }
}

struct EpisodeOptions: Codable, Sendable, Hashable {
    var topic: String
    /// Source types to search (individually switchable, spec 3).
    var sources: Set<SourceKind> = SourceKind.defaultSet
    /// Up to 3 categories, the first is the primary one (style, speakers). Empty = general.
    var categories: [EpisodeCategory] = []
    /// URLs and files added by the user; always used (spec 3: "Manuell: eigene URLs, PDFs, Dateien").
    var customSources: [CustomSource] = []
    /// Per-episode AI choice (research, script, verifier, speech); nil = global settings.
    var aiOverride: AIChoice?
    /// Primary category (first selected) – used for labels.
    var category: EpisodeCategory { categories.first ?? .general }
    var categoryMix: CategoryMix { CategoryMix(categories) }
    var minutes: Int = EpisodeOptions.defaultMinutes
    /// 1 = oberflächlich … 5 = Hardcore-Nerd
    var nerdLevel: Int = 3
    /// Persona IDs in speaking order. 1 = monologue.
    var speakerIDs: [String] = ["max", "lena"]
    /// 0 strikt … 3 frei assoziativ
    var digression: Int = 1
    var language: EpisodeLanguage = .de
    var strictness: FactCheckStrictness = .standard
    var style: EpisodeStyle = .discussion
    /// Apple voices sound better with short sentences and no filler words (spec 6).
    var simpleSpeech = false
    /// Set for follow-up episodes that answer a question from an existing dossier.
    var followUpOf: String?

    var targetWords: Int { minutes * language.wordsPerMinute }

    var nerdInstruction: String {
        switch nerdLevel {
        case ...1: "Zielgruppe: Laien ohne Vorwissen. Fachbegriffe vermeiden oder sofort erklären, Alltagsvergleiche nutzen."
        case 2: "Zielgruppe: interessierte Laien. Wenige Fachbegriffe, jeweils kurz erklärt."
        case 3: "Zielgruppe: Interessierte mit etwas Vorwissen. Fachbegriffe erlaubt, Zahlen mit Einordnung."
        case 4: "Zielgruppe: Fachkundige. Fachbegriffe, Methodik und konkrete Zahlen ausdrücklich erwünscht."
        default: "Zielgruppe: Hardcore-Nerds. Maximale Tiefe: Methodik, Studiendesign, genaue Zahlen, Grenzen der Forschung."
        }
    }

    var digressionInstruction: String {
        switch digression {
        case ...0: "Bleib strikt beim Kernthema, keine Nebenthemen."
        case 1: "Kernthema mit etwas Kontext (Hintergrund, Einordnung)."
        case 2: "Kernthema plus einige Nebenthemen: Geschichte, Nachbarthemen, Kuriositäten."
        default: "Frei assoziativ: Nebenthemen, Kuriositäten und überraschende Verbindungen ausdrücklich erwünscht."
        }
    }

    var webQueryCount: Int { 3 + max(0, min(3, digression)) }

    /// Source mix by nerd level (spec 3, "Quellenwahl nach Einstellung").
    var paperCount: Int { sources.contains(.paper) ? (nerdLevel <= 2 ? 1 : nerdLevel == 3 ? 2 : 3) : 0 }
    var bookCount: Int { sources.contains(.gutenberg) || sources.contains(.openLibrary) ? (nerdLevel >= 4 ? 2 : 1) : 0 }
    var podcastCount: Int { sources.contains(.podcast) ? (nerdLevel <= 2 ? 2 : 1) : 0 }

    init(topic: String) { self.topic = topic }

    static let defaultMinutes = 10
    /// Length slider: 10 to 60 minutes in 10-minute steps (follow-up answers stay shorter).
    static let minuteRange = 10...60
    static let minuteStep = 10

    enum CodingKeys: String, CodingKey {
        case topic, sources, categories, customSources, aiOverride, minutes, nerdLevel, speakerIDs, digression, language, strictness, style, simpleSpeech, followUpOf
        case legacyCategory = "category"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(topic, forKey: .topic)
        try container.encode(sources.map(\.rawValue).sorted(), forKey: .sources)
        try container.encode(categories, forKey: .categories)
        try container.encode(customSources, forKey: .customSources)
        try container.encodeIfPresent(aiOverride, forKey: .aiOverride)
        try container.encode(minutes, forKey: .minutes)
        try container.encode(nerdLevel, forKey: .nerdLevel)
        try container.encode(speakerIDs, forKey: .speakerIDs)
        try container.encode(digression, forKey: .digression)
        try container.encode(language, forKey: .language)
        try container.encode(strictness, forKey: .strictness)
        try container.encode(style, forKey: .style)
        try container.encode(simpleSpeech, forKey: .simpleSpeech)
        try container.encodeIfPresent(followUpOf, forKey: .followUpOf)
    }

    // Older episodes were saved without `sources`; missing keys fall back to defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        topic = try container.decode(String.self, forKey: .topic)
        let raw = try container.decodeIfPresent([String].self, forKey: .sources)
        sources = raw.map { Set($0.compactMap(SourceKind.init(rawValue:))) } ?? SourceKind.defaultSet
        if sources.isEmpty { sources = SourceKind.defaultSet }
        customSources = try container.decodeIfPresent([CustomSource].self, forKey: .customSources) ?? []
        aiOverride = try container.decodeIfPresent(AIChoice.self, forKey: .aiOverride)
        if let list = try container.decodeIfPresent([EpisodeCategory].self, forKey: .categories) {
            categories = list
        } else if let single = try container.decodeIfPresent(EpisodeCategory.self, forKey: .legacyCategory), single != .general {
            categories = [single] // episodes saved with a single category
        }
        minutes = try container.decodeIfPresent(Int.self, forKey: .minutes) ?? Self.defaultMinutes
        nerdLevel = try container.decodeIfPresent(Int.self, forKey: .nerdLevel) ?? 3
        speakerIDs = try container.decodeIfPresent([String].self, forKey: .speakerIDs) ?? ["max", "lena"]
        digression = try container.decodeIfPresent(Int.self, forKey: .digression) ?? 1
        language = try container.decodeIfPresent(EpisodeLanguage.self, forKey: .language) ?? .de
        strictness = try container.decodeIfPresent(FactCheckStrictness.self, forKey: .strictness) ?? .standard
        style = try container.decodeIfPresent(EpisodeStyle.self, forKey: .style) ?? .discussion
        simpleSpeech = try container.decodeIfPresent(Bool.self, forKey: .simpleSpeech) ?? false
        followUpOf = try container.decodeIfPresent(String.self, forKey: .followUpOf)
    }

    var speechInstruction: String {
        simpleSpeech
            ? "Die Stimmen sind einfache Computerstimmen: sehr kurze Sätze, keine Füllwörter wie „hm“ oder „äh“, keine Lautmalerei, Betonung nur über den Satzbau."
            : "Natürliche gesprochene Sprache, gern mit kurzen Einwürfen."
    }
    var maxSources: Int { minutes <= 10 ? 6 : minutes <= 30 ? 8 : 10 }
    var sectionCount: Int {
        minutes <= 3 ? 3 : max(4, min(14, Int((Double(minutes) / 5).rounded()) + 3))
    }
}

// MARK: - Sources

enum TrustTier: String, Codable, Sendable, Comparable, CaseIterable {
    case a = "A", b = "B", c = "C", d = "D"

    private var rank: Int { ["A": 0, "B": 1, "C": 2, "D": 3][rawValue] ?? 3 }
    static func < (lhs: TrustTier, rhs: TrustTier) -> Bool { lhs.rank < rhs.rank }

    var label: String {
        switch self {
        case .a: String(localized: "A – Wissenschaft/amtlich")
        case .b: String(localized: "B – Qualitätsmedien/Nachschlagewerke")
        case .c: String(localized: "C – sonstige Fachseiten")
        case .d: String(localized: "D – Social Media/Foren")
        }
    }
}

enum SourceKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case wikipedia, wikivoyage, web, paper, podcast, gutenberg, openLibrary, custom

    /// Kinds that can be switched on/off (own sources are always used).
    static let selectable: [SourceKind] = [.wikipedia, .wikivoyage, .web, .paper, .podcast, .openLibrary, .gutenberg]

    /// On by default (Wikivoyage only for travel episodes).
    static let defaultSet: Set<SourceKind> = [.wikipedia, .web, .paper, .podcast]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wikipedia: "Wikipedia"
        case .wikivoyage: String(localized: "Wikivoyage (Reiseführer)")
        case .web: String(localized: "Web (DuckDuckGo)")
        case .paper: String(localized: "Wissenschaftliche Paper (OpenAlex)")
        case .podcast: String(localized: "Podcast-Transkripte")
        case .custom: String(localized: "Eigene Quelle")
        case .gutenberg: String(localized: "Project Gutenberg (gemeinfreie Bücher)")
        case .openLibrary: String(localized: "Open Library (frei lesbare Bücher)")
        }
    }

    /// Instruction for claim extraction depending on the kind of text.
    var extractionHint: String {
        switch self {
        case .wikipedia, .web: ""
        case .wikivoyage: "Diese Quelle ist ein Reiseführer-Wiki. Persönliche Empfehlungen als opinion; Preise, Öffnungszeiten und Fahrpläne mit Jahr, falls angegeben."
        case .custom: "Diese Quelle wurde vom Nutzer selbst hinzugefügt."
        case .gutenberg, .openLibrary: "Diese Quelle ist ein (oft älteres) Buch. Übernimm bei Tatsachen das Erscheinungsjahr bzw. den damaligen Kenntnisstand in die Aussage (\"Laut einem Buch von 1859 …\"). Historische Einschätzungen und Meinungen des Autors als opinion."
        case .paper: "Diese Quelle ist eine wissenschaftliche Veröffentlichung (oft Englisch). Übernimm Studiendesign, untersuchte Art/Population und Einschränkungen in die Aussage (z.B. \"In einer Laborstudie an …\"). Das Zitat bleibt in der Originalsprache."
        case .podcast: "Diese Quelle ist das automatische Transkript eines Podcasts (gesprochene Sprache, kann Hörfehler enthalten). Nimm nur klar formulierte Aussagen, keine Werbung, Begrüßung oder Plauderei. Meinungen der Sprecher als opinion."
        }
    }
}

struct SourceChunk: Codable, Sendable, Hashable, Identifiable {
    let id: String       // e.g. "S2-C4"
    let text: String
    let offset: Int      // character offset in the extracted text
}

struct SourceDocument: Codable, Sendable, Hashable, Identifiable {
    let id: String       // e.g. "S2"
    var kind: SourceKind
    var title: String
    var publisher: String  // registrable domain, e.g. "spektrum.de"
    var url: URL
    var publishedAt: Date?
    var language: String
    var tier: TrustTier
    var chunks: [SourceChunk]
    var notes: [String] = []
    var included = true
    /// Retraction-check warning (Crossref): concern or correction. Caps claims at 🟡.
    var integrityWarning: String?
    /// How the text was obtained: nil = normal web/API, "archive.is" or "Waterfox …" for paywalls.
    var fetchMethod: String?
    /// Set when the text is (nearly) identical to another source, e.g. the same agency report.
    var syndicationGroup: String?

    /// Sources from the same publisher (e.g. de/en Wikipedia) are not independent;
    /// two different studies in the same journal are.
    var independenceKey: String {
        if let syndicationGroup { return "syndicated:" + syndicationGroup }
        switch kind {
        case .wikipedia: return "wikipedia"
        case .wikivoyage: return "wikivoyage"
        case .paper, .gutenberg, .openLibrary: return "book:" + url.absoluteString
        default: return publisher
        }
    }
}

// MARK: - Claims

enum ClaimType: String, Codable, Sendable, CaseIterable {
    case number, quote, causal, historical
    case scientificConsensus = "scientific_consensus"
    case definition, opinion, anecdote, fact

    var label: String {
        switch self {
        case .number: "Zahl"
        case .quote: "Zitat"
        case .causal: "Ursache"
        case .historical: "Historisch"
        case .scientificConsensus: "Konsens"
        case .definition: "Definition"
        case .opinion: "Meinung"
        case .anecdote: "Anekdote"
        case .fact: "Fakt"
        }
    }

    var needsEvidence: Bool { self != .opinion && self != .anecdote }
}

enum Verdict: String, Codable, Sendable {
    case supported
    case partiallySupported = "partially_supported"
    case contradicted
    case notEnoughInfo = "not_enough_info"

    var label: String {
        switch self {
        case .supported: String(localized: "belegt")
        case .partiallySupported: String(localized: "teilweise belegt")
        case .contradicted: String(localized: "widerlegt")
        case .notEnoughInfo: String(localized: "zu wenig Beleg")
        }
    }
}

enum TrafficLight: String, Codable, Sendable, Comparable, CaseIterable {
    case green, yellow, red

    private var rank: Int { ["green": 0, "yellow": 1, "red": 2][rawValue] ?? 2 }
    static func < (lhs: TrafficLight, rhs: TrafficLight) -> Bool { lhs.rank < rhs.rank }

    var emoji: String { ["green": "🟢", "yellow": "🟡", "red": "🔴"][rawValue] ?? "⚪️" }
    var label: String {
        switch self {
        case .green: String(localized: "belegt")
        case .yellow: String(localized: "mit Einschränkung")
        case .red: String(localized: "wird entfernt")
        }
    }
}

enum QuoteMatch: String, Codable, Sendable {
    case exact, approximate
}

struct Evidence: Codable, Sendable, Hashable {
    let sourceID: String
    let chunkID: String
    let quote: String
    let match: QuoteMatch
}

struct Claim: Codable, Sendable, Hashable, Identifiable {
    var id: String               // "K1"
    var text: String
    var type: ClaimType
    var evidence: [Evidence]
    var verdict: Verdict?
    var verdictReason: String?
    var verifierModel: String?
    var numberCheck: NumberCheckResult?
    var light: TrafficLight = .red
    var lightReasons: [String] = []
    var userOverride: TrafficLight?
    /// Quotes (spec 5.4): person the quote is attributed to, and whether it may be read verbatim.
    var quotedPerson: String?
    /// True if a quote could not be verified (wording or person) – only as paraphrase.
    var isParaphrase: Bool?
    /// Other claims that state different numbers for the same thing (spec 5.4: "Widersprüche").
    var contestedWith: [String]?

    var effectiveLight: TrafficLight { userOverride ?? light }
    var sourceIDs: [String] { Array(NSOrderedSet(array: evidence.map(\.sourceID))) as? [String] ?? [] }
}

struct NumberCheckResult: Codable, Sendable, Hashable {
    var checked: [String]
    var missing: [String]
    var rounded: [String]
    var passed: Bool { missing.isEmpty }
}

// MARK: - Dossier (Recherche-Mappe)

struct ResearchDossier: Codable, Sendable {
    var options: EpisodeOptions
    var createdAt: Date
    var subquestions: [String] = []
    var keywords: [String] = []
    var sources: [SourceDocument] = []
    var claims: [Claim] = []
    var calls: [LLMCallRecord] = []
    var notes: [String] = []
    var scriptIssues: [String] = []
    /// Set while research is unfinished (allows resuming after a cancel or crash).
    var checkpoint: ResearchCheckpoint?
    /// Measured script quality and test-listener review (ADR-012).
    var scriptQuality: ScriptQualityReport?

    var isComplete: Bool { checkpoint == nil && !claims.isEmpty }

    func source(_ id: String) -> SourceDocument? { sources.first { $0.id == id } }
    func claim(_ id: String) -> Claim? { claims.first { $0.id == id } }

    var includedSourceIDs: Set<String> { Set(sources.filter(\.included).map(\.id)) }

    /// Claims that may be used in the script: not red and backed by at least one included source.
    var usableClaims: [Claim] {
        let included = includedSourceIDs
        return claims.filter { claim in
            claim.effectiveLight != .red && claim.evidence.contains { included.contains($0.sourceID) }
        }
    }

    func count(_ light: TrafficLight) -> Int {
        let included = includedSourceIDs
        return claims.filter { claim in
            claim.effectiveLight == light && claim.evidence.contains { included.contains($0.sourceID) }
        }.count
    }
}

/// Progress of an unfinished research run (stored inside dossier.json).
struct ResearchCheckpoint: Codable, Sendable {
    /// Sources whose claims are already extracted.
    var extractedSourceIDs: [String] = []
    /// Claims before merging duplicates.
    var rawClaims: [Claim] = []
}

// MARK: - Script

struct ScriptSegmentDraft: Codable, Sendable, Hashable {
    var speakerID: String
    var text: String
    var section: String
    var claimIDs: [String]
}

struct EpisodeScript: Codable, Sendable {
    var title: String
    var summary: String
    var segments: [ScriptSegmentDraft]
}

// MARK: - Progress

enum PipelineStage: Int, Codable, Sendable, CaseIterable, Comparable {
    case plan, search, fetch, extract, verify, review, outline, script, check, speech, done

    static func < (lhs: PipelineStage, rhs: PipelineStage) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .plan: String(localized: "Recherche planen")
        case .search: String(localized: "Quellen suchen")
        case .fetch: String(localized: "Texte abrufen")
        case .extract: String(localized: "Aussagen herausziehen")
        case .verify: String(localized: "Aussagen prüfen")
        case .review: String(localized: "Deine Prüfung")
        case .outline: String(localized: "Gliederung")
        case .script: String(localized: "Skript schreiben")
        case .check: String(localized: "Skript prüfen")
        case .speech: String(localized: "Vertonen")
        case .done: String(localized: "Fertig")
        }
    }

    static let visible: [PipelineStage] = [.plan, .search, .fetch, .extract, .verify, .review, .outline, .script, .check, .speech]
}

struct PipelineEvent: Sendable {
    let stage: PipelineStage
    let fraction: Double?
    let message: String
}
