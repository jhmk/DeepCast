import Foundation
import Testing
@testable import DeepCast

struct EvidenceMatcherTests {
    let text = "Bärtierchen können in einen Zustand der Kryptobiose übergehen. In diesem Zustand überstehen sie Temperaturen von nahezu dem absoluten Nullpunkt bis über 150 Grad Celsius."

    @Test func exactMatchIgnoresQuotesCaseAndWhitespace() {
        #expect(EvidenceMatcher.match(quote: "in diesem   Zustand überstehen sie Temperaturen", in: text) == .exact)
        #expect(EvidenceMatcher.match(quote: "„In diesem Zustand überstehen sie Temperaturen“", in: text) == .exact)
    }

    @Test func approximateMatchToleratesSmallDeviation() {
        #expect(EvidenceMatcher.match(quote: "In diesem Zustand überstehen sie Temperaturen von nahe dem absoluten Nullpunkt bis über 150 Grad Celsius", in: text) == .approximate)
    }

    @Test func inventedQuoteIsRejected() {
        #expect(EvidenceMatcher.match(quote: "Bärtierchen können im Weltall ohne Schutz jahrelang leben.", in: text) == nil)
    }

    @Test func tooShortQuoteIsRejected() {
        #expect(EvidenceMatcher.match(quote: "Bärtierchen", in: text) == nil)
    }
}

struct NumberMatcherTests {
    @Test func parsesGermanAndEnglishFormats() {
        #expect(NumberMatcher.parse("1.300") == 1300)
        #expect(NumberMatcher.parse("1 300") == 1300)
        #expect(NumberMatcher.parse("1,300") == 1300)
        #expect(NumberMatcher.parse("1,5") == 1.5)
        #expect(NumberMatcher.parse("150") == 150)
    }

    @Test func understandsMagnitudeWords() {
        let numbers = NumberMatcher.numbers(in: "rund 1,5 Millionen Menschen")
        #expect(numbers.first?.value == 1_500_000)
    }

    @Test func numberMustAppearInEvidence() {
        let ok = NumberMatcher.check(claim: "Es sind mehr als 1.300 Arten beschrieben.", evidence: ["Bislang sind mehr als 1300 Arten beschrieben."])
        #expect(ok.passed)
        let wrong = NumberMatcher.check(claim: "Es sind 1.500 Arten beschrieben.", evidence: ["Bislang sind mehr als 1300 Arten beschrieben."])
        #expect(wrong.missing == ["1.500"])
    }

    @Test func roundingIsAllowedAndDocumentedButNotForYears() {
        let rounded = NumberMatcher.check(claim: "etwa 1.300 Arten", evidence: ["1.265 Arten"])
        #expect(rounded.passed && rounded.rounded == ["1.300"])
        let year = NumberMatcher.check(claim: "im Jahr 1778", evidence: ["im Jahr 1777"])
        #expect(!year.passed)
    }

    @Test func parsesGermanNumberWords() {
        #expect(NumberMatcher.wordValue("dreihundertfünfzig") == 350)
        #expect(NumberMatcher.wordValue("einundzwanzig") == 21)
        #expect(NumberMatcher.wordValue("achtzig") == 80)
        #expect(NumberMatcher.wordValue("zweitausendsechsundzwanzig") == 2026)
        #expect(NumberMatcher.wordValue("eine") == nil)
        #expect(NumberMatcher.wordValue("jahren") == nil)
        #expect(NumberMatcher.wordValue("achtung") == nil)
    }

    @Test func wordNumbersInEvidenceCount() {
        #expect(NumberMatcher.check(claim: "Sie haben 8 Beine.", evidence: ["Die Tiere haben acht Beine."]).passed)
    }
}

struct FactCheckRulesTests {
    func source(_ id: String, tier: TrustTier, publisher: String, kind: SourceKind = .web) -> SourceDocument {
        SourceDocument(id: id, kind: kind, title: id, publisher: publisher, url: URL(string: "https://\(publisher)/x")!,
                       publishedAt: nil, language: "de", tier: tier, chunks: [])
    }

