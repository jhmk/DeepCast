import Foundation
import Testing
@testable import DeepCast

struct DialogFormatTests {
    @Test func chooseFormatFromCategoriesAndSpeakers() {
        var options = EpisodeOptions(topic: "x")
        #expect(DialogFormat.choose(for: options) == .narrator)
        options.categories = [.scientific]
        #expect(DialogFormat.choose(for: options) == .explainer)
        options.categories = [.curiosities]
        #expect(DialogFormat.choose(for: options) == .conversation)
        options.speakerIDs = ["lena"]
        #expect(DialogFormat.choose(for: options) == .monologue)
    }

    @Test func explainerMainVoiceIsNotTheModerator() {
        let cast = [Persona.defaults[0], Persona.defaults[1]]
        #expect(DialogFormat.mainVoice(.explainer, cast: cast)?.id == "lena")
        #expect(DialogFormat.mainVoice(.narrator, cast: cast)?.id == "max")
    }
}

struct ScriptQualityTests {
    let cast = [Persona.defaults[0], Persona.defaults[1]]

    func seg(_ speaker: String, _ text: String, _ section: String = "A", _ ids: [String] = []) -> ScriptSegmentDraft {
        ScriptSegmentDraft(speakerID: speaker, text: text, section: section, claimIDs: ids)
    }

    @Test func factListScriptIsFlagged() {
        // Like the first test episode: short alternating fact lines, fillers, repeated claim, topic jump.
        let bad = [
            seg("max", "Interessant. Und was ist Kryptobiose genau?"),
            seg("lena", "Laut einer Quelle ist Kryptobiose ein Zustand mit reduziertem Stoffwechsel.", "A", ["K1"]),
            seg("max", "Interessant. Wie lange dauert das?", "B"),
            seg("lena", "Laut einer Quelle bis zu zehn Jahre und länger, laut einer Quelle.", "B", ["K2"]),
            seg("max", "Und was ist Kryptobiose nochmal?", "A"),
            seg("lena", "Laut einer Quelle ist Kryptobiose ein Zustand mit reduziertem Stoffwechsel.", "A", ["K1"]),
            seg("max", "Danke fürs Zuhören.", "Schluss"),
        ]
        let report = ScriptQuality.measure(bad, format: .narrator, cast: cast, wordsPerMinute: 130)
        #expect(report.fillerCount >= 4)
        #expect(report.repeatedClaims == ["K1"])
        #expect(report.sectionReturns == 1)
        #expect(!report.repeatedPhrases.isEmpty)
        #expect(ScriptQuality.needsRevision(report))
    }

    @Test func narratorScriptWithinTargets() {
        let story = String(repeating: "Die Tiere leben im Moos und trocknen langsam aus, ohne dabei Schaden zu nehmen. ", count: 6)
        var segments: [ScriptSegmentDraft] = []
        for index in 0..<8 {
            segments.append(seg("max", story, "A", ["K\(index)"]))
            segments.append(seg("lena", index % 2 == 0 ? "Echt jetzt?" : "Moment, heißt das, sie überleben auch Kälte?"))
        }
        let report = ScriptQuality.measure(segments, format: .narrator, cast: cast, wordsPerMinute: 130)
        #expect(report.mainShare ?? 0 > 0.8 || report.problems.allSatisfy { !$0.contains("Hauptstimme") })
        #expect(report.repeatedClaims.isEmpty && report.fillerCount == 0 && report.sectionReturns == 0)
        #expect(report.shortReactionShare >= 0.25)
    }
}

struct ScriptCheckerNarrativeTests {
    func claim(_ id: String, _ text: String, light: TrafficLight = .green, source: String = "S1") -> Claim {
        Claim(id: id, text: text, type: .fact,
              evidence: [Evidence(sourceID: source, chunkID: "\(source)-C1", quote: text, match: .exact)], light: light)
    }

    func seg(_ text: String, _ ids: [String], section: String = "A") -> ScriptSegmentDraft {
        ScriptSegmentDraft(speakerID: "lena", text: text, section: section, claimIDs: ids)
    }

