import Foundation
import Testing
@testable import DeepCast

/// End-to-end run of the research pipeline against real services. Only runs when keys are
/// passed (see LiveFishTests). Writes all artifacts to DEEPCAST_LIVE_OUTPUT.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEEPCAST_OPENROUTER_KEY"] != nil
                   || ProcessInfo.processInfo.environment["DEEPCAST_GOOGLE_KEY"] != nil), .tags(.live))
struct LivePipelineTests {
    let env = ProcessInfo.processInfo.environment

    @Test(.timeLimit(.minutes(20)))
    func tardigradesEndToEnd() async throws {
        let folder = URL(fileURLWithPath: env["DEEPCAST_LIVE_OUTPUT"] ?? NSTemporaryDirectory() + "deepcast-live-pipeline")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Same chains as AppSettings.makeRouter().
        let apple = AppleIntelligenceClient()
        var writers: [any LLMClient] = []
        if let key = env["DEEPCAST_OPENROUTER_KEY"] { writers.append(OpenRouterClient(model: AppSettings.defaultWriterModel, apiKey: key)) }
        var verifiers: [any LLMClient] = []
        if let key = env["DEEPCAST_GOOGLE_KEY"] {
            writers.append(OpenRouterClient(model: "gemini-3.5-flash-lite", apiKey: key, endpoint: .googleAI, maxAttempts: 2))
            verifiers.append(OpenRouterClient(model: AppSettings.defaultVerifierModel, apiKey: key, endpoint: .googleAI))
        }
        writers.append(apple)
        let router = LLMRouter(chains: [.research: writers, .writer: writers, .verifier: verifiers + writers])
        let pipeline = LocalPipeline(router: router)

        var options = EpisodeOptions(topic: "Wie funktionieren Tardigraden?")
        options.minutes = 5
        options.speakerIDs = ["max", "lena", "sabine"]
        options.nerdLevel = 4
        let log = LogCollector()
        let start = Date()

        let dossier: ResearchDossier
        if env["DEEPCAST_REUSE_RESEARCH"] != nil, let saved = ArtifactStore.load(ResearchDossier.self, name: "dossier.json", in: folder) {
            dossier = saved   // only re-run outline/script/check (saves free requests)
        } else {
            dossier = try await pipeline.research(options, folder: folder) { event in
                await log.add("[\(Int(Date().timeIntervalSince(start)))s] \(event.stage.title): \(event.message)")
            }
        }
        let researchSeconds = Date().timeIntervalSince(start)
        #expect(!dossier.sources.isEmpty)
        #expect(dossier.usableClaims.count >= 5)

        let (script, final) = try await pipeline.writeScript(dossier, personas: Persona.defaults, folder: folder) { event in
            await log.add("[\(Int(Date().timeIntervalSince(start)))s] \(event.stage.title): \(event.message)")
        }
        let totalSeconds = Date().timeIntervalSince(start)

        // Every segment with a claim ID must reference a usable claim.
        let usableIDs = Set(final.usableClaims.map(\.id))
        let cited = script.segments.flatMap(\.claimIDs)
        #expect(cited.allSatisfy(usableIDs.contains))
        #expect(!cited.isEmpty)

        // Speech + assembly (Fish if a key is given, else Apple).
        let fishKey = env["DEEPCAST_FISH_KEY"]
        let renderer = SpeechRenderer(mode: fishKey == nil ? .appleOnly : .fishWithAppleFallback, fishAPIKey: fishKey,
                                      cache: SpeechCache(directory: folder.appending(path: "speech-cache")))
        var items: [AssemblyItem] = []
        var chapters: [(title: String, segmentIndex: Int)] = []
        for (index, segment) in script.segments.enumerated() {
            let persona = Persona.defaults.first { $0.id == segment.speakerID } ?? Persona.defaults[0]
            let speech = try await renderer.render(text: segment.text, persona: persona)
            let previous = index > 0 ? script.segments[index - 1] : nil
            if previous?.section != segment.section { chapters.append((segment.section, index)) }
            items.append(AssemblyItem(audioURL: speech.url, pauseBefore: AudioAssembler.pause(
                previousSpeaker: previous?.speakerID, speaker: segment.speakerID,
                chapterChanged: previous != nil && previous?.section != segment.section)))
        }
        let audio = try await AudioAssembler().assemble(
            items: items, chapterStarts: chapters,
            metadata: EpisodeMetadata(title: script.title, summary: script.summary, date: .now),
            output: folder.appending(path: "episode.m4a"), workDirectory: folder.appending(path: ".work"))

        let scriptText = script.segments.map { "[\($0.section)] \($0.speakerID): \($0.text)  \($0.claimIDs)" }.joined(separator: "\n")
        try scriptText.write(to: folder.appending(path: "script.txt"), atomically: true, encoding: .utf8)
        let lines = await log.lines
        try lines.joined(separator: "\n").write(to: folder.appending(path: "log.txt"), atomically: true, encoding: .utf8)
        let calls = final.calls
        let summary = """
        LIVE-SUMMARY
        Titel: \(script.title)
        Quellen: \(final.sources.count) (\(final.sources.map { "\($0.id) \($0.kind.rawValue) \($0.tier.rawValue) \($0.publisher)" }.joined(separator: ", ")))
        Aussagen: \(final.claims.count) · 🟢 \(final.count(.green)) 🟡 \(final.count(.yellow)) 🔴 \(final.count(.red))
        Prüfer: \(Dictionary(grouping: final.claims.compactMap(\.verifierModel), by: { $0 }).mapValues(\.count))
        Segmente: \(script.segments.count), mit Belegen: \(script.segments.filter { !$0.claimIDs.isEmpty }.count), aus Skript entfernt: \(final.scriptIssues.count)
        Audio: \(Int(audio.totalDuration)) s, Kapitel: \(audio.chapters.map(\.title))
        Zeit: Recherche \(Int(researchSeconds)) s, gesamt bis Skript \(Int(totalSeconds)) s
        LLM-Aufrufe: \(calls.count) (ok \(calls.filter(\.succeeded).count)) nach Modell: \(Dictionary(grouping: calls, by: { FactCheckReport.modelName($0.model) }).mapValues(\.count))
        Hinweise: \(final.notes.joined(separator: " | "))
        """
        try summary.write(to: folder.appending(path: "summary.txt"), atomically: true, encoding: .utf8)
        print(summary)
    }
}

actor LogCollector {
    private(set) var lines: [String] = []
    func add(_ line: String) { lines.append(line) }
}