    func claim(_ sources: [String], verdict: Verdict? = .supported, type: ClaimType = .fact, match: QuoteMatch = .exact) -> Claim {
        Claim(id: "K1", text: "Aussage", type: type,
              evidence: sources.map { Evidence(sourceID: $0, chunkID: "\($0)-C1", quote: "Zitat", match: match) },
              verdict: verdict, numberCheck: NumberCheckResult(checked: [], missing: [], rounded: []))
    }

    let wiki = SourceDocument(id: "S1", kind: .wikipedia, title: "W", publisher: "de.wikipedia.org",
                              url: URL(string: "https://de.wikipedia.org/wiki/X")!, publishedAt: nil, language: "de", tier: .b, chunks: [])

    @Test func tierAIsGreen() {
        let rules = FactCheckRules()
        #expect(rules.evaluate(claim(["S2"]), sources: [source("S2", tier: .a, publisher: "nature.com")]).light == .green)
    }

    @Test func singleBIsYellowButCorroboratedBIsGreen() {
        let rules = FactCheckRules()
        #expect(rules.evaluate(claim(["S1"]), sources: [wiki]).light == .yellow)
        let sources = [wiki, source("S2", tier: .c, publisher: "example.org")]
        #expect(rules.evaluate(claim(["S1", "S2"]), sources: sources).light == .green)
    }

    @Test func sameWikipediaInTwoLanguagesIsNotIndependent() {
        let english = SourceDocument(id: "S3", kind: .wikipedia, title: "W", publisher: "en.wikipedia.org",
                                     url: URL(string: "https://en.wikipedia.org/wiki/X")!, publishedAt: nil, language: "en", tier: .b, chunks: [])
        #expect(FactCheckRules().evaluate(claim(["S1", "S3"]), sources: [wiki, english]).light == .yellow)
    }

    @Test func strictNeedsTwoBOrOneA() {
        var rules = FactCheckRules()
        rules.strictness = .strict
        let sources = [wiki, source("S2", tier: .c, publisher: "example.org")]
        #expect(rules.evaluate(claim(["S1", "S2"]), sources: sources).light == .yellow)
        #expect(rules.evaluate(claim(["S2"]), sources: sources).light == .red)
    }

    @Test func contradictedOrMissingNumberIsRed() {
        let rules = FactCheckRules()
        let sources = [source("S2", tier: .a, publisher: "nature.com")]
        #expect(rules.evaluate(claim(["S2"], verdict: .contradicted), sources: sources).light == .red)
        var numberClaim = claim(["S2"])
        numberClaim.numberCheck = NumberCheckResult(checked: ["1500"], missing: ["1500"], rounded: [])
        #expect(rules.evaluate(numberClaim, sources: sources).light == .red)
    }

    @Test func capsLimitToYellow() {
        let rules = FactCheckRules()
        let a = [source("S2", tier: .a, publisher: "nature.com")]
        #expect(rules.evaluate(claim(["S2"], verdict: .partiallySupported), sources: a).light == .yellow)
        #expect(rules.evaluate(claim(["S2"], verdict: nil), sources: a).light == .yellow)
        #expect(rules.evaluate(claim(["S2"], match: .approximate), sources: a).light == .yellow)
        let arxiv = [source("S2", tier: .b, publisher: "arxiv.org")]
        #expect(rules.evaluate(claim(["S2"], type: .scientificConsensus), sources: arxiv).light == .yellow)
    }

    @Test func opinionNeedsNoProofButIsMarked() {
        let outcome = FactCheckRules().evaluate(claim(["S1"], verdict: nil, type: .opinion), sources: [wiki])
        #expect(outcome.light == .yellow)
    }

