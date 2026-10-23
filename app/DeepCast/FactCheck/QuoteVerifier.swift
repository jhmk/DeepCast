import Foundation

/// Quotes may only be read verbatim if the quoted wording appears in the source and the
/// person is named in the same passage (spec 5.4: "Zitate nur wörtlich aus der Quelle und der
/// richtigen Person zugeordnet. Sonst … als Paraphrase gekennzeichnet").
enum QuoteVerifier {
    struct Result: Equatable {
        let person: String?
        let verbatimAllowed: Bool
    }

    static func verify(claimText: String, speaker: String, chunk: String) -> Result {
        let person = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        let personNamed = !person.isEmpty && personAppears(person, in: chunk)
        let quoted = quotedParts(claimText)
        let wordingFound = !quoted.isEmpty && quoted.allSatisfy { EvidenceMatcher.match(quote: $0, in: chunk) == .exact }
        return Result(person: person.isEmpty ? nil : person, verbatimAllowed: personNamed && wordingFound)
    }

    /// Surname (last word ≥ 3 letters) or full name must appear in the passage.
    static func personAppears(_ person: String, in text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains(person.lowercased()) { return true }
        let parts = person.split(separator: " ").map(String.init).filter { $0.count >= 3 && !$0.hasSuffix(".") }
        guard let surname = parts.last else { return false }
        return lower.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: surname.lowercased()) + #"\b"#, options: .regularExpression) != nil
    }

    /// Text inside „…“, "…", »…« or “…” (at least 15 characters).
    static func quotedParts(_ text: String) -> [String] {
        let pattern = #"[„"»“]([^„"»«“”]{15,})[“"«”]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Script check: verbatim quotation marks are only allowed with a verified quote claim.
    static func scriptProblem(_ text: String, cited: [Claim]) -> String? {
        guard !quotedParts(text).isEmpty else { return nil }
        let verified = cited.filter { $0.type == .quote && $0.isParaphrase != true }
        if verified.isEmpty {
            return "Wörtliches Zitat (Anführungszeichen) ohne geprüfte Zitat-Aussage – als Paraphrase ohne Anführungszeichen formulieren."
        }
        let sources = verified.flatMap { [$0.text] + $0.evidence.map(\.quote) }
        for part in quotedParts(text) where !sources.contains(where: { EvidenceMatcher.match(quote: part, in: $0) == .exact }) {
            return "Zitat „\(part.prefix(40))…“ weicht vom Original ab – wörtlich übernehmen oder paraphrasieren."
        }
        return nil
    }
}
