import AVFoundation
import Foundation
import Testing
@testable import DeepCast

struct AudioAssemblerUnitTests {
    @Test func pausesDependOnContext() {
        #expect(AudioAssembler.pause(previousSpeaker: nil, speaker: "max", chapterChanged: false) == 0)
        #expect(AudioAssembler.pause(previousSpeaker: "max", speaker: "max", chapterChanged: false) == 0.25)
        #expect(AudioAssembler.pause(previousSpeaker: "max", speaker: "lena", chapterChanged: false) == 0.4)
        #expect(AudioAssembler.pause(previousSpeaker: "max", speaker: "lena", chapterChanged: true) == 1.0)
    }

    @Test func chaptersCoverWholeEpisode() {
        let timings: [(start: TimeInterval, duration: TimeInterval)] = [(0, 5), (5.4, 3), (9.4, 4)]
        let chapters = AudioAssembler.chapters(from: [("Intro", 0), ("Teil 2", 2)], timings: timings, total: 13.4)
        #expect(chapters == [
            ChapterMarker(title: "Intro", start: 0, end: 9.4),
            ChapterMarker(title: "Teil 2", start: 9.4, end: 13.4),
        ])
    }

    @Test func metadataEscapesSpecialCharacters() {
        #expect(AudioAssembler.escape("a=b;c#d\\e") == "a\\=b\\;c\\#d\\\\e")
        let text = AudioAssembler.ffMetadata(
            EpisodeMetadata(title: "T", summary: "S", date: .now),
            chapters: [ChapterMarker(title: "Intro", start: 0, end: 1.5)]
        )
        #expect(text.hasPrefix(";FFMETADATA1"))
        #expect(text.contains("START=0\nEND=1500\ntitle=Intro"))
    }

    @Test func parsesLoudnormOutput() {
        let stderr = """
        [Parsed_loudnorm_0 @ 0x1] 
        {
        \t"input_i" : "-24.10",
        \t"input_tp" : "-5.30",
        \t"input_lra" : "3.20",
        \t"input_thresh" : "-34.50",
        \t"output_i" : "-16.0",
        \t"target_offset" : "0.20"
        }
        """
        let measured = AudioAssembler.parseLoudnorm(stderr)
        #expect(measured == AudioAssembler.LoudnormMeasurement(
            inputI: "-24.10", inputTP: "-5.30", inputLRA: "3.20", inputThresh: "-34.50", offset: "0.20"
        ))
    }

    @Test func rejectsSilentLoudnormMeasurement() {
        let stderr = #"{"input_i" : "-inf", "input_tp" : "-inf", "input_lra" : "0", "input_thresh" : "-70", "target_offset" : "0"}"#
        #expect(AudioAssembler.parseLoudnorm(stderr) == nil)
    }
}

struct EpisodeExporterTests {
    @Test func formatsTimestamps() {
        #expect(EpisodeExporter.timestamp(3725.5) == "01:02:05.500")
        #expect(EpisodeExporter.shortTime(65) == "1:05")
        #expect(EpisodeExporter.shortTime(3725) == "1:02:05")
    }

    @Test func writesWebVTTWithVoiceTags() {
        let vtt = EpisodeExporter.webVTT([
            ExportSegment(speakerName: "Max", text: "Hallo", section: "Intro", start: 0, duration: 1.2),
        ])
        #expect(vtt == "WEBVTT\n\n1\n00:00:00.000 --> 00:00:01.200\n<v Max>Hallo\n")
    }
}

