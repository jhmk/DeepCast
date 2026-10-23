import Foundation
import Testing
@testable import DeepCast

struct HTMLExtractionTests {
    let html = """
    <html lang="de"><head><title>Ignoriert</title>
    <meta property="og:title" content="Bärtierchen &amp; Kryptobiose">
    <meta property="article:published_time" content="2024-05-17T08:00:00+02:00">
    <script>var x = "<p>Kein Text</p>";</script></head>
    <body><nav><p>Startseite Navigation Menü Links und noch mehr Links hier.</p></nav>
    <article>
    <h2>Überleben</h2>
    <p>Bärtierchen können in einen Zustand der Kryptobiose übergehen, in dem der Stoffwechsel fast ruht.</p>
    <p>Kurz.</p>
    <p>In diesem Zustand überstehen sie Temperaturen von nahezu dem absoluten Nullpunkt bis über 150&nbsp;Grad.</p>
    </article>
    <footer><p>Impressum Datenschutz Kontakt Cookies und weitere rechtliche Hinweise.</p></footer>
    </body></html>
    """

    @Test func extractsMainTextMetadataAndDropsBoilerplate() {
        let result = HTMLTextExtractor.extract(html)
        #expect(result.title == "Bärtierchen & Kryptobiose")
        #expect(result.language == "de")
        #expect(result.publishedAt == HTMLTextExtractor.parseISODate("2024-05-17"))
        #expect(result.text.contains("Kryptobiose übergehen"))
        #expect(result.text.contains("150 Grad"))
        #expect(!result.text.contains("Navigation"))
        #expect(!result.text.contains("Impressum"))
        #expect(!result.text.contains("Kein Text"))
        #expect(!result.text.contains("Kurz."))
        #expect(!result.paywalled)
    }

    @Test func detectsPaywallMarker() {
        #expect(HTMLTextExtractor.extract(#"<script type="application/ld+json">{"isAccessibleForFree": false}</script>"#).paywalled)
    }

    @Test func decodesEntities() {
        #expect(HTMLTextExtractor.decodeEntities("&#x201E;Gr&ouml;&szlig;e&#8220; &amp; mehr") == "„Größe“ & mehr")
    }
}

struct SearchParsingTests {
    @Test func parsesDuckDuckGoResultsAndSkipsAds() {
        let html = """
        <div class="result"><a rel="nofollow" class="result__a" href="https://de.wikipedia.org/wiki/Kryptobiose">Kryptobiose – Wikipedia</a>
        <a class="result__snippet" href="x">Die <b>Kryptobiose</b> ist ein Zustand</a></div>
        <div class="result"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.geo.de%2Fartikel&amp;rut=1">GEO</a></div>
        <div class="result--ad"><a class="result__a" href="https://duckduckgo.com/y.js?ad_domain=shop.de">Anzeige</a></div>
        """
        let hits = DuckDuckGoSearch.parse(html)
        #expect(hits.map(\.url.absoluteString) == ["https://de.wikipedia.org/wiki/Kryptobiose", "https://www.geo.de/artikel"])
        #expect(hits[0].snippet == "Die Kryptobiose ist ein Zustand")
    }

    @Test func cleansWikipediaExtract() {
        let raw = "Einleitung Satz.\nZweiter Absatz.\n\n\nGeschichte\nText.\nEinzelnachweise\nQuelle 1"
        let cleaned = WikipediaClient.cleanExtract(raw)
        #expect(cleaned == "Einleitung Satz.\n\nZweiter Absatz.\n\nGeschichte\n\nText.")
    }

    @Test func trustTiersByDomain() {
        #expect(SourceTrust.tier(forHost: "www.nature.com") == .a)
        #expect(SourceTrust.tier(forHost: "de.wikipedia.org") == .b)
        #expect(SourceTrust.tier(forHost: "www.reddit.com") == .d)
        #expect(SourceTrust.tier(forHost: "blog.example.org") == .c)
        #expect(SourceTrust.tier(forHost: "www.uni-hamburg.de") == .b)
        #expect(SourceTrust.registrableDomain("www.bbc.co.uk") == "bbc.co.uk")
        #expect(SourceTrust.registrableDomain("de.wikipedia.org") == "wikipedia.org")
    }

