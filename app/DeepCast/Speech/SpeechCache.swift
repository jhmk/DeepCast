import CryptoKit
import Foundation

/// File cache for rendered segments. Key = hash(provider | voice | model | text), so only
/// changed segments are rendered again.
struct SpeechCache: Sendable {
    let directory: URL

    init(directory: URL = AppPaths.speechCache()) {
        self.directory = directory
    }

    static func key(provider: SpeechProviderKind, voiceID: String, model: String, text: String) -> String {
        let input = [provider.rawValue, voiceID, model, text].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func url(forKey key: String, fileExtension: String) -> URL {
        directory.appending(path: "\(key).\(fileExtension)")
    }

    func cachedFile(forKey key: String, fileExtension: String) -> URL? {
        let url = url(forKey: key, fileExtension: fileExtension)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return size > 0 ? url : nil
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