/// Runs the real local chain: Apple voice → ffmpeg → M4A with chapters and −16 LUFS.
@Suite(.enabled(if: ExecutableLocator.locate("ffmpeg") != nil && AppleSpeechProvider().voiceIdentifier(forBaseName: "Anna") != nil))
struct AudioChainIntegrationTests {
    @Test func slowerRateRendersLongerAudio() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "deepcast-rate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "Bärtierchen leben im Moos und überstehen fast alles."
        let normal = try await SpeechRenderer(mode: .appleOnly, fishAPIKey: nil, cache: SpeechCache(directory: dir))
            .render(text: text, persona: Persona.defaults[1])
        let slow = try await SpeechRenderer(mode: .appleOnly, fishAPIKey: nil, cache: SpeechCache(directory: dir), speechRate: 0.9)
            .render(text: text, persona: Persona.defaults[1])
        #expect(normal.url != slow.url) // separate cache entries
        let normalSeconds = try await AVURLAsset(url: normal.url).load(.duration).seconds
        let slowSeconds = try await AVURLAsset(url: slow.url).load(.duration).seconds
        #expect(slowSeconds > normalSeconds)
    }

    @Test func rendersAndAssemblesEpisode() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "deepcast-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let renderer = SpeechRenderer(mode: .appleOnly, fishAPIKey: nil, cache: SpeechCache(directory: dir.appending(path: "cache")))
        let lena = Persona.defaults[1]
        let max = Persona.defaults[0]
        let first = try await renderer.render(text: "Hallo, das ist ein Test.", persona: max)
        let second = try await renderer.render(text: "Und das ist das zweite Kapitel.", persona: lena)
        #expect(first.provider == .apple && !first.fromCache)
        let again = try await renderer.render(text: "Hallo, das ist ein Test.", persona: max)
        #expect(again.fromCache)

        let output = dir.appending(path: "out.m4a")
        let result = try await AudioAssembler().assemble(
            items: [AssemblyItem(audioURL: first.url, pauseBefore: 0), AssemblyItem(audioURL: second.url, pauseBefore: 1.0)],
            chapterStarts: [("Eins", 0), ("Zwei", 1)],
            metadata: EpisodeMetadata(title: "Test", summary: "Test", date: .now),
            output: output, workDirectory: dir.appending(path: ".work")
        )
        #expect(result.chapters.count == 2)
        #expect(abs(result.segmentTimings[1].start - (result.segmentTimings[0].duration + 1.0)) < 0.01)

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - result.totalDuration) < 0.2)
        let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["de", "und"])
        #expect(groups.count == 2)

        let mp3 = dir.appending(path: "out.mp3")
        try await AudioAssembler().exportMP3(from: output, to: mp3)
        let mp3Duration = try await AVURLAsset(url: mp3).load(.duration).seconds
        #expect(abs(mp3Duration - duration) < 0.3)
    }
}

struct NumberSpellerTests {
    @Test func spellsIntegers() {
        #expect(NumberSpeller.words(0) == "null")
        #expect(NumberSpeller.words(21) == "einundzwanzig")
        #expect(NumberSpeller.words(101) == "einhunderteins")
        #expect(NumberSpeller.words(1300) == "eintausenddreihundert")
        #expect(NumberSpeller.words(2026) == "zweitausendsechsundzwanzig")
        #expect(NumberSpeller.words(31_000) == "einunddreißigtausend")
        #expect(NumberSpeller.words(1_500_000) == "eine Million fünfhunderttausend")
    }

    @Test func spellsTextWithYearsDecimalsRangesAndUnits() {
        #expect(NumberSpeller.spellOut("Der Name wurde 1777 geprägt.") == "Der Name wurde siebzehnhundertsiebenundsiebzig geprägt.")
        #expect(NumberSpeller.spellOut("mehr als 1.300 Arten") == "mehr als eintausenddreihundert Arten")
        #expect(NumberSpeller.spellOut("80–90 %") == "achtzig bis neunzig Prozent")
        #expect(NumberSpeller.spellOut("94,4 Prozent") == "vierundneunzig Komma vier Prozent")
        #expect(NumberSpeller.spellOut("über 150 °C") == "über einhundertfünfzig Grad Celsius")
        #expect(NumberSpeller.spellOut("Ohne Zahlen.") == "Ohne Zahlen.")
        #expect(NumberSpeller.spellOut("rad51 und H2O") == "rad51 und H2O")
    }
}

struct DialogPlannerTests {
    @Test func groupsByChapterAndLimits() {
        let groups = DialogPlanner.groups(sections: ["A", "A", "A", "B", "B"], lengths: [100, 100, 100, 100, 100], maxCharacters: 250)
        #expect(groups == [[0, 1], [2], [3, 4]])
        #expect(DialogPlanner.groups(sections: ["A", "A", "A"], lengths: [10, 10, 10], maxSegments: 2) == [[0, 1], [2]])
    }

    @Test func distributesDurationByLength() {
        let parts = DialogPlanner.distribute(duration: 10, lengths: [88, 188])
        #expect(abs(parts[0].duration - 10.0 / 3) < 0.01 && abs(parts[1].offset - 10.0 / 3) < 0.01)
        #expect(abs(parts.map(\.duration).reduce(0, +) - 10) < 0.001)
    }

    @Test func buildsFishDialogueText() {
        #expect(FishAudioProvider.dialogText([(0, "Hallo!"), (1, "Hi."), (0, "Los geht's.")]) == "<|speaker:0|>Hallo!<|speaker:1|>Hi.<|speaker:0|>Los geht's.")
    }
}

@MainActor
struct EpisodeSaverTests {
    @Test func plainTextTranscriptHasNoMarkdown() {
        let markdown = "# Titel\n\n## Intro\n\n**Max** (0:00): Hallo!\n"
        #expect(EpisodeSaver.plainText(fromMarkdown: markdown) == "Titel\n\nIntro\n\nMax (0:00): Hallo!\n")
    }
}
