import Foundation
import Testing
@testable import DeepCast

/// Offline test of resuming research from saved artifacts (no network, stub model).
struct ResumeTests {
    actor CallLog {
        var tasks: [String] = []
        func add(_ task: String) { tasks.append(task) }
    }

    struct StubLLM: LLMClient {
        let log: CallLog
        var id: String { "stub" }
        var displayName: String { "Stub" }
        var inputBudgetChars: Int { 20_000 }

        func generate<T: StructuredOutput>(_ type: T.Type, system: String, prompt: String, reasoning: Bool) async throws -> T {
            let json: String
            if T.self == ClaimExtractionOutput.self {
                await log.add("extract")
                json = #"{"claims":[{"chunkID":"S2-C1","text":"Bärtierchen haben acht Beine.","type":"fact","quote":"Bärtierchen haben acht kurze Beine mit Krallen.","speaker":""}]}"#
            } else if T.self == VerificationOutput.self {
                await log.add("verify")
                let ids = prompt.components(separatedBy: "\n").filter { $0.hasPrefix("ID: ") }.map { $0.dropFirst(4) }
                json = #"{"results":["# + ids.map { #"{"claimID":"\#($0)","verdict":"supported","reason":"ok"}"# }.joined(separator: ",") + "]}"
            } else {
                await log.add("other")
                throw LLMError.unavailable("unexpected")
            }
            return try JSONResponseCleaner.decode(T.self, from: json)
        }
    }

    func source(_ id: String, _ text: String) -> SourceDocument {
        SourceDocument(id: id, kind: .web, title: id, publisher: "\(id.lowercased()).example.org",
                       url: URL(string: "https://\(id.lowercased()).example.org")!, publishedAt: nil, language: "de", tier: .c,
                       chunks: [SourceChunk(id: "\(id)-C1", text: text, offset: 0)])
    }

    @Test func resumesAfterPartialExtraction() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var options = EpisodeOptions(topic: "Bärtierchen")
        options.sources = [.web]

        let plan = #"{"subquestions":["Wie sehen sie aus?"],"webQueries":["Bärtierchen"],"wikipediaTitles":[],"paperQueries":[],"keywords":["Bärtierchen","Beine"]}"#
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(plan.utf8).write(to: folder.appending(path: "plan.json"))

        var dossier = ResearchDossier(options: options, createdAt: .now)
        dossier.sources = [
            source("S1", "Bärtierchen sind meist kleiner als einen Millimeter und leben in Moos."),
            source("S2", "Bärtierchen haben acht kurze Beine mit Krallen. Sie bewegen sich tapsig."),
        ]
        var checkpoint = ResearchCheckpoint()
        checkpoint.extractedSourceIDs = ["S1"]
        checkpoint.rawClaims = [Claim(id: "", text: "Bärtierchen sind kleiner als einen Millimeter.", type: .fact,
                                      evidence: [Evidence(sourceID: "S1", chunkID: "S1-C1", quote: "Bärtierchen sind meist kleiner als einen Millimeter", match: .exact)])]
        dossier.checkpoint = checkpoint
        try ArtifactStore.save(dossier, as: "dossier.json", in: folder)

        let log = CallLog()
        let stub = StubLLM(log: log)
        let pipeline = LocalPipeline(router: LLMRouter(chains: [.research: [stub], .writer: [stub], .verifier: [stub]]))
        let result = try await pipeline.research(options, folder: folder, resume: true) { _ in }

        #expect(await log.tasks == ["extract", "verify"])  // only S2 extracted, no new plan/search
        #expect(result.claims.count == 2)
        #expect(result.claims.allSatisfy { $0.verdict == .supported })
        #expect(result.isComplete)
        let saved = try #require(ArtifactStore.load(ResearchDossier.self, name: "dossier.json", in: folder))
        #expect(saved.checkpoint == nil)
    }

    @Test func legacyDossierWithoutCheckpointIsComplete() throws {
        var dossier = ResearchDossier(options: EpisodeOptions(topic: "x"), createdAt: .now)
        dossier.claims = [Claim(id: "K1", text: "t", type: .fact, evidence: [])]
        let data = try JSONEncoder().encode(dossier)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "checkpoint")
        let decoded = try JSONDecoder().decode(ResearchDossier.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.isComplete)
    }
}
