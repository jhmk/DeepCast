import AppKit
import Foundation
import UniformTypeIdentifiers

/// "Speichern" for audio and transcript: save panels, MP3 conversion, folder export.
@MainActor
enum EpisodeSaver {
    enum AudioFormat: String, CaseIterable { case m4a, mp3 }
    enum TranscriptFormat: String, CaseIterable {
        case txt, md, vtt
        var label: String {
            switch self {
            case .txt: String(localized: "Text (.txt)")
            case .md: String(localized: "Markdown (.md)")
            case .vtt: String(localized: "Untertitel (.vtt)")
            }
        }
    }

    static func baseName(_ episode: Episode) -> String { episode.folderName }

    /// Plain text transcript from markdown ("**Max** (0:12): …" → "Max (0:12): …").
    static func plainText(fromMarkdown markdown: String) -> String {
        markdown.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"(?m)^#+\s*"#, with: "", options: .regularExpression)
    }

    static func saveAudio(_ episode: Episode, format: AudioFormat) async throws -> URL? {
        guard let m4a = episode.audioURL else { return nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(baseName(episode)).\(format.rawValue)"
        panel.allowedContentTypes = [format == .mp3 ? .mp3 : .mpeg4Audio]
        guard panel.runModal() == .OK, let target = panel.url else { return nil }
        try? FileManager.default.removeItem(at: target)
        if format == .m4a {
            try FileManager.default.copyItem(at: m4a, to: target)
        } else {
            try await AudioAssembler().exportMP3(from: m4a, to: target)
        }
        return target
    }

    static func saveTranscript(_ episode: Episode, format: TranscriptFormat) throws -> URL? {
        let folder = episode.folderURL
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(baseName(episode)) – Transkript.\(format.rawValue)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .plainText]
        guard panel.runModal() == .OK, let target = panel.url else { return nil }
        let text: String
        switch format {
        case .vtt: text = try String(contentsOf: folder.appending(path: "transcript.vtt"), encoding: .utf8)
        case .md: text = try String(contentsOf: folder.appending(path: "transcript.md"), encoding: .utf8)
        case .txt: text = plainText(fromMarkdown: try String(contentsOf: folder.appending(path: "transcript.md"), encoding: .utf8))
        }
        try text.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    /// Audio (M4A + MP3), transcripts, show notes and fact-check report into a chosen folder.
    static func saveAll(_ episode: Episode) async throws -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Hier speichern")
        guard panel.runModal() == .OK, let parent = panel.url else { return nil }
        let target = parent.appending(path: baseName(episode), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let folder = episode.folderURL
        let fm = FileManager.default
        if let m4a = episode.audioURL {
            let audio = target.appending(path: "\(baseName(episode)).m4a")
            try? fm.removeItem(at: audio)
            try fm.copyItem(at: m4a, to: audio)
            try? await AudioAssembler().exportMP3(from: m4a, to: target.appending(path: "\(baseName(episode)).mp3"))
        }
        for name in ["transcript.md", "transcript.vtt", "shownotes.md", "factcheck.md", "factcheck.json"] {
            let source = folder.appending(path: name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = target.appending(path: name)
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: source, to: destination)
        }
        if let markdown = try? String(contentsOf: folder.appending(path: "transcript.md"), encoding: .utf8) {
            try plainText(fromMarkdown: markdown).write(to: target.appending(path: "transcript.txt"), atomically: true, encoding: .utf8)
        }
        return target
    }
}