    @Test func chunkerKeepsParagraphsAndIDs() {
        let paragraph = String(repeating: "Wort ", count: 150)
        let chunks = TextChunker.chunk([paragraph, paragraph, paragraph].joined(separator: "\n\n"), sourceID: "S1", targetWords: 220)
        #expect(chunks.map(\.id) == ["S1-C1", "S1-C2", "S1-C3"])
    }

    @Test func relevanceSelectsMatchingChunks() {
        let chunks = [
            SourceChunk(id: "C1", text: "Die Geschichte der Stadt Hamburg und ihr Hafen.", offset: 0),
            SourceChunk(id: "C2", text: "Bärtierchen überstehen in der Kryptobiose extreme Kälte.", offset: 50),
        ]
        let picked = TextChunker.selectRelevant(chunks, keywords: ["Kryptobiose", "Bärtierchen"], budgetChars: 1000, maxChunks: 1)
        #expect(picked.map(\.id) == ["C2"])
    }
}

struct LLMPlumbingTests {
    @Test func cleanerStripsFencesAndUnwrapsArray() {
        #expect(JSONResponseCleaner.clean("```json\n{\"a\":1}\n```") == "{\"a\":1}")
        #expect(JSONResponseCleaner.clean("Hier: {\"a\":1} fertig") == "{\"a\":1}")
        #expect(JSONResponseCleaner.clean("[{\"a\":1}]").contains("\"a\""))
        #expect(!JSONResponseCleaner.clean("[{\"a\":1}]").hasPrefix("["))
    }

    @Test func schemaFromGenerableIsValidJSONSchema() throws {
        let schema = try OpenRouterClient.jsonSchema(for: ClaimExtractionOutput.self)
        #expect(schema["type"] as? String == "object")
        let text = String(data: try JSONSerialization.data(withJSONObject: schema), encoding: .utf8) ?? ""
        #expect(text.contains("chunkID"))
        #expect(!text.contains("x-order"))
    }

    @Test func decodesModelOutputIntoGenerableType() throws {
        let json = #"{"claims":[{"chunkID":"S1-C1","text":"T","type":"number","quote":"Q","speaker":""}]}"#
        let output = try JSONResponseCleaner.decode(ClaimExtractionOutput.self, from: json)
        #expect(output.claims.first?.chunkID == "S1-C1")
    }

    @Test func allPromptsExistAndAreFullyFilled() throws {
        let required: [String: [String]] = [
            "plan": ["topic", "minutes", "search_language", "nerd_instruction", "digression_instruction", "category_instruction", "query_count", "today"],
            "extract_claims": ["topic", "language", "max_claims", "source_hint", "source_title", "source_publisher", "chunks"],
            "verify": ["items"],
            "outline": ["language", "minutes", "section_count", "nerd_instruction", "digression_instruction", "style_instruction", "category_instruction", "topic", "claims"],
            "script_section": ["language", "personas", "nerd_instruction", "digression_instruction", "style_instruction", "category_instruction", "speech_instruction", "target_words", "max_words", "section_hint",
                               "topic", "section_title", "section_goal", "previous", "claims", "other_claims"],
            "rewrite_segments": ["language", "claims", "segments"],
            "narrative_plan": ["language", "minutes", "guide", "section_count", "format_instruction", "nerd_instruction", "digression_instruction",
                               "style_instruction", "category_instruction", "topic", "claims"],
            "script_full": ["language", "guide", "personas", "format_instruction", "target_words", "max_words", "speech_instruction", "extra",
                            "topic", "plan", "previous", "sections", "claims"],
            "script_review": ["guide", "metrics", "script"],
            "script_revise": ["language", "guide", "personas", "format_instruction", "target_words", "issues", "claims", "script"],
            "guide_feedback": ["guide", "title", "feedback"],
        ]
        for (name, keys) in required {
            let values = Dictionary(uniqueKeysWithValues: keys.map { ($0, "X") })
            let prompt = try PromptLibrary.load(name, values: values)
            #expect(!prompt.system.isEmpty && !prompt.user.isEmpty, "\(name)")
            #expect(!(prompt.system + prompt.user).contains("{{"), "\(name) has unfilled placeholders")
        }
    }