    @Test func claimUsedTwiceIsFlaggedButRecapAllowed() {
        let claims = [claim("K1", "Bärtierchen leben im Moos.")]
        let result = ScriptChecker.check([
            seg("Sie leben im Moos.", ["K1"]),
            seg("Wie gesagt, sie leben im Moos.", ["K1"]),
            seg("Zum Schluss: Moos ist ihr Zuhause.", ["K1"], section: "Schluss"),
        ], usable: claims)
        #expect(result.issues.map(\.index) == [1])
    }

    @Test func vagueSourceOnlyOncePerEpisode() {
        let claims = [claim("K1", "Bärtierchen leben im Moos.", light: .yellow), claim("K2", "Sie trocknen aus.", light: .yellow, source: "S2")]
        let result = ScriptChecker.check([
            seg("Laut einer Quelle leben sie im Moos.", ["K1"]),
            seg("Laut einer Quelle trocknen sie aus.", ["K2"]),
        ], usable: claims)
        #expect(result.issues.map(\.index) == [1])
    }

    @Test func concreteOriginCountsAndHedgeOncePerSource() {
        let claims = [claim("K1", "Bärtierchen leben im Moos.", light: .yellow), claim("K2", "Sie leben auch in Dachrinnen.", light: .yellow)]
        let result = ScriptChecker.check([
            seg("Eine Studie aus Polen fand sie im Moos.", ["K1"]),
            seg("Und auch in Dachrinnen.", ["K2"]),   // same source, uncertainty already named
        ], usable: claims)
        #expect(result.issues.isEmpty)
    }

    @Test func repeatedQuoteIsFlagged() {
        var quote = Claim(id: "K1", text: "Er sagte: „Diese Tiere sind kleine Bären im Moos.“", type: .quote,
                          evidence: [Evidence(sourceID: "S1", chunkID: "S1-C1", quote: "Diese Tiere sind kleine Bären im Moos.", match: .exact)], light: .green)
        quote.isParaphrase = false
        quote.quotedPerson = "Spallanzani"
        let result = ScriptChecker.check([
            seg("Er schrieb: „Diese Tiere sind kleine Bären im Moos.“", ["K1"]),
            seg("Nochmal: „Diese Tiere sind kleine Bären im Moos.“", [], section: "Schluss"),
        ], usable: [quote])
        #expect(result.issues.contains { $0.index == 1 && $0.problem.contains("wiederholt") })
    }
}

struct ReferenceWorkRuleTests {
    @Test func wikipediaAloneMakesDefinitionsGreenButNotNumbers() {
        let wiki = SourceDocument(id: "S1", kind: .wikipedia, title: "W", publisher: "de.wikipedia.org",
                                  url: URL(string: "https://de.wikipedia.org/wiki/X")!, publishedAt: nil, language: "de", tier: .b, chunks: [])
        func claim(_ type: ClaimType) -> Claim {
            Claim(id: "K1", text: "t", type: type, evidence: [Evidence(sourceID: "S1", chunkID: "S1-C1", quote: "q", match: .exact)],
                  verdict: .supported, numberCheck: NumberCheckResult(checked: [], missing: [], rounded: []))
        }
        #expect(FactCheckRules().evaluate(claim(.definition), sources: [wiki]).light == .green)
        #expect(FactCheckRules().evaluate(claim(.historical), sources: [wiki]).light == .green)
        #expect(FactCheckRules().evaluate(claim(.number), sources: [wiki]).light == .yellow)
        var strict = FactCheckRules()
        strict.strictness = .strict
        #expect(strict.evaluate(claim(.definition), sources: [wiki]).light == .yellow)
    }
}

struct NarrativeHelperTests {
    @Test func batchesSectionsByLength() {
        #expect(LocalPipeline.sectionBatches(5, targetWords: 1300) == [[0, 1, 2, 3, 4]])
        #expect(LocalPipeline.sectionBatches(14, targetWords: 7800).count == 4)
        #expect(LocalPipeline.sectionBatches(14, targetWords: 7800).flatMap { $0 } == Array(0..<14))
    }

    @Test func claimsAssignedOnlyOnce() {
        let sections = [
            NarrativeSectionOutput(title: "A", goal: "", explanation: "", analogy: "", transition: "", claimIDs: ["k1", "K2", "K9"]),
            NarrativeSectionOutput(title: "B", goal: "", explanation: "", analogy: "", transition: "", claimIDs: ["K2", "K3"]),
        ]
        let result = LocalPipeline.assignUniqueClaims(sections, usable: ["K1", "K2", "K3"])
        #expect(result[0].claimIDs == ["K1", "K2"] && result[1].claimIDs == ["K3"])
    }

