import Foundation
import Testing
@testable import DeepCast

struct CategoryTests {
    @Test func everyCategoryHasLabelSummaryInstructionAndValidPreset() {
        let personaIDs = Set(Persona.defaults.map(\.id))
        for category in EpisodeCategory.allCases {
            #expect(!category.label.isEmpty && !category.summary.isEmpty && !category.instruction.isEmpty)
            let preset = category.preset
            #expect((1...5).contains(preset.nerdLevel) && (0...3).contains(preset.digression))
            #expect(!preset.sources.isEmpty)
            #expect((1...4).contains(preset.speakerIDs.count) && preset.speakerIDs.allSatisfy(personaIDs.contains))
        }
    }

    @Test func presetOnlyPresetsAndStaysEditable() {
        var options = EpisodeOptions(topic: "Lissabon")
        options.minutes = 12
        CategoryMix([.travel]).apply(to: &options)
        #expect(options.category == .travel && options.categories == [.travel])
        #expect(options.sources.contains(.wikivoyage))
        #expect(options.minutes == 12)              // untouched
        options.nerdLevel = 5                       // still editable
        #expect(options.nerdLevel == 5)
    }

    @Test func scientificIsStrictAndUsesPapers() {
        let preset = EpisodeCategory.scientific.preset
        #expect(preset.strictness == .strict && preset.sources.contains(.paper))
    }

    @Test func travelAddsTravelQueries() {
        let queries = EpisodeCategory.travel.extraQueries(topic: "Lissabon", language: .de)
        #expect(queries.contains("Lissabon Reiseführer") && queries.contains { $0.contains("Tourismus") })
        #expect(EpisodeCategory.scientific.extraQueries(topic: "x", language: .de).isEmpty)
    }

    @Test func relaxedIsSlowerWithLongerPauses() {
        #expect(EpisodeCategory.relaxed.speechRate < 1 && EpisodeCategory.relaxed.pauseFactor > 1)
        #expect(EpisodeCategory.general.speechRate == 1 && EpisodeCategory.general.pauseFactor == 1)
    }

    @Test func wikivoyageIsOffByDefault() {
        #expect(!SourceKind.defaultSet.contains(.wikivoyage))
        #expect(!EpisodeOptions(topic: "x").sources.contains(.wikivoyage))
    }

    @Test func categorySurvivesEncoding() throws {
        var options = EpisodeOptions(topic: "x")
        CategoryMix([.relaxed]).apply(to: &options)
        let decoded = try JSONDecoder().decode(EpisodeOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded.categories == [.relaxed] && decoded.speakerIDs == ["lena"])
    }
}

struct TravelSourceTests {
    @Test func tourismBoardsAreTierCAndFlagged() {
        for host in ["www.visitportugal.com", "www.germany.travel", "www.tourismus-bw.de", "www.turismodeportugal.pt", "www.visitscotland.com"] {
            #expect(SourceTrust.isTourismBoard(host: host), "\(host)")
            #expect(SourceTrust.tier(forHost: host) == .c, "\(host)")
        }
        #expect(!SourceTrust.isTourismBoard(host: "www.lonelyplanet.com"))
        #expect(!SourceTrust.isTourismBoard(host: "www.spiegel.de"))
    }

    @Test func travelGuidesAndOfficialAdvice() {
        #expect(SourceTrust.tier(forHost: "www.lonelyplanet.com") == .b)
        #expect(SourceTrust.tier(forHost: "www.merian.de") == .b)
        #expect(SourceTrust.tier(forHost: "de.wikivoyage.org") == .b)
        #expect(SourceTrust.tier(forHost: "www.atlasobscura.com") == .c)
        #expect(SourceTrust.tier(forHost: "www.auswaertiges-amt.de") == .a)
    }