    @Test func routerFallsBackAndDisablesPermanentFailures() async throws {
        let failing = StubClient(id: "a", error: .http(status: 404, message: "blocked"))
        let working = StubClient(id: "b", error: nil)
        let router = LLMRouter(chains: [.writer: [failing, working]])
        let first = try await router.generate(ResearchPlanOutput.self, role: .writer, task: "t", system: "", prompt: "")
        #expect(first.model == "b")
        #expect(await router.disabledClients["a"] != nil)
        #expect(await router.activeClient(for: .writer)?.id == "b")
    }

    @Test func routerRethrowsContextTooSmall() async {
        let router = LLMRouter(chains: [.writer: [StubClient(id: "a", error: .contextTooSmall), StubClient(id: "b", error: nil)]])
        await #expect(throws: LLMError.contextTooSmall) {
            _ = try await router.generate(ResearchPlanOutput.self, role: .writer, task: "t", system: "", prompt: "")
        }
    }

    @Test func optionsDeriveSensibleCounts() {
        var options = EpisodeOptions(topic: "x")
        options.minutes = 8
        #expect(options.targetWords == 1040)
        #expect((3...7).contains(options.sectionCount))
        options.digression = 3
        #expect(options.webQueryCount == 6)
    }
}


private struct StubClient: LLMClient {
    let id: String
    let error: LLMError?
    var displayName: String { id }
    var inputBudgetChars: Int { 10_000 }

    func generate<T: StructuredOutput>(_ type: T.Type, system: String, prompt: String, reasoning: Bool) async throws -> T {
        if let error { throw error }
        let json = #"{"subquestions":["a"],"webQueries":["b"],"wikipediaTitles":["c"],"paperQueries":["e"],"keywords":["d"]}"#
        return try JSONResponseCleaner.decode(T.self, from: json)
    }
}

struct NewSourceTests {
    @Test func rebuildsOpenAlexAbstract() {
        #expect(PaperSearch.rebuildAbstract(["Tardigrades": [0], "survive": [1], "drying.": [2]]) == "Tardigrades survive drying.")
    }

    @Test func parsesOpenAlexWorksAndClassifiesPreprints() throws {
        let words = Dictionary(uniqueKeysWithValues: (0..<60).map { ("w\($0)", [$0]) })
        let abstract = String(data: try JSONSerialization.data(withJSONObject: words), encoding: .utf8)!
        let json = """
        {"results":[
          {"id":"https://openalex.org/W1","display_name":"Review of anhydrobiosis","publication_year":2020,"type":"review",
           "doi":"https://doi.org/10.1/x","cited_by_count":120,"is_retracted":false,"language":"en",
           "primary_location":{"source":{"display_name":"FEBS Journal","type":"journal"},"version":"publishedVersion"},
           "best_oa_location":{"pdf_url":"https://example.org/a.pdf"},"abstract_inverted_index":\(abstract)},
          {"id":"https://openalex.org/W2","display_name":"Preprint","publication_year":2025,"type":"preprint",
           "cited_by_count":0,"is_retracted":false,"primary_location":{"source":{"display_name":"bioRxiv","type":"repository"}},
           "abstract_inverted_index":\(abstract)},
          {"id":"https://openalex.org/W3","display_name":"Retracted","type":"article","is_retracted":true,"abstract_inverted_index":\(abstract)}
        ]}
        """
        let works = try PaperSearch.parse(Data(json.utf8))
        #expect(works.map(\.title) == ["Review of anhydrobiosis", "Preprint"])
        #expect(works[0].isReview && !works[0].isPreprint && works[0].openAccessURL?.pathExtension == "pdf")
        #expect(works[1].isPreprint)
    }

