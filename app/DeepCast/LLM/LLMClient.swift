import Foundation
import FoundationModels

/// Output types are declared once with `@Generable` (Apple Intelligence) and decoded from
/// JSON for OpenRouter. `GenerationSchema` encodes to JSON Schema, so both share one source.
typealias StructuredOutput = Generable & Decodable & Sendable

enum LLMError: LocalizedError, Equatable {
    case missingKey
    case dailyLimitReached
    case rateLimited(String)
    case unavailable(String)
    case contextTooSmall
    case refused(String)
    case invalidOutput(String)
    case http(status: Int, message: String)

    /// Permanent errors disable the client for the rest of the run.
    var isPermanent: Bool {
        switch self {
        case .missingKey, .dailyLimitReached: true
        case .http(let status, _): [401, 402, 403, 404].contains(status)
        case .unavailable, .rateLimited, .contextTooSmall, .refused, .invalidOutput: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey: String(localized: "Kein OpenRouter-Key im Schlüsselbund.")
        case .dailyLimitReached: String(localized: "OpenRouter: Tageslimit für Gratis-Modelle erreicht.")
        case .rateLimited(let detail): String(localized: "Überlastet (\(detail)).")
        case .unavailable(let detail): String(localized: "Nicht verfügbar: \(detail)")
        case .contextTooSmall: String(localized: "Eingabe zu lang für das Modell.")
        case .refused(let detail): String(localized: "Vom Modell abgelehnt: \(detail)")
        case .invalidOutput(let detail): String(localized: "Ungültige Modellantwort: \(detail)")
        case .http(let status, let message): String(localized: "HTTP \(status): \(message)")
        }
    }
}

protocol LLMClient: Sendable {
    /// Stable identifier, e.g. "qwen/qwen3.8-27b:free" or "apple-on-device".
    var id: String { get }
    var displayName: String { get }
    /// Rough size of the prompt text (characters) that fits comfortably in one request.
    var inputBudgetChars: Int { get }
    func generate<T: StructuredOutput>(_ type: T.Type, system: String, prompt: String, reasoning: Bool) async throws -> T
}

/// Removes code fences and surrounding prose, unwraps a single-element top-level array.
enum JSONResponseCleaner {
    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.components(separatedBy: .newlines).dropFirst()
                .filter { !$0.hasPrefix("```") }.joined(separator: "\n")
        }
        let starts = [text.firstIndex(of: "{"), text.firstIndex(of: "[")].compactMap { $0 }
        if let start = starts.min() {
            let closer: Character = text[start] == "{" ? "}" : "]"
            if let end = text.lastIndex(of: closer), end > start {
                text = String(text[start...end])
            }
        }
        if text.hasPrefix("["),
           let data = text.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
           array.count == 1, array[0] is [String: Any],
           let inner = try? JSONSerialization.data(withJSONObject: array[0]),
           let string = String(data: inner, encoding: .utf8) {
            return string
        }
        return text
    }

    static func decode<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        let cleaned = clean(raw)
        do {
            return try JSONDecoder().decode(T.self, from: Data(cleaned.utf8))
        } catch {
            throw LLMError.invalidOutput(String(cleaned.prefix(160)))
        }
    }
}
