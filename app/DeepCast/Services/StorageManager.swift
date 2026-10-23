import Foundation

/// Disk usage and cleanup (speech cache, intermediate files of finished episodes).
enum StorageManager {
    /// Automatic limit for the speech cache; oldest files are removed first.
    static let speechCacheLimit: Int64 = 2 * 1024 * 1024 * 1024

    /// Intermediate files that are not needed once an episode is finished. Kept: audio,
    /// transcript, show notes, dossier.json (evidence in the player), factcheck.*.
    static let intermediateNames: Set<String> = [".work", "plan.json", "outline.json", "script.json", "options.json"]

    struct Usage: Sendable, Equatable {
        var speechCache: Int64 = 0
        var episodes: Int64 = 0
        var intermediates: Int64 = 0
    }

    static func usage(speechCache: URL = AppPaths.speechCache(), episodes: URL = AppPaths.episodesRoot(),
                      finishedFolders: [URL]) -> Usage {
        Usage(speechCache: size(of: speechCache), episodes: size(of: episodes),
              intermediates: finishedFolders.reduce(0) { $0 + intermediatesSize(in: $1) })
    }

    static func size(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    static func intermediatesSize(in folder: URL) -> Int64 {
        intermediateNames.reduce(0) { total, name in
            let url = folder.appending(path: name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return total }
            if isDirectory.boolValue { return total + size(of: url) }
            return total + Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
    }

    @discardableResult
    static func clearSpeechCache(_ directory: URL = AppPaths.speechCache()) -> Int64 {
        let freed = size(of: directory)
        try? FileManager.default.removeItem(at: directory)
        return freed
    }

    @discardableResult
    static func clearIntermediates(in folders: [URL]) -> Int64 {
        var freed: Int64 = 0
        for folder in folders {
            for name in intermediateNames {
                let url = folder.appending(path: name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                freed += url.hasDirectoryPath || name == ".work" ? size(of: url) : Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
                try? FileManager.default.removeItem(at: url)
            }
        }
        return freed
    }

    /// Removes the oldest cache files (by last access/modification) until below `limit`.
    @discardableResult
    static func pruneSpeechCache(_ directory: URL = AppPaths.speechCache(), limit: Int64 = speechCacheLimit) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let date = max(values.contentAccessDate ?? .distantPast, values.contentModificationDate ?? .distantPast)
            return (url, Int64(values.totalFileAllocatedSize ?? 0), date)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > limit else { return 0 }
        entries.sort { $0.2 < $1.2 }
        var freed: Int64 = 0
        for (url, size, _) in entries where total > limit {
            try? FileManager.default.removeItem(at: url)
            total -= size
            freed += size
        }
        return freed
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