    @Test func mergerCombinesDuplicatesFromDifferentSources() {
        let a = Claim(id: "", text: "Bärtierchen überstehen Temperaturen bis 150 Grad Celsius.", type: .number,
                      evidence: [Evidence(sourceID: "S1", chunkID: "S1-C1", quote: "q", match: .exact)])
        let b = Claim(id: "", text: "Bärtierchen überstehen Temperaturen von bis zu 150 Grad Celsius.", type: .number,
                      evidence: [Evidence(sourceID: "S2", chunkID: "S2-C1", quote: "q", match: .exact)])
        let c = Claim(id: "", text: "Bärtierchen überstehen Temperaturen bis 120 Grad Celsius.", type: .number,
                      evidence: [Evidence(sourceID: "S3", chunkID: "S3-C1", quote: "q", match: .exact)])
        let merged = ClaimMerger.merge([a, b, c])
        #expect(merged.count == 2)
        #expect(merged[0].id == "K1" && merged[0].sourceIDs == ["S1", "S2"])
    }
}

struct ScriptCheckerTests {
    let claims = [
        Claim(id: "K1", text: "Es sind mehr als 1300 Arten beschrieben.", type: .number,
              evidence: [Evidence(sourceID: "S1", chunkID: "S1-C1", quote: "mehr als 1300 Arten", match: .exact)], light: .green),
        Claim(id: "K2", text: "Erste Studien deuten auf Strahlenresistenz hin.", type: .fact,
              evidence: [Evidence(sourceID: "S1", chunkID: "S1-C1", quote: "q", match: .exact)], light: .yellow),
    ]

    func draft(_ text: String, _ ids: [String]) -> ScriptSegmentDraft {
        ScriptSegmentDraft(speakerID: "lena", text: text, section: "A", claimIDs: ids)
    }

    @Test func validSegmentPasses() {
        let result = ScriptChecker.check([draft("Bisher kennt man über 1300 Arten.", ["K1"])], usable: claims)
        #expect(result.issues.isEmpty)
    }

    @Test func numberWithoutClaimIsFlagged() {
        let result = ScriptChecker.check([draft("Es gibt 2000 Arten.", [])], usable: claims)
        #expect(result.issues.count == 1)
    }

    @Test func unknownClaimIDIsRemovedAndFlagged() {
        let result = ScriptChecker.check([draft("Spannend.", ["K9"])], usable: claims)
        #expect(result.segments[0].claimIDs.isEmpty)
        #expect(result.issues.count == 1)
    }

    @Test func yellowClaimNeedsHedge() {
        #expect(ScriptChecker.check([draft("Sie sind strahlenresistent.", ["K2"])], usable: claims).issues.count == 1)
        #expect(ScriptChecker.check([draft("Erste Hinweise deuten auf Strahlenresistenz hin.", ["K2"])], usable: claims).issues.isEmpty)
    }

    @Test func writtenOutNumbersAreChecked() {
        // Found in the live run: "zwei Jahren" was invented and slipped through.
        #expect(ScriptChecker.check([draft("Nach zwei Jahren aber keine.", ["K1"])], usable: claims).issues.count == 1)
        #expect(ScriptChecker.check([draft("Man kennt über eintausenddreihundert Arten.", ["K1"])], usable: claims).issues.isEmpty)
        #expect(ScriptChecker.check([draft("Das hat zwei Gründe.", [])], usable: claims).issues.isEmpty)
    }

    @Test func editorRecheckFindsProblemsOfSingleSegment() {
        #expect(ScriptChecker.problems(text: "Es gibt über 1300 Arten.", claimIDs: ["K1"], usable: claims).isEmpty)
        #expect(ScriptChecker.problems(text: "Es gibt 5000 Arten.", claimIDs: ["K1"], usable: claims).count == 1)
        #expect(ScriptChecker.problems(text: "Spannend.", claimIDs: ["K7"], usable: claims).count == 1)
    }

    @Test func unbackedConsensusIsFlagged() {
        #expect(ScriptChecker.check([draft("Über 1300 Arten, das ist Konsens in der Forschung.", ["K1"])], usable: claims).issues.count == 1)
    }

    @Test func speakerPrefixIsStripped() {
        #expect(LocalPipeline.stripSpeakerPrefix("Dr. Lena: Genau so.", cast: Persona.defaults) == "Genau so.")
        #expect(LocalPipeline.stripSpeakerPrefix("Lena: Ja.", cast: Persona.defaults) == "Ja.")
        #expect(LocalPipeline.stripSpeakerPrefix("Wichtig: das gilt.", cast: Persona.defaults) == "Wichtig: das gilt.")
    }

