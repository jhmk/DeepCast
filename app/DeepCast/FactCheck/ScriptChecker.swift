import Foundation

/// Deterministic script check (spec 5.6): claim IDs must exist and be usable, numbers must
/// come from cited claims, no overclaiming words.
enum ScriptChecker {
    static let overclaimPattern = #"\b(beweist|bewiesen|garantiert|garantieren|heilt|geheilt|zweifellos|ohne jeden zweifel|proves|proven|guaranteed|cures)\b"#

    struct Issue: Equatable, Sendable {
        let index: Int
        let problem: String
    }

    /// Returns cleaned segments (invalid IDs removed) and the issues that need a rewrite.
    static func check(_ segments: [ScriptSegmentDraft], usable: [Claim]) -> (segments: [ScriptSegmentDraft], issues: [Issue]) {
        let byID = Dictionary(uniqueKeysWithValues: usable.map { ($0.id, $0) })
        var cleaned: [ScriptSegmentDraft] = []
        var issues: [Issue] = []
        let closingSection = segments.last(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })?.section
        var usedClaims: [String: Int] = [:]
        var usedQuotes: Set<String> = []
        var vagueSourceCount = 0
        /// Sources whose uncertainty was already named (once per topic is enough).
        var hedgedSources: Set<String> = []

        for var segment in segments {
            segment.text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.text.isEmpty else { continue }
            let index = cleaned.count
            let requested = segment.claimIDs.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            let valid = requested.filter { byID[$0] != nil }
            let invalid = requested.filter { byID[$0] == nil }
            segment.claimIDs = Array(NSOrderedSet(array: valid)) as? [String] ?? valid
            let cited = segment.claimIDs.compactMap { byID[$0] }

            var problems: [String] = []
            if !invalid.isEmpty {
                problems.append("Verweist auf nicht erlaubte Aussagen (\(invalid.joined(separator: ", "))). Nur erlaubte Aussagen verwenden.")
            }
            // Each claim once (the closing recap may refer back without re-reading the fact).
            if segment.section != closingSection {
                let repeated = segment.claimIDs.filter { usedClaims[$0] != nil }
                if !repeated.isEmpty {
                    problems.append("Aussage \(repeated.joined(separator: ", ")) wurde schon in Beitrag \(repeated.compactMap { usedClaims[$0] }.map(String.init).joined(separator: ", ")) gesagt – nicht wiederholen, höchstens kurz darauf zurückverweisen.")
                }
            }
            for id in segment.claimIDs where usedClaims[id] == nil { usedClaims[id] = index }
            for quote in QuoteVerifier.quotedParts(segment.text) {
                let key = EvidenceMatcher.normalize(quote)
                if usedQuotes.contains(key) { problems.append("Zitat wird wiederholt – nur einmal zitieren.") }
                usedQuotes.insert(key)
            }
            let lower = segment.text.lowercased()
            vagueSourceCount += lower.components(separatedBy: "laut einer quelle").count - 1 + lower.components(separatedBy: "laut derselben quelle").count - 1
            if vagueSourceCount > 1, lower.contains("laut einer quelle") || lower.contains("laut derselben quelle") {
                problems.append("„Laut einer Quelle“ höchstens einmal pro Folge – Herkunft konkret nennen (z.B. „eine Studie von 2011“, „das Lexikon“).")
            }
            let alreadyHedged = cited.filter { $0.effectiveLight == .yellow }.allSatisfy { claim in
                claim.sourceIDs.contains(where: hedgedSources.contains)
            }
            problems += contentProblems(segment.text, cited: cited, hedgeAlreadyGiven: alreadyHedged)
            if hasHedge(segment.text) {
                for claim in cited where claim.effectiveLight == .yellow { hedgedSources.formUnion(claim.sourceIDs) }
            }
            if !problems.isEmpty { issues.append(Issue(index: index, problem: problems.joined(separator: " "))) }
            cleaned.append(segment)
        }
        return (cleaned, issues)
    }

    /// Checks of the spoken text against the cited claims (shared by pipeline and editor).
    static func contentProblems(_ text: String, cited: [Claim], hedgeAlreadyGiven: Bool = false) -> [String] {
        var problems: [String] = []
        let missing = unsupportedNumbers(in: text, cited: cited)
        if !missing.isEmpty {
            problems.append(cited.isEmpty
                ? "Enthält Zahlen (\(missing.joined(separator: ", "))) ohne Aussage-ID."
                : "Zahl \(missing.joined(separator: ", ")) steht in keiner der genannten Aussagen.")
        }
        if let quoteProblem = QuoteVerifier.scriptProblem(text, cited: cited) { problems.append(quoteProblem) }
        if text.range(of: overclaimPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            problems.append("Übertreibung (z.B. „beweist“, „garantiert“) – vorsichtiger formulieren.")
        }
        let consensusWords = ["konsens", "forschung ist sich einig", "wissenschaft ist sich einig", "consensus", "scientists agree"]
        if consensusWords.contains(where: text.lowercased().contains),
           !cited.contains(where: { $0.type == .scientificConsensus && $0.effectiveLight == .green }) {
            problems.append("Behauptet einen Forschungskonsens ohne belegte Konsens-Aussage.")
        }
        if cited.contains(where: { $0.effectiveLight == .yellow }), !hedgeAlreadyGiven, !hasHedge(text) {
            problems.append("Stützt sich auf eine unsichere Aussage – Herkunft konkret nennen (z.B. „eine Laborstudie von 2011“) oder die Unsicherheit einmal klar sagen.")
        }
        return problems
    }

    /// Problems of one edited segment (editor re-check, spec 7: "Bearbeitete Segmente werden neu geprüft").
    static func problems(text: String, claimIDs: [String], usable: [Claim]) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: usable.map { ($0.id, $0) })
        let invalid = claimIDs.filter { byID[$0] == nil }
        var problems: [String] = []
        if !invalid.isEmpty {
            problems.append("Aussage(n) \(invalid.joined(separator: ", ")) sind nicht (mehr) verwendbar (rot oder Quelle abgewählt).")
        }
        return problems + contentProblems(text, cited: claimIDs.compactMap { byID[$0] })
    }

    /// Units that make even a small number a factual statement ("zwei Jahre", "drei Arten").
    static let unitWords: Set<String> = [
        "jahr", "jahre", "jahren", "jahres", "monat", "monate", "monaten", "woche", "wochen", "tag", "tage", "tagen",
        "stunde", "stunden", "minute", "minuten", "sekunde", "sekunden", "prozent", "grad", "kelvin", "meter", "metern",
        "kilometer", "millimeter", "mikrometer", "zentimeter", "kilogramm", "gramm", "tonnen", "liter", "arten", "art",
        "gene", "proteine", "beine", "zellen", "mal", "fach", "millionen", "milliarden", "tausend", "hundert",
        "years", "year", "months", "weeks", "days", "hours", "minutes", "percent", "degrees", "species", "times",
    ]

    /// Numbers (digits or words) in a script segment that none of the cited claims support.
    static func unsupportedNumbers(in text: String, cited: [Claim]) -> [String] {
        let support = cited.flatMap { [$0.text] + $0.evidence.map(\.quote) }
        let supported = support.flatMap { NumberMatcher.numbers(in: $0, includeWords: true) }.map(\.value)
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        var missing: [String] = []

        let quantities = UnitConverter.quantities(in: text)
        let supportedQuantities = support.flatMap { UnitConverter.quantities(in: $0) }
        func convertedSupport(_ raw: String) -> Bool {
            guard let quantity = quantities.first(where: { $0.raw.hasPrefix(raw) }) else { return false }
            return UnitConverter.matches(quantity, in: supportedQuantities, tolerance: NumberMatcher.roundingTolerance)
        }

        func isSupported(_ value: Double) -> Bool {
            supported.contains { $0 == value || ($0 != 0 && value > 20 && abs($0 - value) / abs($0) <= NumberMatcher.roundingTolerance) }
        }

        // Digits
        for number in NumberMatcher.numbers(in: text) where number.value > 10 || number.raw.contains(",") || number.raw.contains(".")
            || followedByUnit(number.raw, in: words) {
            if !isSupported(number.value) && !convertedSupport(number.raw) { missing.append(number.raw) }
        }
        // Words
        for (index, word) in words.enumerated() {
            guard let value = NumberMatcher.wordValue(word), value != 0.5 else { continue }
            var total = value
            if index + 1 < words.count, words[index + 1] == "millionen" || words[index + 1] == "million" { total *= 1e6 }
            if index + 1 < words.count, words[index + 1] == "milliarden" { total *= 1e9 }
            let hasUnit = index + 1 < words.count && unitWords.contains(words[index + 1])
            guard value > 10 || hasUnit else { continue }
            if !isSupported(total) && !isSupported(value) { missing.append(word) }
        }
        return missing
    }

    private static func followedByUnit(_ raw: String, in words: [String]) -> Bool {
        let token = raw.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).last ?? raw
        guard let index = words.firstIndex(of: token), index + 1 < words.count else { return false }
        return unitWords.contains(words[index + 1])
    }

    static func hasHedge(_ text: String) -> Bool {
        let hedges = ["laut", "einer quelle", "hinweis", "studie", "untersuchung", "experiment", "versuch", "forscher", "forschende",
                      "wissenschaftler", "lexikon", "wikipedia", "buch", "bericht", "messung", "beobachtet", "fanden", "fand ", "zeigte",
                      "zeigten", "nach heutigem", "nach bisherigem", "bei der untersuchten", "vermutlich", "wahrscheinlich", "möglicherweise", "vielleicht",
                      "stand ", "bisher", "noch nicht", "unklar", "umstritten", "vorläufig", "manche", "einige", "teilweise",
                      "nach angaben", "heißt es", "soll ", "sollen ", "gilt als", "schätz", "etwa", "rund", "ungefähr", "bis zu",
                      "according", "suggest", "may ", "might", "estimate", "reportedly", "about ", "roughly", "so far", "as of"]
        let lower = text.lowercased()
        return hedges.contains { lower.contains($0) }
    }
}

