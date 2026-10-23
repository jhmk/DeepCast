import Foundation
import SwiftData

enum EpisodeStatus: String, Codable, Sendable {
    case researching    // pipeline stages 1–5
    case review         // waiting for the user's review of sources and claims
    case scripting      // outline, script, script check
    case draft          // script exists, no audio yet
    case needsRender    // script changed after rendering
    case rendering
    case ready
    case failed

    var label: String {
        switch self {
        case .researching: String(localized: "Recherche …")
        case .review: String(localized: "Prüfung offen")
        case .scripting: String(localized: "Skript …")
        case .draft: String(localized: "Entwurf")
        case .needsRender: String(localized: "Neu vertonen")
        case .rendering: String(localized: "Wird vertont …")
        case .ready: String(localized: "Fertig")
        case .failed: String(localized: "Fehler")
        }
    }
}

@Model
final class Episode {
    @Attribute(.unique) var id: UUID
    var title: String
    var topic: String
    var createdAt: Date
    /// Folder name inside ~/Music/DeepCast.
    var folderName: String
    var language: String
    var statusRaw: String
    var duration: Double
    var playbackPosition: Double
    var audioFileName: String?
    var chaptersData: Data?
    var renderNote: String?
    var lastError: String?
    /// JSON-encoded EpisodeOptions (nil for manual scripts).
    var optionsData: Data?
    @Relationship(deleteRule: .cascade, inverse: \EpisodeSegment.episode)
    var segments: [EpisodeSegment] = []

    init(title: String, topic: String, language: String = "de", createdAt: Date = .now) {
        id = UUID()
        self.title = title
        self.topic = topic
        self.createdAt = createdAt
        self.language = language
        folderName = AppPaths.episodeFolderName(topic: title, date: createdAt)
        statusRaw = EpisodeStatus.draft.rawValue
        duration = 0
        playbackPosition = 0
    }

    var status: EpisodeStatus {
        get { EpisodeStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    var sortedSegments: [EpisodeSegment] {
        segments.sorted { $0.order < $1.order }
    }

    var chapters: [ChapterMarker] {
        get { chaptersData.flatMap { try? JSONDecoder().decode([ChapterMarker].self, from: $0) } ?? [] }
        set { chaptersData = try? JSONEncoder().encode(newValue) }
    }

    var options: EpisodeOptions? {
        get { optionsData.flatMap { try? JSONDecoder().decode(EpisodeOptions.self, from: $0) } }
        set { optionsData = try? JSONEncoder().encode(newValue) }
    }

    var isResearchEpisode: Bool { optionsData != nil }

    /// Expected length from the script's word count (before rendering).
    var estimatedDuration: TimeInterval {
        let words = segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        let perMinute = (EpisodeLanguage(rawValue: language) ?? .de).wordsPerMinute
        return Double(words) / Double(perMinute) * 60
    }

    var folderURL: URL {
        AppPaths.episodesRoot().appending(path: folderName, directoryHint: .isDirectory)
    }

    var audioURL: URL? {
        audioFileName.map { folderURL.appending(path: $0) }
    }

    /// Marks rendered audio as outdated after an edit.
    func markEdited() {
        if status == .ready || status == .failed { status = .needsRender }
    }

    func renumberSegments() {
        for (index, segment) in sortedSegments.enumerated() { segment.order = index }
    }
}

@Model
final class EpisodeSegment {
    @Attribute(.unique) var id: UUID
    var order: Int
    var speakerID: String
    var text: String
    var section: String
    var claimIDs: [String]
    var sourceIDs: [String]
    var startTime: Double
    var duration: Double
    var renderedProvider: String?
    var episode: Episode?

    init(order: Int, speakerID: String, text: String, section: String, claimIDs: [String] = [], sourceIDs: [String] = []) {
        id = UUID()
        self.order = order
        self.speakerID = speakerID
        self.text = text
        self.section = section
        self.claimIDs = claimIDs
        self.sourceIDs = sourceIDs
        startTime = 0
        duration = 0
    }

    func contains(time: Double) -> Bool {
        duration > 0 && time >= startTime && time < startTime + duration
    }
}
