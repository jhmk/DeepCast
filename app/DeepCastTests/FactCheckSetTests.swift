import Foundation
import Testing
@testable import DeepCast

/// Spec 5.8: myth / fact regression set for the verifier.
struct FactCheckSet: Decodable {
    struct Item: Decodable {
        let id: String
        let expected: String
        let de: String
        let en: String
        let evidence: String
    }

    let version: Int
    let items: [Item]

    static func load() throws -> FactCheckSet {
        let bundle = Bundle(for: FactCheckSetBundleToken.self)
        let url = try #require(bundle.url(forResource: "factcheck_set", withExtension: "json"))
        return try JSONDecoder().decode(FactCheckSet.self, from: Data(contentsOf: url))
    }
}

final class FactCheckSetBundleToken {}

struct FactCheckSetTests {
    @Test func setHasThirtyMythsAndThirtyFactsInBothLanguages() throws {
        let set = try FactCheckSet.load()
        #expect(set.items.filter { $0.expected == "false" }.count == 30)
        #expect(set.items.filter { $0.expected == "true" }.count == 30)
        #expect(Set(set.items.map(\.id)).count == 60)
        #expect(set.items.allSatisfy { !$0.de.isEmpty && !$0.en.isEmpty && $0.evidence.count > 20 })
    }

    @Test func numbersInTrueFactsAppearInEvidence() throws {
        // Deterministic layer: the number check must not reject correct claims.
        for item in try FactCheckSet.load().items where item.expected == "true" {
            let result = NumberMatcher.check(claim: item.de, evidence: [item.evidence])
            #expect(result.passed, "\(item.id): \(result.missing)")
        }
    }
}

/// Live regression run against the configured verifier (needs DEEPCAST_GOOGLE_KEY or
/// DEEPCAST_OPENROUTER_KEY). Writes factcheck-set-report.txt to DEEPCAST_LIVE_OUTPUT.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEEPCAST_FACTCHECK_SET"] != nil), .tags(.live))
struct LiveFactCheckSetTests {
    @Test(.timeLimit(.minutes(20)))
    func verifierDetectsMythsAndKeepsFacts() async throws {
        let env = ProcessInfo.processInfo.environment
        var keys: [ModelProvider: String] = [:]
        if let key = env["DEEPCAST_GOOGLE_KEY"] { keys[.google] = key }
        if let key = env["DEEPCAST_OPENROUTER_KEY"] { keys[.openRouter] = key }
        let router = LLMRouter(chains: AppSettings.chains(writer: AppSettings.defaultWriter, verifier: AppSettings.defaultVerifier, keys: keys))
        let set = try FactCheckSet.load()
        let prompt = try PromptLibrary.load("verify", values: ["items": "{{items}}"])

        var verdicts: [String: String] = [:]
        for language in ["de", "en"] {
            for batch in stride(from: 0, to: set.items.count, by: 12).map({ Array(set.items[$0..<min($0 + 12, set.items.count)]) }) {
                let items = batch.map { item in
                    "ID: \(item.id)-\(language)\nAussage: \(language == "de" ? item.de : item.en)\nBelegstellen:\n- „\(item.evidence)“"
                }.joined(separator: "\n\n")
                let output = try await router.generate(VerificationOutput.self, role: .verifier, task: "factcheck-set",
                                                       system: prompt.system, prompt: prompt.user.replacingOccurrences(of: "{{items}}", with: items),
                                                       reasoning: true)
                for result in output.value.results { verdicts[result.claimID.uppercased()] = result.verdict }
            }
        }
        let myths = set.items.filter { $0.expected == "false" }.flatMap { ["\($0.id)-DE", "\($0.id)-EN"] }
        let facts = set.items.filter { $0.expected == "true" }.flatMap { ["\($0.id)-DE", "\($0.id)-EN"] }
        let detected = myths.filter { ["contradicted", "not_enough_info"].contains(verdicts[$0] ?? "") }.count
        let wronglyRejected = facts.filter { verdicts[$0] != "supported" && verdicts[$0] != "partially_supported" }.count
        let report = """
        Faktencheck-Set v\(set.version) – Prüfer: \(AppSettings.defaultVerifier.displayName)
        Erkannte Falschbehauptungen: \(detected)/\(myths.count) (\(Int(Double(detected) / Double(myths.count) * 100)) %)
        Fälschlich verworfene korrekte Aussagen: \(wronglyRejected)/\(facts.count) (\(Int(Double(wronglyRejected) / Double(facts.count) * 100)) %)
        Nicht erkannt: \(myths.filter { !["contradicted", "not_enough_info"].contains(verdicts[$0] ?? "") }.joined(separator: ", "))
        Fälschlich verworfen: \(facts.filter { verdicts[$0] != "supported" && verdicts[$0] != "partially_supported" }.joined(separator: ", "))
        """
        if let output = env["DEEPCAST_LIVE_OUTPUT"] {
            try report.write(to: URL(fileURLWithPath: output).appending(path: "factcheck-set-report.txt"), atomically: true, encoding: .utf8)
        }
        print(report)
        #expect(Double(detected) / Double(myths.count) >= 0.9)
        #expect(Double(wronglyRejected) / Double(facts.count) <= 0.1)
    }
}