    @Test func cleansPDFText() {
        let raw = "Tardi-\ngrades survive\ndrying.\n\nSecond para.\n\nReferences\nSmith 2001"
        #expect(PaperSearch.cleanPDFText(raw) == "Tardigrades survive drying.\n\nSecond para.")
    }

    @Test func parsesTranscriptFormats() {
        let podigee = #"[{"start":1,"end":2,"text":""},{"start":2,"end":3,"text":"Hallo zusammen."},{"start":3,"end":4,"text":"Heute Bärtierchen."}]"#
        #expect(PodcastSearch.parseTranscript(podigee, type: "application/json") == "Hallo zusammen. Heute Bärtierchen.")
        let p20 = #"{"version":"1.0.0","segments":[{"speaker":"A","body":"Erster Satz."},{"body":"Zweiter Satz."}]}"#
        #expect(PodcastSearch.parseTranscript(p20, type: "application/json") == "Erster Satz. Zweiter Satz.")
        let vtt = "WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.000\n<v Max>Hallo\n\n2\n00:00:02.000 --> 00:00:03.000\nWelt"
        #expect(PodcastSearch.parseTranscript(vtt, type: "text/vtt") == "Hallo Welt")
    }

    @Test func parsesAppleTTML() {
        let ttml = #"<tt><body><div><p begin="0" ttm:agent="SPEAKER_1"><span podcasts:unit="sentence"><span>Bärtierchen</span><span>sind</span><span>klein.</span></span></p><p begin="3"><span>Sehr&amp;klein.</span></p></div></body></tt>"#
        #expect(PodcastSearch.parseTTML(ttml) == "Bärtierchen sind klein.\n\nSehr&klein.")
    }

    @Test func findsTranscriptInFeedByGuidAndPrefersText() {
        let xml = """
        <rss><channel><item><title>Andere Folge</title><guid>aaa</guid>
        <podcast:transcript url="https://x/a.json" type="application/json"/></item>
        <item><title>Wie überleben Bärtierchen?</title><guid isPermaLink="false">164b66</guid>
        <podcast:transcript url="https://x/b.vtt" type="text/vtt"/>
        <podcast:transcript url="https://x/b.json" type="application/json"/></item></channel></rss>
        """
        let found = PodcastSearch.findTranscript(in: xml, guid: "164b66", title: "egal")
        #expect(found?.url.absoluteString == "https://x/b.json")
        #expect(PodcastSearch.findTranscript(in: xml, guid: nil, title: "Wie überleben Bärtierchen?")?.url.lastPathComponent == "b.json")
    }

    @Test func oldEpisodeOptionsDecodeWithAllSources() throws {
        let old = #"{"topic":"x","minutes":5,"nerdLevel":4,"speakerIDs":["max"],"digression":0,"language":"de","strictness":"standard"}"#
        let options = try JSONDecoder().decode(EpisodeOptions.self, from: Data(old.utf8))
        #expect(options.sources == SourceKind.defaultSet)
        #expect(options.category == .general)
        #expect(options.paperCount == 3 && options.podcastCount == 1)
    }


    @Test func papersInSameJournalAreIndependent() {
        let a = SourceDocument(id: "S1", kind: .paper, title: "A", publisher: "Nature", url: URL(string: "https://doi.org/1")!,
                               publishedAt: nil, language: "en", tier: .a, chunks: [])
        var b = a
        b.url = URL(string: "https://doi.org/2")!
        #expect(a.independenceKey != b.independenceKey)
    }
}

