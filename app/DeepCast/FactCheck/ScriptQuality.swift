import Foundation

/// Measurable quality of a script against the podcast models (ADR-012).
struct ScriptQualityReport: Codable, Sendable, Hashable {
    var format: DialogFormat
    var words: Int
    var estimatedMinutes: Double
    var turnsPerMinute: Double
    var mainShare: Double?
    var shortReactionShare: Double
    var medianWords: Int
    var fillerCount: Int
    var repeatedClaims: [String]
    var repeatedPhrases: [String]
    var sectionReturns: Int
    /// Problems derived from the targets (empty = all within range).
    var problems: [String]
    /// Test-listener scores (1–10) and verdict, if a review ran.
    var clarity: Int?
    var structure: Int?
    var naturalness: Int?
    var verdict: String?
    var reviewIssues: [String] = []
    var revised = false

    var reviewScore: Double? {
        guard let clarity, let structure, let naturalness else { return nil }
        return Double(clarity + structure + naturalness) / 3
    }

    var summary: String {
        var parts = [
            String(format: "%.1f Wechsel/min", turnsPerMinute),
            "\(Int((shortReactionShare * 100).rounded())) % kurze Reaktionen",
            "\(fillerCount) Floskeln",
        ]
        if let mainShare { parts.insert("Hauptstimme \(Int((mainShare * 100).rounded())) %", at: 0) }
        if let reviewScore { parts.append(String(format: "Testhörer %.1f/10", reviewScore)) }
        return parts.joined(separator: " · ")
    }
}

enum ScriptQuality {
    static let fillers = ["laut einer quelle", "laut derselben quelle", "das ist wirklich faszinierend", "das ist interessant",
                          "interessant", "genau.", "genau,", "spannend, oder", "wie bereits erwähnt"]

    static func measure(_ segments: [ScriptSegmentDraft], format: DialogFormat, cast: [Persona], wordsPerMinute: Int) -> ScriptQualityReport {
        let counts = segments.map { $0.text.split(whereSeparator: \.isWhitespace).count }
        let words = counts.reduce(0, +)
        let minutes = max(0.1, Double(words) / Double(max(1, wordsPerMinute)))
        var turns = 0
        for index in segments.indices.dropFirst() where segments[index].speakerID != segments[index - 1].speakerID { turns += 1 }
        let main = DialogFormat.mainVoice(format, cast: cast)?.id
        let mainWords = zip(segments, counts).filter { $0.0.speakerID == main }.map(\.1).reduce(0, +)
        let shortShare = segments.isEmpty ? 0 : Double(counts.filter { $0 <= 6 }.count) / Double(segments.count)
        let sorted = counts.sorted()
        let lower = segments.map { $0.text.lowercased() }.joined(separator: "\n")
        let fillerCount = fillers.reduce(0) { $0 + lower.components(separatedBy: $1).count - 1 }

        // Claims used more than once outside the closing section.
        let lastSection = segments.last?.section
        var seen: [String: Int] = [:]
        for segment in segments where segment.section != lastSection {
            for id in Set(segment.claimIDs) { seen[id, default: 0] += 1 }
        }
        let repeatedClaims = seen.filter { $0.value > 1 }.map(\.key).sorted()

        // Repeated 6-word phrases (copy-paste repetitions, repeated quotes).
        var grams: [String: Int] = [:]
        for segment in segments {
            let tokens = segment.text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
            guard tokens.count >= 6 else { continue }
            var local = Set<String>()
            for start in 0...(tokens.count - 6) { local.insert(tokens[start..<(start + 6)].joined(separator: " ")) }
            for gram in local { grams[gram, default: 0] += 1 }
        }
        let repeatedPhrases = grams.filter { $0.value > 1 }.map(\.key).sorted().prefix(5).map { $0 }

        // Returning to an earlier section = topic jump.
        var order: [String] = []
        var returns = 0
        for segment in segments {
            if order.last == segment.section { continue }
            if order.contains(segment.section) { returns += 1 }
            order.append(segment.section)
        }

        var report = ScriptQualityReport(
            format: format, words: words, estimatedMinutes: minutes, turnsPerMinute: Double(turns) / minutes,
            mainShare: format == .monologue || format == .conversation || words == 0 ? nil : Double(mainWords) / Double(words),
            shortReactionShare: shortShare, medianWords: sorted.isEmpty ? 0 : sorted[sorted.count / 2],
            fillerCount: fillerCount, repeatedClaims: repeatedClaims, repeatedPhrases: repeatedPhrases,
            sectionReturns: returns, problems: [])
        report.problems = problems(report, targets: format.targets)
        return report
    }

    static func problems(_ report: ScriptQualityReport, targets: DialogFormat.Targets) -> [String] {
        var problems: [String] = []
        if let share = report.mainShare, let range = targets.mainShare, !range.contains(share) {
            problems.append(String(format: "Hauptstimme hat %.0f %% der Worte (Ziel %.0f–%.0f %%).", share * 100, range.lowerBound * 100, range.upperBound * 100))
        }
        if !targets.turnsPerMinute.contains(report.turnsPerMinute) {
            problems.append(String(format: "%.1f Sprecherwechsel pro Minute (Ziel %.0f–%.0f) – %@.", report.turnsPerMinute,
                                   targets.turnsPerMinute.lowerBound, targets.turnsPerMinute.upperBound,
                                   report.turnsPerMinute > targets.turnsPerMinute.upperBound ? "zu abgehackt, längere Erklärpassagen" : "zu wenig Gespräch"))
        }
        if report.shortReactionShare < targets.shortReactionShare.lowerBound {
            problems.append("Zu wenige kurze Reaktionen (\(Int(report.shortReactionShare * 100)) %) – Gespräch wirkt steif.")
        }
        if report.fillerCount > 1 { problems.append("\(report.fillerCount) Floskeln (z.B. „laut einer Quelle“, „interessant“).") }
        if !report.repeatedClaims.isEmpty { problems.append("Aussagen mehrfach verwendet: \(report.repeatedClaims.joined(separator: ", ")).") }
        if !report.repeatedPhrases.isEmpty { problems.append("Wiederholte Formulierungen/Zitate: „\(report.repeatedPhrases.prefix(2).joined(separator: "“, „"))“.") }
        if report.sectionReturns > 0 { problems.append("\(report.sectionReturns) Themensprünge zurück zu einem früheren Kapitel.") }
        return problems
    }

    /// Revise if measurements or the test listener say so.
    static func needsRevision(_ report: ScriptQualityReport) -> Bool {
        report.problems.count >= 2 || (report.reviewScore ?? 10) < 7.5 || !report.repeatedClaims.isEmpty
    }

    /// Numbered script listing for review and revision prompts.
    static func listing(_ segments: [ScriptSegmentDraft], cast: [Persona], withIDs: Bool, offset: Int = 0) -> String {
        segments.enumerated().map { index, segment in
            let name = cast.first { $0.id == segment.speakerID }?.name ?? segment.speakerID
            let ids = withIDs && !segment.claimIDs.isEmpty ? " [\(segment.claimIDs.joined(separator: ","))]" : ""
            return "\(index + offset) · \(segment.section) · \(name) (\(segment.speakerID)): \(segment.text)\(ids)"
        }.joined(separator: "\n")
    }
}