    @Test func sectionMatchingAndOrdering() {
        #expect(LocalPipeline.matchSection("„Die Tun-Form“", titles: ["Einstieg", "Die Tun-Form"], fallback: "Einstieg") == "Die Tun-Form")
        #expect(LocalPipeline.matchSection("Unbekannt", titles: ["Einstieg"], fallback: "Einstieg") == "Einstieg")
        let ordered = LocalPipeline.orderBySections([
            ScriptSegmentDraft(speakerID: "a", text: "2", section: "B", claimIDs: []),
            ScriptSegmentDraft(speakerID: "a", text: "1", section: "A", claimIDs: []),
            ScriptSegmentDraft(speakerID: "a", text: "3", section: "B", claimIDs: []),
        ], titles: ["A", "B"])
        #expect(ordered.map(\.text) == ["1", "2", "3"])
    }

    @Test func concreteSourceDescriptions() {
        let paper = SourceDocument(id: "S1", kind: .paper, title: "Trehalose", publisher: "FEBS Journal", url: URL(string: "https://doi.org/1")!,
                                   publishedAt: Calendar.current.date(from: DateComponents(year: 2007, month: 7, day: 1)), language: "en", tier: .a,
                                   chunks: [], notes: ["Übersichtsarbeit"])
        #expect(LocalPipeline.sourceDescription(paper) == "Übersichtsarbeit in FEBS Journal, 2007")
        let wiki = SourceDocument(id: "S2", kind: .wikipedia, title: "Bärtierchen – Wikipedia (DE)", publisher: "de.wikipedia.org",
                                  url: URL(string: "https://de.wikipedia.org")!, publishedAt: nil, language: "de", tier: .b, chunks: [])
        #expect(LocalPipeline.sourceDescription(wiki) == "Lexikon Wikipedia („Bärtierchen“)")
    }

    @Test func situationalPauses() {
        #expect(AudioAssembler.pause(previousSpeaker: "max", speaker: "lena", chapterChanged: false, previousText: "Wie lange überleben sie das eigentlich?", text: "Jahrzehnte, wenn alles passt und sie trocken liegen.") == 0.55)
        #expect(AudioAssembler.pause(previousSpeaker: "max", speaker: "lena", chapterChanged: false, previousText: "Sie leben im Moos und überall sonst.", text: "Echt?") == 0.18)
        #expect(AudioAssembler.pause(previousSpeaker: "max", speaker: "lena", chapterChanged: true, previousText: "Frage?", text: "Antwort hier.") == 1.0)
    }
}

@MainActor
struct StyleGuideTests {
    @Test func bundledGuideContainsUserNotesAndFormats() {
        let text = StyleGuideStore.defaultText
        #expect(text.contains("Erzähler + Zuhörer") && text.contains("laut einer Quelle") && text.contains("Aufhänger"))
    }

    @Test func appendsConfirmedRulesAndShortVersionSkipsExamples() {
        let file = FileManager.default.temporaryDirectory.appending(path: "guide-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = StyleGuideStore(fileURL: file)
        store.appendRules(["Mehr Alltagsbeispiele verwenden.", "  "], episodeTitle: "Bärtierchen")
        let reloaded = StyleGuideStore(fileURL: file)
        #expect(reloaded.text.contains("## Aus deinen Rückmeldungen") && reloaded.text.contains("- Mehr Alltagsbeispiele verwenden."))
        let short = StyleGuideStore.short(reloaded.text)
        #expect(short.contains("Mehr Alltagsbeispiele") && !short.contains("Bergsteiger"))
    }
}

/// Offline run of the narrative script path with a stub model (plan → script → review → revise → check).
struct NarrativePipelineTests {
    actor Log { var tasks: [String] = []; func add(_ t: String) { tasks.append(t) } }

    struct Stub: LLMClient {
        let log: Log
        var id: String { "stub" }
        var displayName: String { "Stub" }
        var inputBudgetChars: Int { 100_000 }

