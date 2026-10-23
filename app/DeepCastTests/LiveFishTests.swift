import AVFoundation
import Foundation
import Testing
@testable import DeepCast

/// Live test against Fish Audio. Runs only when a key is passed, e.g.
/// `TEST_RUNNER_DEEPCAST_FISH_KEY=$(security find-generic-password -s local.deepcast -a fish-audio -w) xcodebuild test …`
/// Optional `TEST_RUNNER_DEEPCAST_LIVE_OUTPUT=/path` keeps the rendered episode for listening.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEEPCAST_FISH_KEY"] != nil), .tags(.live))
struct LiveFishTests {
    let key = ProcessInfo.processInfo.environment["DEEPCAST_FISH_KEY"] ?? ""

    @Test func rendersExampleEpisodeWithFishAndFallsBackOnBadVoice() async throws {
        let outputDir = ProcessInfo.processInfo.environment["DEEPCAST_LIVE_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appending(path: "deepcast-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let renderer = SpeechRenderer(mode: .fishWithAppleFallback, fishAPIKey: key,
                                      cache: SpeechCache(directory: outputDir.appending(path: "cache")))
        let parsed = ScriptParser.parse(ScriptParser.exampleScript, personas: Persona.defaults)
        let byID = Dictionary(uniqueKeysWithValues: Persona.defaults.map { ($0.id, $0) })

        var items: [AssemblyItem] = []
        var chapters: [(title: String, segmentIndex: Int)] = []
        let start = Date()
        for (index, segment) in parsed.segments.enumerated() {
            let speech = try await renderer.render(text: segment.text, persona: byID[segment.speakerID]!)
            #expect(speech.provider == .fish, "Segment \(index) fell back: \(speech.fallbackReason ?? "")")
            let previous = index > 0 ? parsed.segments[index - 1] : nil
            if previous?.section != segment.section { chapters.append((segment.section, index)) }
            items.append(AssemblyItem(audioURL: speech.url, pauseBefore: AudioAssembler.pause(
                previousSpeaker: previous?.speakerID, speaker: segment.speakerID,
                chapterChanged: previous != nil && previous?.section != segment.section)))
        }
        let renderSeconds = Date().timeIntervalSince(start)

        let result = try await AudioAssembler().assemble(
            items: items, chapterStarts: chapters,
            metadata: EpisodeMetadata(title: "Bärtierchen – Live-Test", summary: "Fish Audio", date: .now),
            output: outputDir.appending(path: "fish-live.m4a"), workDirectory: outputDir.appending(path: ".work")
        )
        print("LIVE: \(parsed.segments.count) segments rendered in \(Int(renderSeconds)) s, episode \(Int(result.totalDuration)) s → \(outputDir.path)")
        #expect(result.totalDuration > 20)

        // A broken voice ID must fall back to Apple instead of failing the episode.
        var broken = Persona.defaults[0]
        broken.fishVoice = FishVoiceRef(id: "does-not-exist-000", title: "Kaputt")
        let fallback = try await renderer.render(text: "Kurzer Fallback-Test.", persona: broken)
        #expect(fallback.provider == .apple)
        #expect(fallback.fallbackReason != nil)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEEPCAST_FISH_DIALOG"] != nil), .tags(.live))
struct LiveFishDialogTests {
    @Test func rendersShortNaturalDialogue() async throws {
        let key = try #require(ProcessInfo.processInfo.environment["DEEPCAST_FISH_KEY"])
        let dir = FileManager.default.temporaryDirectory.appending(path: "dialog-\(UUID().uuidString)")
        let renderer = SpeechRenderer(mode: .fishWithAppleFallback, fishAPIKey: key, cache: SpeechCache(directory: dir))
        let max = Persona.defaults[0], lena = Persona.defaults[1]
        let start = Date()
        let url = try await renderer.renderDialog([
            ("Lena, wie klein sind Bärtierchen eigentlich?", max),
            ("Meist kleiner als einen Millimeter – man braucht ein Mikroskop.", lena),
            ("Und trotzdem überstehen sie fast alles. Unglaublich!", max),
        ])
        let seconds = try await AVURLAsset(url: url).load(.duration).seconds
        print("LIVE-DIALOG \(Int(seconds)) s Audio in \(Int(Date().timeIntervalSince(start))) s → \(url.path)")
        #expect(seconds > 4)
        if let keep = ProcessInfo.processInfo.environment["DEEPCAST_LIVE_OUTPUT"] {
            try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: keep).appending(path: "dialog-test.mp3"))
        }
    }
}

extension Tag {
    @Tag static var live: Self
}