struct CrossrefTests {
    @Test func parsesRetractionCorrectionAndConcern() {
        func data(_ json: String) -> Data { Data(json.utf8) }
        #expect(CrossrefCheck.parse(data(#"{"message":{"updated-by":[{"type":"correction","source":"retraction-watch"},{"type":"retraction","source":"retraction-watch"}]}}"#))
                == .retracted(source: "retraction-watch"))
        #expect(CrossrefCheck.parse(data(#"{"message":{"updated-by":[{"type":"expression_of_concern"}]}}"#)) == .concern)
        #expect(CrossrefCheck.parse(data(#"{"message":{"updated-by":[{"type":"erratum"}]}}"#)) == .corrected)
        #expect(CrossrefCheck.parse(data(#"{"message":{"title":["ok"]}}"#)) == .ok)
        #expect(CrossrefCheck.cleanDOI("https://doi.org/10.1016/S0140-6736(97)11096-0") == "10.1016/S0140-6736(97)11096-0")
    }

    @Test func warningCapsClaimsAtYellow() {
        var paper = SourceDocument(id: "S1", kind: .paper, title: "P", publisher: "Lancet", url: URL(string: "https://doi.org/1")!,
                                   publishedAt: nil, language: "en", tier: .a, chunks: [])
        let claim = Claim(id: "K1", text: "t", type: .fact, evidence: [Evidence(sourceID: "S1", chunkID: "S1-C1", quote: "q", match: .exact)],
                          verdict: .supported, numberCheck: NumberCheckResult(checked: [], missing: [], rounded: []))
        #expect(FactCheckRules().evaluate(claim, sources: [paper]).light == .green)
        paper.integrityWarning = "Korrektur"
        #expect(FactCheckRules().evaluate(claim, sources: [paper]).light == .yellow)
    }
}

/// Live: DEEPCAST_CROSSREF=1 – the retracted Wakefield paper must be detected.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEEPCAST_CROSSREF"] != nil), .tags(.live))
struct LiveCrossrefTests {
    @Test func detectsWakefieldRetraction() async {
        let status = await CrossrefCheck().status(doi: "10.1016/S0140-6736(97)11096-0")
        print("LIVE-CROSSREF \(status)")
        if case .retracted = status {} else { Issue.record("expected retraction, got \(status)") }
    }
}

struct CustomSourceTests {
    @Test func parsesURLsAndFiles() throws {
        #expect(CustomSource.parse("https://www.spiegel.de/a")?.isFile == false)
        #expect(CustomSource.parse("ftp://x") == nil)
        #expect(CustomSource.parse("kein link") == nil)
        let file = FileManager.default.temporaryDirectory.appending(path: "custom-\(UUID().uuidString).md")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(CustomSource.parse(file.path)?.isFile == true)
    }

    @Test func loadsMarkdownFileAsCustomSource() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "notiz-\(UUID().uuidString).md")
        let body = "# Meine Notizen\n\n" + String(repeating: "Bärtierchen leben im Moos und überstehen Austrocknung. ", count: 20)
        try body.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let document = try CustomSourceLoader().loadFile(file, tier: .b)
        #expect(document.kind == .custom && document.tier == .b && !document.chunks.isEmpty)
        #expect(!document.chunks[0].text.contains("#"))
    }

    @Test func rejectsUnsupportedAndEmptyFiles() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "leer-\(UUID().uuidString).txt")
        try "kurz".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: CustomSourceError.self) { try CustomSourceLoader().loadFile(file, tier: .c) }
        #expect(throws: CustomSourceError.self) { try CustomSourceLoader().loadFile(URL(fileURLWithPath: "/tmp/x.docx"), tier: .c) }
    }

    @Test func customSourcesSurviveEncodingAndAreNotSelectable() throws {
        var options = EpisodeOptions(topic: "x")
        options.customSources = [CustomSource(location: "https://example.org/a", tier: .a)]
        let decoded = try JSONDecoder().decode(EpisodeOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded.customSources.first?.tier == .a)
        #expect(!SourceKind.selectable.contains(.custom))
    }
}