        func generate<T: StructuredOutput>(_ type: T.Type, system: String, prompt: String, reasoning: Bool) async throws -> T {
            let json: String
            switch T.self {
            case is NarrativePlanOutput.Type:
                await log.add("plan")
                #expect(system.contains("Podcast-Leitfaden") || system.contains("Leitfaden"))
                json = #"{"title":"Unzerstörbar","summary":"S.","hook":"Dachrinne","guidingQuestion":"Wie?","keyInsights":["a","b","c"],"callback":"Dachrinne","sections":[{"title":"Einstieg","goal":"g","explanation":"e","analogy":"","transition":"t","claimIDs":["K1"]},{"title":"Schluss","goal":"g","explanation":"e","analogy":"","transition":"","claimIDs":["K1","K2"]}]}"#
            case is FullScriptOutput.Type where prompt.contains("Probleme laut Testhörer"):
                await log.add("revise")
                json = #"{"segments":[{"section":"Einstieg","speaker":"max","text":"Stell dir eine Dachrinne vor. Darin leben Bärtierchen im Moos.","claimIDs":["K1"]},{"section":"Einstieg","speaker":"lena","text":"Echt?","claimIDs":[]},{"section":"Schluss","speaker":"max","text":"Und sie trocknen aus, ohne zu sterben. Das nehmen wir mit.","claimIDs":["K2"]}]}"#
            case is FullScriptOutput.Type:
                await log.add("script")
                json = #"{"segments":[{"section":"Einstieg","speaker":"max","text":"Laut einer Quelle leben Bärtierchen im Moos.","claimIDs":["K1"]},{"section":"Einstieg","speaker":"lena","text":"Laut einer Quelle leben Bärtierchen im Moos.","claimIDs":["K1"]},{"section":"Schluss","speaker":"max","text":"Sie trocknen aus.","claimIDs":["K2"]}]}"#
            case is ScriptReviewOutput.Type:
                await log.add("review")
                json = #"{"clarity":5,"structure":4,"naturalness":3,"issues":[{"segment":1,"problem":"Wiederholung"}],"verdict":"Zu listig."}"#
            default:
                await log.add("rewrite")
                json = #"{"segments":[{"speaker":"max","text":"Und sie trocknen aus, ohne zu sterben.","claimIDs":["K2"]}]}"#
            }
            return try JSONResponseCleaner.decode(T.self, from: json)
        }
    }

    @Test func runsPlanScriptReviewReviseAndCheck() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "narrative-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var dossier = ResearchDossier(options: EpisodeOptions(topic: "Bärtierchen"), createdAt: .now)
        dossier.sources = [SourceDocument(id: "S1", kind: .wikipedia, title: "Bärtierchen", publisher: "de.wikipedia.org",
                                          url: URL(string: "https://de.wikipedia.org")!, publishedAt: nil, language: "de", tier: .b, chunks: [])]
        dossier.claims = [
            Claim(id: "K1", text: "Bärtierchen leben im Moos.", type: .fact, evidence: [Evidence(sourceID: "S1", chunkID: "S1-C1", quote: "q", match: .exact)], light: .green),
            Claim(id: "K2", text: "Bärtierchen können austrocknen.", type: .fact, evidence: [Evidence(sourceID: "S1", chunkID: "S1-C1", quote: "q", match: .exact)], light: .green),
        ]
        let log = Log()
        let stub = Stub(log: log)
        var pipeline = LocalPipeline(router: LLMRouter(chains: [.research: [stub], .writer: [stub], .verifier: [stub]]))
        pipeline.styleGuide = "# Podcast-Leitfaden\n- Kein Faktenvorlesen."
        let (script, result) = try await pipeline.writeScript(dossier, personas: Persona.defaults, folder: folder) { _ in }
        let tasks = await log.tasks
        #expect(tasks.starts(with: ["plan", "script", "review", "revise"]))
        #expect(script.title == "Unzerstörbar")
        #expect(script.segments.first?.text.hasPrefix("Stell dir") == true)            // revised version kept
        #expect(!script.segments.contains { $0.text.lowercased().contains("laut einer quelle") })
        #expect(result.scriptQuality?.revised == true && result.scriptQuality?.naturalness == 3)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "narrative.json").path))
    }
}
