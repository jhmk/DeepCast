import Foundation

/// Traffic-light rules (spec 5.4/5.5) as configuration, not scattered through the code.
struct FactCheckRules: Sendable {
    var strictness: FactCheckStrictness = .standard
    /// Number claims older than this are shown with "Stand <Jahr>" (yellow).
    var staleNumberYears = 5
    /// Verifier did not run (e.g. all models unavailable): best possible light.
    var unverifiedCap: TrafficLight = .yellow
    /// Standard mode: a reference work (Wikipedia, Wikivoyage, Britannica) alone makes
    /// definitions and historical dates green (deviation from spec 5.4, decided by the user).
    var referenceWorkSuffices = true

    struct Outcome: Equatable {
        var light: TrafficLight
        var reasons: [String]
    }

    func evaluate(_ claim: Claim, sources: [SourceDocument], now: Date = .now) -> Outcome {
        var reasons: [String] = []
        let cited = claim.evidence.compactMap { evidence in sources.first { $0.id == evidence.sourceID } }
        guard !cited.isEmpty else { return Outcome(light: .red, reasons: ["Keine Quelle"]) }

        // Hard failures.
        if claim.verdict == .contradicted { return Outcome(light: .red, reasons: ["Vom Prüfer als widerlegt bewertet"]) }
        if claim.verdict == .notEnoughInfo, claim.type.needsEvidence {
            return Outcome(light: .red, reasons: ["Belegstelle reicht laut Prüfer nicht aus"])
        }
        if let numbers = claim.numberCheck, !numbers.passed {
            return Outcome(light: .red, reasons: ["Zahl nicht im Beleg gefunden: \(numbers.missing.joined(separator: ", "))"])
        }

        // Opinions and anecdotes need no proof but must be framed as such.
        if !claim.type.needsEvidence {
            return Outcome(light: .yellow, reasons: ["\(claim.type.label) – im Skript als solche kennzeichnen"])
        }

        // Source strength and independence.
        var bestByPublisher: [String: TrustTier] = [:]
        for source in cited where source.tier != .d {
            bestByPublisher[source.independenceKey] = min(bestByPublisher[source.independenceKey] ?? .d, source.tier)
        }
        let tiers = bestByPublisher.values.sorted()
        let countA = tiers.filter { $0 == .a }.count
        let countB = tiers.filter { $0 == .b }.count
        let countBC = tiers.filter { $0 == .b || $0 == .c }.count
        let independent = tiers.count

        var light: TrafficLight
        switch strictness {
        case .standard:
            let referenceWork = cited.contains { [.wikipedia, .wikivoyage].contains($0.kind) || $0.publisher.contains("britannica") }
            if referenceWorkSuffices, referenceWork, [.definition, .historical].contains(claim.type), countB >= 1 {
                // Definitions and historical dates from a reference work need no second source (ADR-012).
                light = .green
                reasons.append("Nachschlagewerk genügt für Definitionen und historische Daten")
            } else if countA >= 1 || (countB >= 1 && countBC >= 2) {
                light = .green
            } else if countB >= 1 || independent >= 2 {
                light = .yellow
                reasons.append(countB >= 1 ? "Nur eine Quelle (Stufe B)" : "Nur schwächere Quellen (Stufe C)")
            } else if independent == 1 {
                light = .yellow
                reasons.append("Nur eine schwache Quelle (Stufe C)")
            } else {
                light = .red
                reasons.append("Nur Social Media/Forum als Quelle")
            }
        case .strict:
            if countA >= 1 || countB >= 2 {
                light = .green
            } else if countB >= 1 {
                light = .yellow
                reasons.append("Streng: braucht Stufe A oder zwei unabhängige B-Quellen")
            } else {
                light = .red
                reasons.append("Streng: keine Quelle der Stufe A/B")
            }
        }
        if independent >= 2 { reasons.append("\(independent) unabhängige Quellen") }

        // Caps.
        func cap(_ maximum: TrafficLight, _ reason: String) {
            if light < maximum { light = maximum }
            reasons.append(reason)
        }
        switch claim.verdict {
        case .partiallySupported: cap(.yellow, "Nur teilweise belegt")
        case nil: cap(unverifiedCap, "Nicht vom Prüfer bewertet")
        default: break
        }
        if claim.evidence.allSatisfy({ $0.match == .approximate }) { cap(.yellow, "Beleg nur sinngemäß gefunden") }
        if let others = claim.contestedWith, !others.isEmpty {
            cap(.yellow, "Umstritten: andere Quelle nennt abweichende Zahl (\(others.joined(separator: ", ")))")
        }
        if claim.type == .scientificConsensus, countA == 0 { cap(.yellow, "Konsens-Aussage ohne Quelle der Stufe A") }
        if cited.allSatisfy({ $0.integrityWarning != nil }), let warning = cited.first?.integrityWarning {
            cap(.yellow, warning)
        }
        if cited.allSatisfy({ SourceTrust.isPreprint(host: $0.url.host() ?? "") }) { cap(.yellow, "Nur Preprint (nicht begutachtet)") }
        if let rounded = claim.numberCheck?.rounded, !rounded.isEmpty { reasons.append("Gerundet: \(rounded.joined(separator: ", "))") }
        if claim.type == .number,
           let newest = cited.compactMap({ $0.kind == .web ? $0.publishedAt : nil }).max(),
           let years = Calendar.current.dateComponents([.year], from: newest, to: now).year,
           years >= staleNumberYears {
            cap(.yellow, "Zahl von \(Calendar.current.component(.year, from: newest)) – „Stand“ nennen")
        }
        if light == .red { return Outcome(light: .red, reasons: reasons) }
        return Outcome(light: light, reasons: reasons)
    }
}

