import Foundation

/// Plain values for writing transcript and show notes off the main actor.
struct ExportSegment: Sendable {
    let speakerName: String
    let text: String
    let section: String
    let start: TimeInterval
    let duration: TimeInterval
}

enum EpisodeExporter {
    /// WebVTT with voice tags – usable for `podcast:transcript` and the in-app transcript.
    static func webVTT(_ segments: [ExportSegment]) -> String {
        var lines = ["WEBVTT", ""]
        for (index, segment) in segments.enumerated() {
            lines.append("\(index + 1)")
            lines.append("\(timestamp(segment.start)) --> \(timestamp(segment.start + segment.duration))")
            lines.append("<v \(segment.speakerName)>\(segment.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func transcriptMarkdown(title: String, segments: [ExportSegment]) -> String {
        var lines = ["# \(title)", ""]
        var section: String?
        for segment in segments {
            if segment.section != section {
                section = segment.section
                lines += ["", "## \(segment.section)", ""]
            }
            lines.append("**\(segment.speakerName)** (\(shortTime(segment.start))): \(segment.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func showNotes(title: String, date: Date, chapters: [ChapterMarker], speakers: [String], renderNote: String?,
                          sources: [String] = [], factCheck: String? = nil) -> String {
        var lines = [
            "# \(title)", "",
            "Stand: \(date.formatted(date: .long, time: .omitted))", "",
            "Sprecher: \(speakers.joined(separator: ", "))", "",
            "## Kapitel", "",
        ]
        lines += chapters.map { "- \(shortTime($0.start)) \($0.title)" }
        lines += ["", "## Quellen", ""]
        lines += sources.isEmpty ? ["Keine (manuelles Skript)."] : sources
        lines.append("")
        if let factCheck { lines += ["## Faktencheck", "", factCheck, "Details: factcheck.md", ""] }
        if let renderNote { lines += ["## Hinweise zur Vertonung", "", renderNote, ""] }
        lines += ["---", sources.isEmpty ? "KI-generiert mit DeepCast." : "KI-generiert, automatisch faktengeprüft (DeepCast)."]
        return lines.joined(separator: "\n")
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let millis = Int((max(0, seconds) * 1000).rounded())
        return String(
            format: "%02d:%02d:%02d.%03d",
            millis / 3_600_000, (millis / 60_000) % 60, (millis / 1000) % 60, millis % 1000
        )
    }

    static func shortTime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Copies the audio file to iCloud Drive/DeepCast so it can be played on the iPhone (Files app).
    static func copyToICloud(_ audioURL: URL, fileName: String) throws -> URL {
        let fm = FileManager.default
        let folder = AppPaths.iCloudExportFolder()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appending(path: fileName)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: audioURL, to: target)
        return target
    }
}