enum ArtifactStore {
    static func save<T: Encodable>(_ value: T, as name: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: folder.appending(path: name), options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, name: String, in folder: URL) -> T? {
        guard let data = try? Data(contentsOf: folder.appending(path: name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }
}

/// Machine-readable fact-check report (spec 5.7: factcheck.json). Source texts are omitted.
struct FactCheckExport: Codable, Sendable {
    struct Source: Codable, Sendable {
        let id, title, publisher, tier, kind: String
        let url: URL
        let publishedAt: Date?
        let included: Bool
        let notes: [String]
    }

    let title: String
    let createdAt: Date
    let strictness: String
    let counts: [String: Int]
    let sources: [Source]
    let claims: [Claim]
    let removedFromScript: [String]
    let notes: [String]

    init(_ dossier: ResearchDossier, title: String) {
        self.title = title
        createdAt = dossier.createdAt
        strictness = dossier.options.strictness.rawValue
        counts = Dictionary(uniqueKeysWithValues: TrafficLight.allCases.map { ($0.rawValue, dossier.count($0)) })
        sources = dossier.sources.map {
            Source(id: $0.id, title: $0.title, publisher: $0.publisher, tier: $0.tier.rawValue, kind: $0.kind.rawValue,
                   url: $0.url, publishedAt: $0.publishedAt, included: $0.included, notes: $0.notes)
        }
        claims = dossier.claims
        removedFromScript = dossier.scriptIssues
        notes = dossier.notes
    }
}

/// Fact-check report (spec 5.7) as Markdown.
enum FactCheckReport {
    static func markdown(_ dossier: ResearchDossier, title: String) -> String {
        let included = dossier.includedSourceIDs
        let claims = dossier.claims.filter { $0.evidence.contains { included.contains($0.sourceID) } }
        var lines = [
            "# Faktencheck: \(title)", "",
            "Stand: \(dossier.createdAt.formatted(date: .long, time: .omitted)) · Strenge: \(dossier.options.strictness.displayName)", "",
            "🟢 \(dossier.count(.green)) · 🟡 \(dossier.count(.yellow)) · 🔴 \(dossier.count(.red)) (entfernt)", "",
        ]
        let verifiers = Dictionary(grouping: claims.compactMap(\.verifierModel), by: { $0 }).mapValues(\.count)
        if !verifiers.isEmpty {
            lines.append("Geprüft von: " + verifiers.map { "\(modelName($0.key)) (\($0.value))" }.sorted().joined(separator: ", "))
            lines.append("")
        }
        lines += ["## Quellen", ""]
        for source in dossier.sources {
            let date = source.publishedAt.map { " · \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
            let excluded = source.included ? "" : " · **abgewählt**"
            lines.append("- [\(source.id)] Stufe \(source.tier.rawValue) · [\(source.title)](\(source.url.absoluteString)) · \(source.publisher)\(date)\(excluded)")
        }
        let tierCounts = Dictionary(grouping: dossier.sources.filter(\.included), by: \.tier).mapValues(\.count)
        lines += ["", "Anteil je Stufe: " + TrustTier.allCases.map { "\($0.rawValue): \(tierCounts[$0] ?? 0)" }.joined(separator: " · "), ""]

        for light in TrafficLight.allCases {
            let group = claims.filter { $0.effectiveLight == light }
            guard !group.isEmpty else { continue }
            lines += ["## \(light.emoji) \(light.label.capitalized) (\(group.count))", ""]
            for claim in group {
                lines.append("### \(claim.id): \(claim.text)")
                var meta = ["Typ: \(claim.type.label)"]
                if let verdict = claim.verdict { meta.append("Prüfer: \(verdict.label)" + (claim.verdictReason.map { " – \($0)" } ?? "")) }
                if claim.type == .quote {
                    meta.append(claim.isParaphrase == true ? "Zitat nicht verifiziert → nur Paraphrase" : "Zitat geprüft (\(claim.quotedPerson ?? "?"))")
                }
                if let others = claim.contestedWith { meta.append("**Umstritten** (vgl. \(others.joined(separator: ", ")))") }
                if let override = claim.userOverride { meta.append("**Manuell überstimmt: \(override.emoji)** (automatisch: \(claim.light.emoji))") }
                lines.append(meta.joined(separator: " · "))
                if !claim.lightReasons.isEmpty { lines.append("Gründe: " + claim.lightReasons.joined(separator: "; ")) }
                for evidence in claim.evidence {
                    let source = dossier.source(evidence.sourceID)
                    let suffix = evidence.match == .approximate ? " _(sinngemäß)_" : ""
                    lines.append("> „\(evidence.quote)“ — [\(evidence.sourceID)] \(source?.publisher ?? "")\(suffix)")
                }
                lines.append("")
            }
        }
        if !dossier.scriptIssues.isEmpty {
            lines += ["## Aus dem Skript entfernt", ""] + dossier.scriptIssues.map { "- \($0)" } + [""]
        }
        if !dossier.notes.isEmpty {
            lines += ["## Hinweise zum Ablauf", ""] + dossier.notes.map { "- \($0)" } + [""]
        }
        lines += ["---", "KI-generiert, automatisch faktengeprüft (Proof of Concept). Keine Garantie für Vollständigkeit."]
        return lines.joined(separator: "\n")
    }

    static func modelName(_ id: String) -> String {
        if id == "apple-on-device" { return "Apple Intelligence" }
        if id.hasPrefix("google/gemini") { return id.replacingOccurrences(of: "google/", with: "") }
        return (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: ":free", with: "")
    }

    /// Numbered source list for the show notes.
    static func sourceLines(_ dossier: ResearchDossier) -> [String] {
        dossier.sources.filter(\.included).enumerated().map { index, source in
            "\(index + 1). [\(source.title)](\(source.url.absoluteString)) – \(source.publisher), Stufe \(source.tier.rawValue)"
        }
    }
}
