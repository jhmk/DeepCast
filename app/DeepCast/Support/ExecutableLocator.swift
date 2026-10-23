import Foundation

/// Finds command line tools. GUI apps do not inherit the Homebrew PATH from the shell,
/// so the usual install locations are checked explicitly.
enum ExecutableLocator {
    static let defaultSearchDirectories = [
        "/opt/homebrew/bin",
        "/opt/homebrew/opt/ffmpeg-full/bin",
        "/opt/homebrew/opt/ffmpeg/bin",
        "/usr/local/bin",
        "/usr/bin",
    ]

    static func locate(
        _ name: String,
        searchDirectories: [String] = defaultSearchDirectories,
        fileManager: FileManager = .default
    ) -> URL? {
        for directory in searchDirectories {
            let path = (directory as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}
