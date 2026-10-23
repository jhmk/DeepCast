import Foundation

/// Prepares script text for speech: strips markup the model may produce and applies the
/// pronunciation dictionary (whole-word replacement).
enum TextNormalizer {
    static func normalize(_ text: String, pronunciations: [String: String] = [:]) -> String {
        var result = text
        // Markdown emphasis and headings are read aloud literally by most voices.
        for token in ["**", "__", "*", "#", "`"] {
            result = result.replacingOccurrences(of: token, with: "")
        }
        // Stage directions in square brackets like [lacht] must not be spoken.
        result = result.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        for (word, spoken) in pronunciations where !word.isEmpty {
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#
            result = result.replacingOccurrences(of: pattern, with: spoken, options: .regularExpression)
        }
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
