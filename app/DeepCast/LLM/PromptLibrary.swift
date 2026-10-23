import Foundation

/// Loads prompt templates from `Resources/Prompts/*.txt` and fills `{{placeholders}}`.
/// Templates contain "=== SYSTEM ===" and "=== USER ===" parts.
enum PromptLibrary {
    struct Prompt: Sendable {
        let system: String
        let user: String
    }

    enum PromptError: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            switch self { case .missing(let name): String(localized: "Prompt-Datei fehlt: \(name)") }
        }
    }

    static func load(_ name: String, values: [String: String], bundle: Bundle = .main) throws -> Prompt {
        guard let url = bundle.url(forResource: name, withExtension: "txt"),
              let template = try? String(contentsOf: url, encoding: .utf8)
        else { throw PromptError.missing(name) }
        return render(template, values: values)
    }

    static func render(_ template: String, values: [String: String]) -> Prompt {
        var text = template
        for (key, value) in values {
            text = text.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        let parts = text.components(separatedBy: "=== USER ===")
        let system = parts[0].replacingOccurrences(of: "=== SYSTEM ===", with: "")
        let user = parts.count > 1 ? parts[1] : ""
        return Prompt(system: system.trimmingCharacters(in: .whitespacesAndNewlines),
                      user: user.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
