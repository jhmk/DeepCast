import Foundation

/// Central place for on-disk locations.
enum AppPaths {
    /// Root folder for episodes: ~/Music/DeepCast
    static func episodesRoot(fileManager: FileManager = .default) -> URL {
        let music = fileManager.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Music")
        return music.appending(path: "DeepCast", directoryHint: .isDirectory)
    }

    /// Cache for rendered speech segments (hash of text + voice + rate).
    static func speechCache(fileManager: FileManager = .default) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return caches.appending(path: "DeepCast/Speech", directoryHint: .isDirectory)
    }

    /// ~/Library/Application Support/DeepCast
    static func applicationSupport(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "DeepCast", directoryHint: .isDirectory)
    }

    static func personasFile(fileManager: FileManager = .default) -> URL {
        applicationSupport(fileManager: fileManager).appending(path: "personas.json")
    }

    /// iCloud Drive export folder, used by "Auf iPhone verfügbar machen".
    static func iCloudExportFolder(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs/DeepCast", directoryHint: .isDirectory)
    }

    /// Turns a topic into a safe folder name, e.g. "Wie funktionieren Tardigraden?" →
    /// "2026-10-03 Wie funktionieren Tardigraden".
    static func episodeFolderName(topic: String, date: Date) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.newlines)
        let cleaned = topic.components(separatedBy: forbidden).joined()
            .trimmingCharacters(in: .whitespaces)
        let trimmed = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        let day = date.formatted(.iso8601.year().month().day())
        return trimmed.isEmpty ? day : "\(day) \(trimmed)"
    }
}