struct BookSourceTests {
    @Test func parsesGutenbergOPDSAndDropsFuzzyHits() {
        let xml = """
        <feed><entry><id>https://www.gutenberg.org/ebooks/authors/search.opds/?query=x</id><title>Authors</title></entry>
        <entry><id>https://www.gutenberg.org/ebooks/1228.opds</id><title>On the Origin of Species</title><content type="text">Charles Darwin</content></entry>
        <entry><id>https://www.gutenberg.org/ebooks/2591.opds</id><title>Grimms&#39; Fairy Tales</title><content type="text">Jacob Grimm</content></entry></feed>
        """
        let books = BookSearch.parseGutenberg(xml, query: "darwin species")
        #expect(books.map(\.id) == ["1228"])
        #expect(books[0].textURL.absoluteString == "https://www.gutenberg.org/cache/epub/1228/pg1228.txt")
    }

    @Test func openLibraryOnlyPublicFullTexts() {
        let json = #"{"docs":[{"key":"/works/OL1W","title":"Free","ebook_access":"public","ia":["free00"],"first_publish_year":1915},{"key":"/works/OL2W","title":"Borrow","ebook_access":"borrowable","ia":["b00"]},{"key":"/works/OL3W","title":"None","ebook_access":"no_ebook"}]}"#
        let books = BookSearch.parseOpenLibrary(Data(json.utf8))
        #expect(books.map(\.id) == ["free00"])
        #expect(books[0].textURL.absoluteString == "https://archive.org/download/free00/free00_djvu.txt")
    }

    @Test func stripsGutenbergHeaderAndFooter() {
        let raw = "License blah\n*** START OF THE PROJECT GUTENBERG EBOOK X ***\nChapter one text.\n*** END OF THE PROJECT GUTENBERG EBOOK X ***\nMore license"
        #expect(BookSearch.stripGutenbergBoilerplate(raw).trimmingCharacters(in: .whitespacesAndNewlines) == "Chapter one text.")
    }

    @Test func rewrapsHardWrappedParagraphs() {
        let text = "This is a long line of a book that\nwas hard wrapped at the end.\n\n12\n\nSecond paragraph that is also long enough to keep."
        #expect(BookSearch.paragraphs(text) == "This is a long line of a book that was hard wrapped at the end.\n\nSecond paragraph that is also long enough to keep.")
    }

    @Test func historyCategoryIncludesBooks() {
        #expect(EpisodeCategory.history.preset.sources.isSuperset(of: [.gutenberg, .openLibrary]))
        #expect(!SourceKind.defaultSet.contains(.gutenberg))
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEEPCAST_BOOKS"] != nil), .tags(.live))
struct LiveBookTests {
    @Test func gutenbergAndOpenLibraryDeliverRelevantChunks() async throws {
        let search = BookSearch()
        let gutenberg = try await search.searchGutenberg("darwin origin species", limit: 1)
        let darwin = try #require(gutenberg.first)
        let doc = try #require(try await search.document(for: darwin, keywords: ["natural selection", "species", "variation"]))
        print("LIVE-BOOK Gutenberg: \(doc.title) – \(doc.chunks.count) Abschnitte")
        let openLibrary = try await search.searchOpenLibrary("history hanseatic league", language: .en, limit: 1)
        if let book = openLibrary.first, let doc2 = try await search.document(for: book, keywords: ["hanse", "hanseatic", "merchants", "london"]) {
            print("LIVE-BOOK Open Library: \(doc2.title) – \(doc2.chunks.count) Abschnitte")
        } else {
            print("LIVE-BOOK Open Library: kein öffentlicher Volltext")
        }
        #expect(doc.chunks.count >= 10)
    }
}
