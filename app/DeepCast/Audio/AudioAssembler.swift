import AVFoundation
import Foundation

/// One rendered segment in playback order.
struct AssemblyItem: Sendable {
    let audioURL: URL
    /// Silence inserted before this segment.
    let pauseBefore: TimeInterval
}

struct ChapterMarker: Sendable, Hashable, Codable {
    let title: String
    let start: TimeInterval
    let end: TimeInterval
}

struct EpisodeMetadata: Sendable {
    let title: String
    let summary: String
    let date: Date
}

struct AssemblyResult: Sendable {
    /// Start and duration of every segment in the final file.
    let segmentTimings: [(start: TimeInterval, duration: TimeInterval)]
    let totalDuration: TimeInterval
    let chapters: [ChapterMarker]
}

/// Shared sound treatment so all voices sound like one studio (ADR-012).
enum SoundProfile: String, CaseIterable, Identifiable, Sendable {
    /// Conversation at a table: light early reflections, warm.
    case table
    /// Dry radio sound.
    case dry

    var id: String { rawValue }
    var title: String {
        switch self {
        case .table: String(localized: "Gespräch am Tisch (leichter Raum)")
        case .dry: String(localized: "Trocken (wie Radio)")
        }
    }

    /// Per segment: rumble/hiss filter, de-esser, gentle compressor, equal loudness per voice.
    static let segmentFilter = "highpass=f=80,lowpass=f=12500,deesser=i=0.4,acompressor=threshold=-22dB:ratio=2.5:attack=8:release=120:makeup=2,loudnorm=I=-19:TP=-3:LRA=7"

    /// Applied once to the joined episode (before the final loudness normalisation).
    var roomFilter: String? {
        switch self {
        case .table: "aecho=0.9:0.5:11|19|29:0.10|0.07|0.05,equalizer=f=250:t=q:w=1:g=1.5"
        case .dry: nil
        }
    }
}

enum AudioAssemblerError: LocalizedError {
    case ffmpegMissing
    case noSegments

    var errorDescription: String? {
        switch self {
        case .ffmpegMissing: String(localized: "ffmpeg wurde nicht gefunden (brew install ffmpeg).")
        case .noSegments: String(localized: "Keine Segmente zum Zusammensetzen.")
        }
    }
}

