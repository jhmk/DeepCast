import Foundation

struct ProcessResult: Sendable {
    let exitCode: Int32
    let stderr: String
}

enum ProcessRunnerError: LocalizedError {
    case failed(tool: String, code: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .failed(let tool, let code, let stderr):
            let tail = stderr.split(separator: "\n").suffix(4).joined(separator: "\n")
            return String(localized: "\(tool) ist fehlgeschlagen (Code \(code)): \(tail)")
        }
    }
}

/// Runs a command line tool without blocking a thread. stderr goes to a temp file so a
/// chatty tool (ffmpeg) can never dead-lock on a full pipe.
enum ProcessRunner {
    static func run(_ executable: URL, arguments: [String], checkExitCode: Bool = true) async throws -> ProcessResult {
        let logURL = FileManager.default.temporaryDirectory.appending(path: "deepcast-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: logURL) }
        let logHandle = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice

        let code: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
        try? logHandle.close()
        try Task.checkCancellation()

        let stderr = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        if checkExitCode, code != 0 {
            throw ProcessRunnerError.failed(tool: executable.lastPathComponent, code: code, stderr: stderr)
        }
        return ProcessResult(exitCode: code, stderr: stderr)
    }
}