    @Test func wikivoyageIsOwnPublisherForIndependence() {
        let voyage = SourceDocument(id: "S1", kind: .wikivoyage, title: "Lissabon", publisher: "de.wikivoyage.org",
                                    url: URL(string: "https://de.wikivoyage.org/wiki/Lissabon")!, publishedAt: nil, language: "de", tier: .b, chunks: [])
        let wiki = SourceDocument(id: "S2", kind: .wikipedia, title: "Lissabon", publisher: "de.wikipedia.org",
                                  url: URL(string: "https://de.wikipedia.org/wiki/Lissabon")!, publishedAt: nil, language: "de", tier: .b, chunks: [])
        #expect(voyage.independenceKey != wiki.independenceKey)
    }
}

struct CategoryMixTests {
    @Test func combinesStrictestHighestAndUnion() {
        let mix = CategoryMix([.travel, .history, .scientific])
        let preset = mix.preset
        #expect(preset.strictness == .strict)                       // from scientific
        #expect(preset.nerdLevel == 4)                              // highest
        #expect(preset.digression == 2)                             // highest (travel)
        #expect(preset.sources.isSuperset(of: [.wikivoyage, .paper, .podcast]))
        #expect(preset.style == EpisodeCategory.travel.preset.style) // from the first one
        #expect(preset.speakerIDs == EpisodeCategory.travel.preset.speakerIDs)
        #expect(mix.instruction.contains("Reiseführer") && mix.instruction.contains("Geschichte"))
    }

    @Test func limitsToThreeAndDropsDuplicatesAndGeneral() {
        let mix = CategoryMix([.general, .travel, .travel, .history, .news, .portrait])
        #expect(mix.categories == [.travel, .history, .news])
    }

    @Test func relaxedSlowsAnyMixAndWarnsOnConflicts() {
        let mix = CategoryMix([.news, .relaxed])
        #expect(mix.speechRate < 1 && mix.pauseFactor > 1)
        #expect(mix.warnings.count == 1)
        #expect(CategoryMix([.travel, .history]).warnings.isEmpty)
    }

    @Test func emptyMixIsGeneral() {
        #expect(CategoryMix([]).instruction == EpisodeCategory.general.instruction)
        #expect(CategoryMix([]).extraQueries(topic: "x", language: .de).isEmpty)
    }

    @Test func legacySingleCategoryDecodes() throws {
        let json = #"{"topic":"x","category":"travel","minutes":5}"#
        let options = try JSONDecoder().decode(EpisodeOptions.self, from: Data(json.utf8))
        #expect(options.categories == [.travel] && options.minutes == 5)
    }

    @Test func lengthSliderRangeAndScaling() {
        #expect(EpisodeOptions.minuteRange == 10...60 && EpisodeOptions.minuteStep == 10)
        #expect(EpisodeOptions(topic: "x").minutes == 10)
        var options = EpisodeOptions(topic: "x")
        options.minutes = 60
        #expect(options.targetWords == 7800)
        #expect(options.sectionCount == 14)
        #expect(options.maxSources == 10)
        options.minutes = 10
        #expect(options.sectionCount == 5)
    }
}

struct LengthControlTests {
    @Test func correctionOnlyBeyondThirtyPercent() {
        #expect(LocalPipeline.lengthCorrection(actual: 300, target: 400) == nil)   // −25 %
        #expect(LocalPipeline.lengthCorrection(actual: 500, target: 400) == nil)   // +25 %
        #expect(LocalPipeline.lengthCorrection(actual: 200, target: 400)?.contains("länger") == true)
        #expect(LocalPipeline.lengthCorrection(actual: 600, target: 400)?.contains("kürzer") == true)
    }

    @Test func countsWords() {
        let drafts = [ScriptSegmentDraft(speakerID: "max", text: "Eins zwei drei", section: "A", claimIDs: []),
                      ScriptSegmentDraft(speakerID: "lena", text: "vier  fünf", section: "A", claimIDs: [])]
        #expect(LocalPipeline.wordCount(drafts) == 5)
    }
}