    @Test func overclaimingIsFlagged() {
        #expect(ScriptChecker.check([draft("Das beweist, dass über 1300 Arten existieren.", ["K1"])], usable: claims).issues.count == 1)
    }
}

struct IndependenceTests {
    func web(_ id: String, _ publisher: String, _ text: String) -> SourceDocument {
        SourceDocument(id: id, kind: .web, title: id, publisher: publisher, url: URL(string: "https://\(publisher)/a")!,
                       publishedAt: nil, language: "de", tier: .b, chunks: [SourceChunk(id: "\(id)-C1", text: text, offset: 0)])
    }

    let agency = String(repeating: "Forscher haben herausgefunden dass Bärtierchen extreme Kälte überstehen können und dabei ihren Stoffwechsel fast vollständig einstellen. ", count: 4)

    @Test func syndicatedCopiesCountAsOneSource() {
        var sources = [
            web("S1", "zeit.de", agency),
            web("S2", "spiegel.de", "Vorspann. " + agency + " Eigener Schluss."),
            web("S3", "geo.de", "Ein ganz anderer Artikel über Moose, Flechten und das Leben in Dachrinnen mit vielen eigenen Worten und Beispielen."),
        ]
        let notes = SyndicationDetector.mark(&sources)
        #expect(notes.count == 1)
        #expect(sources[0].independenceKey == sources[1].independenceKey)
        #expect(sources[2].syndicationGroup == nil)

        let claim = Claim(id: "K1", text: "t", type: .fact,
                          evidence: [Evidence(sourceID: "S1", chunkID: "S1-C1", quote: "q", match: .exact),
                                     Evidence(sourceID: "S2", chunkID: "S2-C1", quote: "q", match: .exact)],
                          verdict: .supported, numberCheck: NumberCheckResult(checked: [], missing: [], rounded: []))
        // Two B sources but syndicated → only one independent → yellow instead of green.
        #expect(FactCheckRules().evaluate(claim, sources: sources).light == .yellow)
    }

    @Test func differentNumbersForSameFactAreContested() {
        func claim(_ id: String, _ text: String, _ source: String) -> Claim {
            Claim(id: id, text: text, type: .number,
                  evidence: [Evidence(sourceID: source, chunkID: "\(source)-C1", quote: "q", match: .exact)], verdict: .supported,
                  numberCheck: NumberCheckResult(checked: [], missing: [], rounded: []))
        }
        var claims = [
            claim("K1", "Bislang sind mehr als 1300 Arten der Bärtierchen beschrieben.", "S1"),
            claim("K2", "Bislang sind mehr als 1500 Arten der Bärtierchen beschrieben.", "S2"),
            claim("K3", "Bärtierchen überstehen 150 Grad Celsius.", "S3"),
        ]
        let notes = ContradictionDetector.mark(&claims)
        #expect(notes.count == 1)
        #expect(claims[0].contestedWith == ["K2"] && claims[1].contestedWith == ["K1"])
        #expect(claims[2].contestedWith == nil)
        let source = SourceDocument(id: "S1", kind: .web, title: "x", publisher: "nature.com", url: URL(string: "https://nature.com")!,
                                    publishedAt: nil, language: "en", tier: .a, chunks: [])
        #expect(FactCheckRules().evaluate(claims[0], sources: [source]).light == .yellow)
    }

    @Test func factCheckExportOmitsSourceText() throws {
        var dossier = ResearchDossier(options: EpisodeOptions(topic: "x"), createdAt: .now)
        dossier.sources = [web("S1", "zeit.de", "Geheimer Volltext")]
        let data = try JSONEncoder().encode(FactCheckExport(dossier, title: "T"))
        #expect(!(String(data: data, encoding: .utf8) ?? "").contains("Geheimer Volltext"))
    }
}