/// Builds the final episode with ffmpeg:
/// 1. every segment → 44.1 kHz mono PCM (Fish MP3 and Apple 22 kHz CAF share one format)
/// 2. concatenation with pauses (speaker change, same speaker, chapter break)
/// 3. two-pass loudness normalisation to −16 LUFS / −1.5 dBTP (podcast standard)
/// 4. AAC in M4A with chapter markers and metadata
actor AudioAssembler {
    static let sampleRate = 44_100
    static let targetLUFS = -16.0
    static let truePeak = -1.5

    private let ffmpeg: URL
    private let profile: SoundProfile?

    /// `profile` nil = no per-voice treatment (raw segments), e.g. for tests of timing.
    init(ffmpeg: URL? = ExecutableLocator.locate("ffmpeg"), profile: SoundProfile? = .table) throws {
        guard let ffmpeg else { throw AudioAssemblerError.ffmpegMissing }
        self.ffmpeg = ffmpeg
        self.profile = profile
    }

    /// Pause lengths in seconds. Short gaps sound natural in dialogue; longer at chapters.
    static func pause(previousSpeaker: String?, speaker: String, chapterChanged: Bool) -> TimeInterval {
        guard previousSpeaker != nil else { return 0 }
        if chapterChanged { return 1.0 }
        return previousSpeaker == speaker ? 0.25 : 0.4
    }

    /// Situational pauses: short after quick reactions, a breath longer after questions.
    static func pause(previousSpeaker: String?, speaker: String, chapterChanged: Bool, previousText: String, text: String) -> TimeInterval {
        let base = pause(previousSpeaker: previousSpeaker, speaker: speaker, chapterChanged: chapterChanged)
        guard previousSpeaker != nil, !chapterChanged, previousSpeaker != speaker else { return base }
        let isShort = { (value: String) in value.split(whereSeparator: \.isWhitespace).count <= 6 }
        if previousText.trimmingCharacters(in: .whitespaces).hasSuffix("?"), !isShort(text) { return 0.55 }
        if isShort(text) || isShort(previousText) { return 0.18 }
        return base
    }

    func assemble(
        items: [AssemblyItem],
        chapterStarts: [(title: String, segmentIndex: Int)],
        metadata: EpisodeMetadata,
        output: URL,
        workDirectory: URL
    ) async throws -> AssemblyResult {
        guard !items.isEmpty else { throw AudioAssemblerError.noSegments }
        let fm = FileManager.default
        try? fm.removeItem(at: workDirectory)
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDirectory) }

        // 1 + 2: normalise format, build concat list with exact durations.
        var concatLines: [String] = []
        var timings: [(start: TimeInterval, duration: TimeInterval)] = []
        var cursor: TimeInterval = 0
        var silenceFiles: [Int: URL] = [:]

        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            if item.pauseBefore > 0 {
                let millis = Int((item.pauseBefore * 1000).rounded())
                let silence: URL
                if let existing = silenceFiles[millis] {
                    silence = existing
                } else {
                    silence = workDirectory.appending(path: "silence_\(millis).wav")
                    try await runFFmpeg([
                        "-f", "lavfi", "-i", "anullsrc=r=\(Self.sampleRate):cl=mono",
                        "-t", String(format: "%.3f", item.pauseBefore),
                        "-c:a", "pcm_s16le", silence.path,
                    ])
                    silenceFiles[millis] = silence
                }
                concatLines.append(Self.concatLine(silence))
                cursor += try Self.duration(of: silence)
            }
            let wav = workDirectory.appending(path: String(format: "seg_%04d.wav", index))
            try await runFFmpeg(["-i", item.audioURL.path]
                + (profile != nil ? ["-af", SoundProfile.segmentFilter] : [])
                + ["-ar", String(Self.sampleRate), "-ac", "1", "-c:a", "pcm_s16le", wav.path])
            let duration = try Self.duration(of: wav)
            timings.append((cursor, duration))
            cursor += duration
            concatLines.append(Self.concatLine(wav))
        }

        let listURL = workDirectory.appending(path: "concat.txt")
        try concatLines.joined(separator: "\n").write(to: listURL, atomically: true, encoding: .utf8)
        let joined = workDirectory.appending(path: "joined.wav")
        try await runFFmpeg(["-f", "concat", "-safe", "0", "-i", listURL.path, "-c", "copy", joined.path])

        // Chapters from segment timings.
        let chapters = Self.chapters(from: chapterStarts, timings: timings, total: cursor)
        let metadataURL = workDirectory.appending(path: "metadata.txt")
        try Self.ffMetadata(metadata, chapters: chapters).write(to: metadataURL, atomically: true, encoding: .utf8)

        // 3: loudness, pass 1 (measure).
        var source = joined
        if let room = profile?.roomFilter {
            let roomed = workDirectory.appending(path: "room.wav")
            try await runFFmpeg(["-i", joined.path, "-af", room, "-ar", String(Self.sampleRate), "-ac", "1", "-c:a", "pcm_s16le", roomed.path])
            source = roomed
        }
        let filter = try await loudnessFilter(for: source)

        // 4: encode M4A with chapters.
        try? fm.removeItem(at: output)
        try await runFFmpeg([
            "-i", source.path, "-i", metadataURL.path,
            "-map", "0:a", "-map_metadata", "1", "-map_chapters", "1",
            "-af", filter, "-ar", String(Self.sampleRate), "-ac", "1",
            "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart",
            output.path,
        ])
        return AssemblyResult(segmentTimings: timings, totalDuration: cursor, chapters: chapters)
    }

    /// MP3 copy with chapters (ID3v2.3 CHAP) and metadata, e.g. for players without M4A chapters.
    func exportMP3(from m4a: URL, to mp3: URL) async throws {
        try? FileManager.default.removeItem(at: mp3)
        try await runFFmpeg([
            "-i", m4a.path, "-map", "0:a", "-map_metadata", "0", "-map_chapters", "0",
            "-c:a", "libmp3lame", "-b:a", "128k", "-ar", String(Self.sampleRate), "-id3v2_version", "3", mp3.path,
        ])
    }

    /// Two-pass loudnorm: measure first, then apply linear gain. Falls back to single pass.
    private func loudnessFilter(for input: URL) async throws -> String {
        let base = "loudnorm=I=\(Self.targetLUFS):TP=\(Self.truePeak):LRA=11"
        let result = try await ProcessRunner.run(ffmpeg, arguments: [
            "-hide_banner", "-nostats", "-i", input.path, "-af", base + ":print_format=json", "-f", "null", "-",
        ])
        guard let measured = Self.parseLoudnorm(result.stderr) else { return base }
        return base
            + ":measured_I=\(measured.inputI):measured_TP=\(measured.inputTP)"
            + ":measured_LRA=\(measured.inputLRA):measured_thresh=\(measured.inputThresh)"
            + ":offset=\(measured.offset):linear=true"
    }

    struct LoudnormMeasurement: Equatable {
        let inputI, inputTP, inputLRA, inputThresh, offset: String
    }

    static func parseLoudnorm(_ stderr: String) -> LoudnormMeasurement? {
        guard let open = stderr.range(of: "{", options: .backwards),
              let close = stderr.range(of: "}", options: .backwards),
              open.lowerBound < close.lowerBound,
              let data = String(stderr[open.lowerBound...close.lowerBound]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let i = json["input_i"], let tp = json["input_tp"], let lra = json["input_lra"],
              let thresh = json["input_thresh"], let offset = json["target_offset"],
              Double(i)?.isFinite == true
        else { return nil }
        return LoudnormMeasurement(inputI: i, inputTP: tp, inputLRA: lra, inputThresh: thresh, offset: offset)
    }

    static func chapters(
        from starts: [(title: String, segmentIndex: Int)],
        timings: [(start: TimeInterval, duration: TimeInterval)],
        total: TimeInterval
    ) -> [ChapterMarker] {
        let valid = starts.filter { $0.segmentIndex < timings.count }
        return valid.enumerated().map { offset, chapter in
            // Chapters start at the pause before their first segment so a jump does not cut in.
            let start = offset == 0 ? 0 : timings[chapter.segmentIndex].start
            let end = offset + 1 < valid.count ? timings[valid[offset + 1].segmentIndex].start : total
            return ChapterMarker(title: chapter.title, start: start, end: end)
        }
    }

    static func ffMetadata(_ metadata: EpisodeMetadata, chapters: [ChapterMarker]) -> String {
        var lines = [
            ";FFMETADATA1",
            "title=\(escape(metadata.title))",
            "artist=DeepCast",
            "album=DeepCast",
            "genre=Podcast",
            "date=\(metadata.date.formatted(.iso8601.year()))",
            "comment=\(escape(metadata.summary))",
        ]
        for chapter in chapters {
            lines += [
                "",
                "[CHAPTER]",
                "TIMEBASE=1/1000",
                "START=\(Int((chapter.start * 1000).rounded()))",
                "END=\(Int((chapter.end * 1000).rounded()))",
                "title=\(escape(chapter.title))",
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// FFMETADATA requires escaping of = ; # \ and newlines.
    static func escape(_ value: String) -> String {
        var result = ""
        for character in value {
            switch character {
            case "=", ";", "#", "\\": result += "\\\(character)"
            case "\n": result += "\\\n"
            default: result.append(character)
            }
        }
        return result
    }

    private static func concatLine(_ url: URL) -> String {
        "file '\(url.path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func duration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func runFFmpeg(_ arguments: [String]) async throws {
        _ = try await ProcessRunner.run(ffmpeg, arguments: ["-hide_banner", "-loglevel", "error", "-y"] + arguments)
    }
}