/// Merges duplicate claims from different sources so corroboration counts (independence).
enum ClaimMerger {
    static let similarityThreshold = 0.6

    static func merge(_ claims: [Claim]) -> [Claim] {
        var merged: [Claim] = []
        for claim in claims {
            if let index = merged.firstIndex(where: { isDuplicate($0, claim) }) {
                for evidence in claim.evidence where !merged[index].evidence.contains(where: { $0.sourceID == evidence.sourceID }) {
                    merged[index].evidence.append(evidence)
                }
            } else {
                merged.append(claim)
            }
        }
        return merged.enumerated().map { index, claim in
            var renumbered = claim
            renumbered.id = "K\(index + 1)"
            return renumbered
        }
    }

    static func isDuplicate(_ lhs: Claim, _ rhs: Claim) -> Bool {
        let lhsNumbers = Set(NumberMatcher.numbers(in: lhs.text).map(\.value))
        let rhsNumbers = Set(NumberMatcher.numbers(in: rhs.text).map(\.value))
        guard lhsNumbers == rhsNumbers else { return false }
        let a = Set(TextChunker.terms(lhs.text).map { String($0.prefix(6)) })
        let b = Set(TextChunker.terms(rhs.text).map { String($0.prefix(6)) })
        guard !a.isEmpty, !b.isEmpty else { return false }
        return Double(a.intersection(b).count) / Double(a.union(b).count) >= similarityThreshold
    }
}

/// Detects syndication: near-identical texts on different sites count as one source (spec 5.2).
enum SyndicationDetector {
    static let threshold = 0.5

    /// Word 5-gram shingles of the first ~1500 words.
    static func shingles(_ text: String) -> Set<Int> {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.prefix(1500)
        guard words.count >= 5 else { return [] }
        let array = Array(words)
        return Set((0...(array.count - 5)).map { array[$0..<($0 + 5)].joined(separator: " ").hashValue })
    }

    static func similarity(_ lhs: Set<Int>, _ rhs: Set<Int>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        // Containment: a short copy inside a longer article also counts.
        return Double(lhs.intersection(rhs).count) / Double(min(lhs.count, rhs.count))
    }

    /// Groups web/podcast sources with near-identical text. Returns notes for the report.
    static func mark(_ sources: inout [SourceDocument]) -> [String] {
        let candidates = sources.indices.filter { sources[$0].kind == .web }
        let sets = Dictionary(uniqueKeysWithValues: candidates.map { ($0, shingles(sources[$0].chunks.map(\.text).joined(separator: " "))) })
        var notes: [String] = []
        for (position, i) in candidates.enumerated() {
            for j in candidates.dropFirst(position + 1) where sources[i].publisher != sources[j].publisher {
                guard similarity(sets[i] ?? [], sets[j] ?? []) >= threshold else { continue }
                let group = sources[i].syndicationGroup ?? sources[j].syndicationGroup ?? sources[i].id
                sources[i].syndicationGroup = group
                sources[j].syndicationGroup = group
                let note = String(localized: "Fast gleicher Text wie \(sources[i].id) (\(sources[i].publisher)) – zählt nicht als unabhängige Quelle")
                if !sources[j].notes.contains(note) { sources[j].notes.append(note) }
                notes.append(String(localized: "\(sources[i].id) und \(sources[j].id) sind (fast) identisch – zählen als eine Quelle."))
            }
        }
        return notes
    }
}

/// Finds claims that describe the same thing with different numbers (spec 5.4).
enum ContradictionDetector {
    static let topicThreshold = 0.55

    static func mark(_ claims: inout [Claim]) -> [String] {
        var notes: [String] = []
        let numbers = claims.map { Set(NumberMatcher.numbers(in: $0.text).map(\.value)) }
        let terms = claims.map { Set(TextChunker.terms($0.text).map { String($0.prefix(6)) }) }
        for i in claims.indices where !numbers[i].isEmpty {
            for j in claims.indices where j > i && !numbers[j].isEmpty && numbers[i] != numbers[j] {
                guard Set(claims[i].sourceIDs).isDisjoint(with: claims[j].sourceIDs),
                      !terms[i].isEmpty, !terms[j].isEmpty else { continue }
                let overlap = Double(terms[i].intersection(terms[j]).count) / Double(terms[i].union(terms[j]).count)
                guard overlap >= topicThreshold else { continue }
                claims[i].contestedWith = (claims[i].contestedWith ?? []) + [claims[j].id]
                claims[j].contestedWith = (claims[j].contestedWith ?? []) + [claims[i].id]
                notes.append(String(localized: "Möglicher Widerspruch: \(claims[i].id) und \(claims[j].id) nennen unterschiedliche Zahlen."))
            }
        }
        return notes
    }
}