struct UnitConverterTests {
    @Test func findsQuantitiesWithUnits() {
        let q = UnitConverter.quantities(in: "Licht: 299.792.458 Meter pro Sekunde, Mond 384.400 km, 150 °C, 80 Prozent, 2 Jahre.")
        #expect(q.map(\.dimension) == [.speed, .length, .temperature, .percent, .time])
        #expect(q[0].si == 299_792_458)
        #expect(q[1].si == 384_400_000)
        #expect(abs(q[2].si - 423.15) < 0.001)
    }

    @Test func convertedNumbersPassTheCheck() {
        let light = NumberMatcher.check(claim: "Licht ist rund 300.000 km/s schnell.",
                                        evidence: ["Die Lichtgeschwindigkeit beträgt 299.792.458 Meter pro Sekunde."])
        #expect(light.passed && light.rounded.first?.contains("umgerechnet") == true)
        let temperature = NumberMatcher.check(claim: "bis über 350 Kelvin", evidence: ["erhöhte Temperaturen über 77 °C"])
        #expect(temperature.passed)
        let wrong = NumberMatcher.check(claim: "Licht ist 500.000 km/s schnell.", evidence: ["299.792.458 Meter pro Sekunde"])
        #expect(!wrong.passed)
    }

    @Test func scriptCheckerAcceptsConvertedUnits() {
        let claim = Claim(id: "K1", text: "Die Lichtgeschwindigkeit beträgt 299.792.458 Meter pro Sekunde.", type: .number,
                          evidence: [Evidence(sourceID: "S1", chunkID: "S1-C1", quote: "299.792.458 Meter pro Sekunde", match: .exact)], light: .green)
        #expect(ScriptChecker.problems(text: "Das Licht schafft rund 300.000 Kilometer pro Sekunde.", claimIDs: ["K1"], usable: [claim]).isEmpty)
    }

    @Test func doesNotConfuseWords() {
        #expect(UnitConverter.quantities(in: "Er kam 3 mal und hatte 2 Kinder.").isEmpty)
    }
}

struct QuoteVerifierTests {
    let chunk = "Der Forscher Lazzaro Spallanzani schrieb 1777: „Diese Tiere bewegen sich langsam wie kleine Bären.“ Später folgten weitere Studien."

    @Test func verifiedQuoteNeedsPersonAndWording() {
        let ok = QuoteVerifier.verify(claimText: "Spallanzani schrieb: „Diese Tiere bewegen sich langsam wie kleine Bären.“",
                                      speaker: "Lazzaro Spallanzani", chunk: chunk)
        #expect(ok == .init(person: "Lazzaro Spallanzani", verbatimAllowed: true))
        let wrongPerson = QuoteVerifier.verify(claimText: "„Diese Tiere bewegen sich langsam wie kleine Bären.“", speaker: "Charles Darwin", chunk: chunk)
        #expect(!wrongPerson.verbatimAllowed)
        let altered = QuoteVerifier.verify(claimText: "„Diese Tiere bewegen sich schnell wie kleine Bären.“", speaker: "Spallanzani", chunk: chunk)
        #expect(!altered.verbatimAllowed)
    }

    @Test func scriptRejectsQuotesWithoutVerifiedClaim() {
        var claim = Claim(id: "K1", text: "Spallanzani: „Diese Tiere bewegen sich langsam wie kleine Bären.“", type: .quote,
                          evidence: [Evidence(sourceID: "S1", chunkID: "S1-C1", quote: "Diese Tiere bewegen sich langsam wie kleine Bären.", match: .exact)],
                          light: .green)
        claim.quotedPerson = "Spallanzani"
        claim.isParaphrase = false
        #expect(QuoteVerifier.scriptProblem("Er schrieb: „Diese Tiere bewegen sich langsam wie kleine Bären.“", cited: [claim]) == nil)
        #expect(QuoteVerifier.scriptProblem("Er schrieb: „Diese Tiere sind die süßesten Bären der Welt.“", cited: [claim]) != nil)
        claim.isParaphrase = true
        #expect(QuoteVerifier.scriptProblem("Er schrieb: „Diese Tiere bewegen sich langsam wie kleine Bären.“", cited: [claim]) != nil)
        #expect(QuoteVerifier.scriptProblem("Er verglich sie mit kleinen, langsamen Bären.", cited: [claim]) == nil)
    }
}
