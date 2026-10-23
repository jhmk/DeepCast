import AVFoundation
import Foundation

enum AppleSpeechError: LocalizedError {
    case voiceNotFound(String)
    case emptyText
    case noAudio

    var errorDescription: String? {
        switch self {
        case .voiceNotFound(let name): String(localized: "Apple-Stimme \"\(name)\" ist nicht installiert.")
        case .emptyText: String(localized: "Leerer Text kann nicht vertont werden.")
        case .noAudio: String(localized: "Die Apple-Sprachausgabe hat kein Audio geliefert.")
        }
    }
}

/// Renders text with AVSpeechSynthesizer into a CAF file (PCM, 22.05 kHz mono for Siri voices).
struct AppleSpeechProvider: Sendable {
    /// Resolves the best installed variant of a base voice name ("Anna" → "Anna (Premium)").
    func voiceIdentifier(forBaseName name: String, language: String = "de") -> String? {
        VoiceCatalog.bestVoice(named: name, language: language, in: VoiceCatalog.installedVoices())?.identifier
            ?? VoiceCatalog.voices(forLanguage: language, in: VoiceCatalog.installedVoices()).first?.identifier
    }

    func synthesize(text: String, voiceIdentifier: String, rate: Double = 1.0, to url: URL) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppleSpeechError.emptyText }
        guard AVSpeechSynthesisVoice(identifier: voiceIdentifier) != nil else {
            throw AppleSpeechError.voiceNotFound(voiceIdentifier)
        }
        try? FileManager.default.removeItem(at: url)
        let job = AppleSpeechJob(text: trimmed, voiceIdentifier: voiceIdentifier, rate: rate, url: url)
        try await job.run()
    }
}

/// One synthesis run. AVSpeechSynthesizer delivers buffers on its own queue; state is guarded by a lock.
private final class AppleSpeechJob: @unchecked Sendable {
    private let text: String
    private let voiceIdentifier: String
    private let rate: Double
    private let url: URL
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var writeError: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    init(text: String, voiceIdentifier: String, rate: Double, url: URL) {
        self.text = text
        self.voiceIdentifier = voiceIdentifier
        self.rate = rate
        self.url = url
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock { self.continuation = continuation }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
            if rate != 1.0 {
                utterance.rate = Float(Double(AVSpeechUtteranceDefaultSpeechRate) * rate)
            }
            synthesizer.write(utterance) { [self] buffer in
                handle(buffer)
            }
        }
    }

    private func handle(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        let finished: Bool = lock.withLock {
            if pcm.frameLength == 0 { return true }
            do {
                if file == nil {
                    file = try AVAudioFile(
                        forWriting: url,
                        settings: pcm.format.settings,
                        commonFormat: pcm.format.commonFormat,
                        interleaved: pcm.format.isInterleaved
                    )
                }
                try file?.write(from: pcm)
                frames += AVAudioFramePosition(pcm.frameLength)
            } catch {
                writeError = error
            }
            return false
        }
        if finished { finish() }
    }

    private func finish() {
        let (continuation, error, frames): (CheckedContinuation<Void, Error>?, Error?, AVAudioFramePosition) = lock.withLock {
            let result = (self.continuation, writeError, self.frames)
            self.continuation = nil
            file = nil // closes the file
            return result
        }
        if let error {
            continuation?.resume(throwing: error)
        } else if frames == 0 {
            continuation?.resume(throwing: AppleSpeechError.noAudio)
        } else {
            continuation?.resume()
        }
    }
}
