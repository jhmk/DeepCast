import Foundation
import Observation

/// The podcast style guide ("Podcast-Leitfaden"): editable Markdown that is sent with every
/// narrative, script, revision and review call. It shapes style only; fact rules stay in code.
@MainActor
@Observable
final class StyleGuideStore {
    private(set) var text: String
    let fileURL: URL

    init(fileURL: URL = AppPaths.applicationSupport().appending(path: "Podcast-Leitfaden.md")) {
        self.fileURL = fileURL
        if let stored = try? String(contentsOf: fileURL, encoding: .utf8), !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = stored
        } else {
            text = Self.defaultText
        }
    }

    nonisolated static var defaultText: String {
        guard let url = Bundle.main.url(forResource: "Podcast-Leitfaden", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return fallback }
        return text
    }

    /// Minimal guide if the bundled file is missing (e.g. in some test hosts).
    nonisolated static let fallback = """
    # Podcast-Leitfaden
    - Echter Podcast mit Aufhänger, Leitfrage, rotem Faden, Erklärketten und Schluss mit Rückgriff.
    - Sprecher reden miteinander, kurze Reaktionen, keine Faktenlisten, keine Wiederholungen.
    - Keine Floskeln wie „laut einer Quelle“; Herkunft konkret nennen, Unsicherheit einmal pro Thema.
    """

    func update(_ newText: String) {
        text = newText
        save()
    }

    func resetToDefault() {
        text = Self.defaultText
        save()
    }

    /// Appends confirmed rules from user feedback (section "Aus deinen Rückmeldungen").
    func appendRules(_ rules: [String], episodeTitle: String, date: Date = .now) {
        let cleaned = rules.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        let heading = "## Aus deinen Rückmeldungen"
        var body = text
        if !body.contains(heading) { body += "\n\n" + heading + "\n" }
        let stamp = date.formatted(date: .numeric, time: .omitted)
        body += "\n" + cleaned.map { "- \($0) _(\(stamp), „\(episodeTitle)“)_" }.joined(separator: "\n") + "\n"
        update(body)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Compact version for small models (Apple Intelligence): headings and first-level bullets
    /// of the rule sections, no examples.
    nonisolated static func short(_ guide: String, limit: Int = 1_800) -> String {
        // The user's own rules (from feedback) come first – they must survive the length limit.
        var own: [String] = []
        var lines: [String] = []
        var skip = false
        var inOwn = false
        for line in guide.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                skip = line.lowercased().contains("beispiel")
                inOwn = line.contains("Rückmeldungen")
            }
            guard !skip else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.range(of: #"^\d+\."#, options: .regularExpression) != nil {
                if inOwn { own.append(trimmed) } else { lines.append(trimmed) }
            }
        }
        lines = own + lines
        var result = ""
        for line in lines where result.count + line.count < limit { result += line + "\n" }
        return result
    }
}
