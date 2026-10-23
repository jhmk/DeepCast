import Foundation

/// Deterministic check that a quote really appears in the source text (spec 5.3).
enum EvidenceMatcher {
    static let minimumQuoteLength = 20
    static let approximateThreshold = 0.88

    static func normalize(_ text: String) -> String {
        var result = text.lowercased()
        let replacements: [(String, String)] = [
            ("„", "\""), ("“", "\""), ("”", "\""), ("«", "\""), ("»", "\""), ("‚", "'"), ("‘", "'"), ("’", "'"),
            ("–", "-"), ("—", "-"), ("\u{00AD}", ""), ("\u{00A0}", " "), ("\u{202F}", " "), ("…", "..."),
        ]
        for (from, to) in replacements { result = result.replacingOccurrences(of: from, with: to) }
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".,;:\"'")))
    }

    /// Exact (normalised substring) or approximate (≥ 88 % token overlap in a window) match.
    static func match(quote: String, in text: String) -> QuoteMatch? {
        let quoteNorm = normalize(quote)
        guard quoteNorm.count >= minimumQuoteLength, !quoteNorm.contains("...") || quoteNorm.count > 60 else { return nil }
        let textNorm = normalize(text)
        if textNorm.contains(quoteNorm) { return .exact }

        let quoteTokens = tokens(quoteNorm)
        let textTokens = tokens(textNorm)
        guard quoteTokens.count >= 4, textTokens.count >= quoteTokens.count else { return nil }
        let window = quoteTokens.count
        let quoteCounts = quoteTokens.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        var best = 0.0
        for start in 0...(textTokens.count - window) {
            var counts = quoteCounts
            var hits = 0
            for token in textTokens[start..<(start + window)] where (counts[token] ?? 0) > 0 {
                counts[token]! -= 1
                hits += 1
            }
            best = max(best, Double(hits) / Double(window))
            if best >= 0.999 { break }
        }
        return best >= approximateThreshold ? .approximate : nil
    }

    private static func tokens(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}

/// Deterministic number check (spec 5.4): every number in a claim must occur in its evidence.
enum NumberMatcher {
    struct Number: Hashable, Sendable {
        let raw: String
        let value: Double
    }

    static let roundingTolerance = 0.05

    private static let multipliers: [String: Double] = [
        "tausend": 1e3, "thousand": 1e3, "million": 1e6, "millionen": 1e6, "mio": 1e6, "millions": 1e6,
        "milliarde": 1e9, "milliarden": 1e9, "mrd": 1e9, "billion": 1e9, "billions": 1e9,
    ]

    /// Numbers written with digits, with German/English separators and magnitude words.
    static func numbers(in text: String, includeWords: Bool = false) -> [Number] {
        var results: [Number] = []
        let pattern = #"(\d{1,3}(?:[.,\x{00A0}\x{202F} ]\d{3})+|\d+(?:[.,]\d+)?)(?:\s*(tausend|thousand|millionen|million|millions|mio|milliarden|milliarde|mrd|billions|billion)\b)?"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: match.range)
                guard var value = parse(ns.substring(with: match.range(at: 1))) else { continue }
                if match.range(at: 2).location != NSNotFound {
                    value *= multipliers[ns.substring(with: match.range(at: 2)).lowercased()] ?? 1
                }
                results.append(Number(raw: raw.trimmingCharacters(in: .whitespaces), value: value))
            }
        }
        if includeWords {
            let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
            for (index, word) in words.enumerated() {
                guard var value = wordValue(word) else { continue }
                if index + 1 < words.count, let multiplier = multipliers[words[index + 1]], multiplier > 1_000 {
                    value *= multiplier
                }
                results.append(Number(raw: word, value: value))
            }
        }
        return results
    }

    // MARK: Number words ("dreihundertfünfzig", "einundzwanzig", "achtzig", "twenty")

    private static let germanUnits: [String: Double] = [
        "eins": 1, "ein": 1, "zwei": 2, "drei": 3, "vier": 4, "fünf": 5, "sechs": 6, "sieben": 7, "acht": 8, "neun": 9,
    ]
    private static let germanTeens: [String: Double] = [
        "null": 0, "zehn": 10, "elf": 11, "zwölf": 12, "dreizehn": 13, "vierzehn": 14, "fünfzehn": 15,
        "sechzehn": 16, "siebzehn": 17, "achtzehn": 18, "neunzehn": 19,
    ]
    private static let germanTens: [String: Double] = [
        "zwanzig": 20, "dreißig": 30, "vierzig": 40, "fünfzig": 50, "sechzig": 60, "siebzig": 70, "achtzig": 80, "neunzig": 90,
    ]
    private static let englishWords: [String: Double] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100, "thousand": 1_000, "half": 0.5,
    ]

    /// Value of a single number word. "ein"/"eine" alone are articles and ignored.
    static func wordValue(_ word: String) -> Double? {
        if word == "ein" || word.hasPrefix("eine") { return nil }
        if let value = englishWords[word] { return value }
        if word == "halbe" || word == "halb" { return 0.5 }
        if word == "hundert" { return 100 }
        if word == "tausend" { return 1_000 }
        // Inflected forms: "zweien", "dreien", "vieren" are rare; "Jahren" etc. are not numbers.
        return parseGerman(word)
    }

    private static func parseGerman(_ word: String) -> Double? {
        guard !word.isEmpty else { return nil }
        if let range = word.range(of: "tausend") {
            let left = String(word[..<range.lowerBound]), right = String(word[range.upperBound...])
            let factor = left.isEmpty ? 1 : parseGerman(left)
            let rest = right.isEmpty ? 0 : parseGerman(right)
            guard let factor, let rest else { return nil }
            return factor * 1_000 + rest
        }
        if let range = word.range(of: "hundert") {
            let left = String(word[..<range.lowerBound]), right = String(word[range.upperBound...])
            let factor = left.isEmpty ? 1 : germanUnits[left]
            let rest = right.isEmpty ? 0 : parseGerman(right)
            guard let factor, let rest else { return nil }
            return factor * 100 + rest
        }
        if let value = germanTeens[word] ?? germanTens[word] ?? germanUnits[word] { return value }
        if let range = word.range(of: "und") {
            guard let unit = germanUnits[String(word[..<range.lowerBound])],
                  let tens = germanTens[String(word[range.upperBound...])] else { return nil }
            return tens + unit
        }
        return nil
    }

    /// "1.300" / "1 300" / "1,300" → 1300; "1,5" / "1.5" → 1.5
    static func parse(_ raw: String) -> Double? {
        let compact = raw.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        if compact.range(of: #"^\d{1,3}([., ]\d{3})+$"#, options: .regularExpression) != nil {
            return Double(compact.filter(\.isNumber))
        }
        return Double(compact.replacingOccurrences(of: ",", with: "."))
    }

    static func check(claim: String, evidence: [String]) -> NumberCheckResult {
        let claimNumbers = numbers(in: claim)
        let claimQuantities = UnitConverter.quantities(in: claim)
        let evidenceQuantities = evidence.flatMap { UnitConverter.quantities(in: $0) }
        let evidenceNumbers = evidence.flatMap { numbers(in: $0, includeWords: true) }
        var missing: [String] = []
        var rounded: [String] = []
        for number in claimNumbers {
            if evidenceNumbers.contains(where: { $0.value == number.value }) { continue }
            // Same quantity in another unit ("300.000 km/s" ↔ "299.792.458 m/s")?
            if let quantity = claimQuantities.first(where: { $0.raw.hasPrefix(number.raw) || $0.number == number.value }),
               UnitConverter.matches(quantity, in: evidenceQuantities, tolerance: roundingTolerance) {
                rounded.append("\(quantity.raw) (umgerechnet)")
                continue
            }
            let close = evidenceNumbers.contains { candidate in
                candidate.value != 0 && abs(candidate.value - number.value) / abs(candidate.value) <= roundingTolerance
            }
            // Years (four plain digits) and small integers must match exactly.
            let isYear = number.raw.range(of: #"^(1[0-9]|20|21)\d\d$"#, options: .regularExpression) != nil
            if close, !isYear, number.value > 20 {
                rounded.append(number.raw)
            } else {
                missing.append(number.raw)
            }
        }
        return NumberCheckResult(checked: claimNumbers.map(\.raw), missing: missing, rounded: rounded)
    }
}
