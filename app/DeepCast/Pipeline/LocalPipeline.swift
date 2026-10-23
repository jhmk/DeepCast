import Foundation

typealias PipelineProgress = @Sendable (PipelineEvent) async -> Void

/// App-side engine interface (ADR-002). The PoC implements it in Swift; later a client for
/// the Python engine can replace it.
protocol EngineClient: Sendable {
    func research(_ options: EpisodeOptions, folder: URL, progress: @escaping PipelineProgress) async throws -> ResearchDossier
    func writeScript(_ dossier: ResearchDossier, personas: [Persona], folder: URL, progress: @escaping PipelineProgress) async throws -> (EpisodeScript, ResearchDossier)
}

enum PipelineError: LocalizedError {
    case noSources([String])
    case noClaims
    case noScript

    var errorDescription: String? {
        switch self {
        case .noSources(let notes):
            String(localized: "Keine Quelle konnte gelesen werden. \(notes.prefix(3).joined(separator: " · "))")
        case .noClaims: String(localized: "Aus den Quellen konnten keine belegten Aussagen gewonnen werden.")
        case .noScript: String(localized: "Das Skript konnte nicht erzeugt werden.")
        }
    }
}

struct LocalPipeline: EngineClient {
    let router: LLMRouter
    var wikipedia = WikipediaClient()
    var duckDuckGo = DuckDuckGoSearch()
    var fetcher = WebPageFetcher()
    var papers = PaperSearch()
    var podcasts = PodcastSearch()
    var rules = FactCheckRules()
    var domainRules = DomainRules()
    var paywall = PaywallConfig()
    /// Podcast-Leitfaden (style guide), sent with narrative, script, review and revision prompts.
    var styleGuide = StyleGuideStore.fallback

    // MARK: - Research (stages 1–7, then review pause)

    func research(_ options: EpisodeOptions, folder: URL, progress: @escaping PipelineProgress) async throws -> ResearchDossier {
        try await research(options, folder: folder, resume: false, progress: progress)
    }

    /// Runs research. With `resume`, saved artifacts (plan.json, dossier.json incl. checkpoint)
    /// are reused: finished stages, already extracted sources and verified claims are skipped.
    func research(_ options: EpisodeOptions, folder: URL, resume: Bool, progress: @escaping PipelineProgress) async throws -> ResearchDossier {
        var rules = rules
        rules.strictness = options.strictness
        let saved = resume ? ArtifactStore.load(ResearchDossier.self, name: "dossier.json", in: folder) : nil
        let resumed = String(localized: "aus Zwischenstand übernommen")

        // 1. Plan
        let plan: ResearchPlanOutput
        if resume, let savedPlan = ArtifactStore.load(ResearchPlanOutput.self, name: "plan.json", in: folder) {
            plan = savedPlan
            await progress(PipelineEvent(stage: .plan, fraction: 1, message: resumed))
        } else {
            await progress(PipelineEvent(stage: .plan, fraction: nil, message: String(localized: "Teilfragen und Suchbegriffe …")))
            plan = try await makePlan(options)
            try? ArtifactStore.save(plan, as: "plan.json", in: folder)
            await progress(PipelineEvent(stage: .plan, fraction: 1, message: plan.subquestions.joined(separator: " · ")))
        }

        // 2.–3. Search and fetch
        var dossier: ResearchDossier
        if let saved, !saved.sources.isEmpty {
            dossier = saved
            dossier.options = options
            await progress(PipelineEvent(stage: .fetch, fraction: 1, message: String(localized: "\(saved.sources.count) Quellen \(resumed)")))
        } else {
            dossier = ResearchDossier(options: options, createdAt: .now)
            dossier.subquestions = plan.subquestions
            dossier.keywords = plan.keywords
            dossier.checkpoint = ResearchCheckpoint()
            await progress(PipelineEvent(stage: .search, fraction: nil, message: String(localized: "Wikipedia und DuckDuckGo …")))
            let (candidates, searchNotes) = await searchCandidates(options: options, plan: plan, progress: progress)
            dossier.notes += searchNotes
            let (webSources, fetchNotes) = try await fetchSources(candidates, options: options, progress: progress)
            dossier.notes += fetchNotes
            let (extra, extraNotes) = await extraSources(options: options, plan: plan, progress: progress)
            dossier.notes += extraNotes
            var own: [SourceDocument] = []
            let loader = CustomSourceLoader(paywall: paywall)
            for custom in options.customSources {
                await progress(PipelineEvent(stage: .fetch, fraction: nil, message: String(localized: "Eigene Quelle: \(custom.displayName)")))
                do { own.append(try await loader.load(custom)) } catch {
                    dossier.notes.append(String(localized: "Eigene Quelle \(custom.displayName) nicht lesbar: \(error.localizedDescription)"))
                }
            }
            dossier.sources = Self.renumber(own + webSources + extra)
            guard !dossier.sources.isEmpty else { throw PipelineError.noSources(dossier.notes) }
            dossier.notes += SyndicationDetector.mark(&dossier.sources)
            try? ArtifactStore.save(dossier, as: "dossier.json", in: folder)
        }

        // 4. Extract claims (checkpoint after every source)
        if dossier.claims.isEmpty {
            var checkpoint = dossier.checkpoint ?? ResearchCheckpoint()
            let keywords = plan.keywords + plan.subquestions + [options.topic]
            let sources = dossier.sources
            for (index, source) in sources.enumerated() where !checkpoint.extractedSourceIDs.contains(source.id) {
                try Task.checkCancellation()
                await progress(PipelineEvent(stage: .extract, fraction: Double(index) / Double(sources.count),
                                             message: String(localized: "\(source.publisher): \(source.title)")))
                let (claims, notes) = try await extractClaims(from: source, options: options, keywords: keywords)
                checkpoint.rawClaims += claims
                checkpoint.extractedSourceIDs.append(source.id)
                dossier.notes += notes
                dossier.checkpoint = checkpoint
                try? ArtifactStore.save(dossier, as: "dossier.json", in: folder)
            }
            dossier.claims = ClaimMerger.merge(checkpoint.rawClaims)
            guard !dossier.claims.isEmpty else { throw PipelineError.noClaims }
            dossier.notes += ContradictionDetector.mark(&dossier.claims)
            for index in dossier.claims.indices {
                let quotes = dossier.claims[index].evidence.map(\.quote)
                dossier.claims[index].numberCheck = NumberMatcher.check(claim: dossier.claims[index].text, evidence: quotes)
            }
            try? ArtifactStore.save(dossier, as: "dossier.json", in: folder)
            await progress(PipelineEvent(stage: .extract, fraction: 1,
                                         message: String(localized: "\(dossier.claims.count) Aussagen aus \(sources.count) Quellen")))
        } else {
            await progress(PipelineEvent(stage: .extract, fraction: 1, message: String(localized: "\(dossier.claims.count) Aussagen \(resumed)")))
        }

        // 5. Verify unverified claims (independent verifier sees only claim + evidence).
        try await verify(&dossier, folder: folder, progress: progress)
        for index in dossier.claims.indices {
            let outcome = rules.evaluate(dossier.claims[index], sources: dossier.sources)
            dossier.claims[index].light = outcome.light
            dossier.claims[index].lightReasons = outcome.reasons
        }
        dossier.calls += await router.calls
        for (model, reason) in await router.disabledClients {
            dossier.notes.append(String(localized: "\(FactCheckReport.modelName(model)) übersprungen: \(reason)"))
        }
        dossier.checkpoint = nil
        try ArtifactStore.save(dossier, as: "dossier.json", in: folder)
        await progress(PipelineEvent(stage: .verify, fraction: 1, message: String(localized:
            "🟢 \(dossier.count(.green)) · 🟡 \(dossier.count(.yellow)) · 🔴 \(dossier.count(.red))")))
        return dossier
    }

    /// Adds one own source to a finished dossier (review step): extract, merge, verify, re-evaluate.
    func addSource(_ custom: CustomSource, to input: ResearchDossier, folder: URL, progress: @escaping PipelineProgress) async throws -> ResearchDossier {
        var dossier = input
        var rules = rules
        rules.strictness = dossier.options.strictness
        await progress(PipelineEvent(stage: .fetch, fraction: nil, message: String(localized: "Eigene Quelle: \(custom.displayName)")))
        let loaded = try await CustomSourceLoader(paywall: paywall).load(custom)
        let source = loaded.renumbered("S\(dossier.sources.count + 1)")
        dossier.sources.append(source)
        dossier.options.customSources.append(custom)

        await progress(PipelineEvent(stage: .extract, fraction: nil, message: source.title))
        let keywords = dossier.keywords + dossier.subquestions + [dossier.options.topic]
        let (claims, notes) = try await extractClaims(from: source, options: dossier.options, keywords: keywords)
        dossier.notes += notes
        let existingCount = dossier.claims.count
        dossier.claims = ClaimMerger.merge(dossier.claims + claims)
        for index in dossier.claims.indices where index >= existingCount {
            let quotes = dossier.claims[index].evidence.map(\.quote)
            dossier.claims[index].numberCheck = NumberMatcher.check(claim: dossier.claims[index].text, evidence: quotes)
        }
        for index in dossier.claims.indices { dossier.claims[index].contestedWith = nil }
        _ = ContradictionDetector.mark(&dossier.claims)
        try await verify(&dossier, folder: folder, progress: progress)
        for index in dossier.claims.indices {
            let outcome = rules.evaluate(dossier.claims[index], sources: dossier.sources)
            dossier.claims[index].light = outcome.light
            dossier.claims[index].lightReasons = outcome.reasons
        }
        dossier.calls += await router.calls
        dossier.notes.append(String(localized: "Eigene Quelle hinzugefügt: \(source.id) \(source.title) (\(dossier.claims.count - existingCount) neue Aussagen)"))
        try ArtifactStore.save(dossier, as: "dossier.json", in: folder)
        return dossier
    }

    private func makePlan(_ options: EpisodeOptions) async throws -> ResearchPlanOutput {
        let prompt = try PromptLibrary.load("plan", values: [
            "topic": options.topic,
            "minutes": String(options.minutes),
            "search_language": options.language.promptName,
            "nerd_instruction": options.nerdInstruction,
            "digression_instruction": options.digressionInstruction,
            "query_count": String(options.webQueryCount),
            "category_instruction": options.categoryMix.instruction,
            "today": Date().formatted(date: .long, time: .omitted),
        ])
        var plan = try await router.generate(ResearchPlanOutput.self, role: .research, task: "plan",
                                             system: prompt.system, prompt: prompt.user).value
        plan.webQueries = plan.webQueries.map { $0.replacingOccurrences(of: "\"", with: "") }.filter { !$0.isEmpty }
        if plan.webQueries.isEmpty { plan.webQueries = [options.topic] }
        if plan.keywords.isEmpty { plan.keywords = TextChunker.terms(options.topic) }
        return plan
    }

    // MARK: Search

    struct Candidate: Sendable, Hashable {
        enum Kind: Hashable, Sendable { case wikipedia(title: String, language: String), web }
        let kind: Kind
        let url: URL?
        let title: String
        var score: Double
    }

    private func searchCandidates(options: EpisodeOptions, plan: ResearchPlanOutput, progress: @escaping PipelineProgress) async -> ([Candidate], [String]) {
        var notes: [String] = []
        var candidates: [Candidate] = []
        let language = options.language.rawValue

        // Wikipedia: planned titles + search for the topic.
        var titles = options.sources.contains(.wikipedia) ? plan.wikipediaTitles : []
        if options.sources.contains(.wikipedia), let found = try? await wikipedia.search(options.topic, language: language, limit: 2) {
            titles += found
        }
        var seen = Set<String>()
        for title in titles where seen.insert(title.lowercased()).inserted {
            candidates.append(Candidate(kind: .wikipedia(title: title, language: language), url: nil, title: title, score: 2.5))
        }
        if options.sources.contains(.wikipedia), options.nerdLevel >= 4, options.language == .de, let english = plan.wikipediaTitles.first ?? titles.first,
           let found = try? await wikipedia.search(english, language: "en", limit: 1).first {
            candidates.append(Candidate(kind: .wikipedia(title: found, language: "en"), url: nil, title: found, score: 1.8))
        }

        // DuckDuckGo web search.
        var webScores: [URL: (Candidate, Int)] = [:]
        var failures = 0
        let webQueries = options.sources.contains(.web)
            ? Array(plan.webQueries.prefix(options.webQueryCount)) + options.categoryMix.extraQueries(topic: options.topic, language: options.language)
            : []
        for (index, query) in webQueries.enumerated() {
            await progress(PipelineEvent(stage: .search, fraction: Double(index) / Double(max(1, webQueries.count)), message: query))
            do {
                for hit in try await duckDuckGo.search(query, language: options.language, limit: 6) {
                    guard let host = hit.url.host(), !host.hasSuffix("wikipedia.org"),
                          !hit.url.pathExtension.lowercased().hasPrefix("pdf") else { continue }
                    guard !domainRules.isBlocked(host) else { continue }
                    let tier = domainRules.tier(forHost: host)
                    guard tier != .d else { continue }
                    var weight: Double = switch tier { case .a: 3; case .b: 2; default: 1 }
                    if options.nerdLevel >= 4, tier == .a { weight += 1 }
                    if options.nerdLevel <= 2, tier == .b { weight += 0.5 }
                    let score = weight + 1 / Double(hit.rank + 1)
                    if let existing = webScores[hit.url] {
                        webScores[hit.url] = (Candidate(kind: .web, url: hit.url, title: hit.title, score: max(existing.0.score, score) + 0.5), existing.1 + 1)
                    } else {
                        webScores[hit.url] = (Candidate(kind: .web, url: hit.url, title: hit.title, score: score), 1)
                    }
                }
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            notes.append(String(localized: "DuckDuckGo: \(failures) Suchanfragen fehlgeschlagen."))
        }
        // Max two pages per publisher.
        var perPublisher: [String: Int] = [:]
        for (candidate, _) in webScores.values.sorted(by: { $0.0.score > $1.0.score }) {
            let publisher = SourceTrust.registrableDomain(candidate.url?.host() ?? "")
            guard perPublisher[publisher, default: 0] < 2 else { continue }
            perPublisher[publisher, default: 0] += 1
            candidates.append(candidate)
        }
        await progress(PipelineEvent(stage: .search, fraction: 1, message: String(localized: "\(candidates.count) Kandidaten")))
        return (candidates, notes)
    }

    // MARK: Fetch

    private func fetchSources(_ candidates: [Candidate], options: EpisodeOptions, progress: @escaping PipelineProgress) async throws -> ([SourceDocument], [String]) {
        let wikiCandidates = candidates.filter { if case .wikipedia = $0.kind { true } else { false } }
        let webCandidates = candidates.filter { $0.kind == .web }.sorted { $0.score > $1.score }
        let maxWiki = min(3, max(1, options.maxSources / 3))
        let maxWeb = options.sources.contains(.web) ? options.maxSources - min(maxWiki, wikiCandidates.count) : 0

        var documents: [(Double, SourceDocument)] = []
        var notes: [String] = []
        var attempts = 0
        let totalPlanned = Double(min(wikiCandidates.count, maxWiki) + maxWeb)

        // Wikipedia
        var wikiCount = 0
        var seenTitles = Set<String>()
        for candidate in wikiCandidates where wikiCount < maxWiki {
            try Task.checkCancellation()
            guard case .wikipedia(let title, let language) = candidate.kind else { continue }
            attempts += 1
            await progress(PipelineEvent(stage: .fetch, fraction: Double(documents.count) / totalPlanned, message: "Wikipedia: \(title)"))
            guard let page = try? await wikipedia.page(title: title, language: language),
                  seenTitles.insert(page.title).inserted else { continue }
            wikiCount += 1
            documents.append((candidate.score, SourceDocument(
                id: "", kind: .wikipedia, title: "\(page.title) – Wikipedia (\(language.uppercased()))",
                publisher: "\(language).wikipedia.org", url: page.url, publishedAt: page.lastEdited,
                language: language, tier: .b, chunks: [], notes: ["Stand des Artikels = letzte Bearbeitung"])
                .withText(page.text)))
        }

        // Web pages, four at a time, more candidates if some fail.
        var queue = webCandidates[...]
        var webCount = 0
        var paywalled: [(Candidate, URL)] = []
        while webCount < maxWeb, !queue.isEmpty, attempts < options.maxSources * 3 {
            try Task.checkCancellation()
            let batch = Array(queue.prefix(min(4, maxWeb - webCount)))
            queue = queue.dropFirst(batch.count)
            attempts += batch.count
            await progress(PipelineEvent(stage: .fetch, fraction: Double(documents.count) / totalPlanned,
                                         message: batch.compactMap { $0.url?.host() }.joined(separator: ", ")))
            let results = await withTaskGroup(of: (Candidate, Result<WebPageFetcher.Page, Error>).self) { group in
                for candidate in batch {
                    group.addTask {
                        guard let url = candidate.url else { return (candidate, .failure(URLError(.badURL))) }
                        do { return (candidate, .success(try await fetcher.fetch(url))) } catch { return (candidate, .failure(error)) }
                    }
                }
                var collected: [(Candidate, Result<WebPageFetcher.Page, Error>)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (candidate, result) in results {
                let host = candidate.url?.host() ?? "?"
                switch result {
                case .success(let page):
                    let finalHost = page.url.host() ?? host
                    if domainRules.isBlocked(finalHost) {
                        notes.append(String(localized: "\(finalHost) gesperrt (Domain-Liste)"))
                        continue
                    }
                    var sourceNotes: [String] = []
                    if page.extracted.paywalled, paywall.enabled, paywalled.count < paywall.maxArticles {
                        paywalled.append((candidate, page.url))
                        continue
                    }
                    if page.extracted.paywalled { sourceNotes.append(String(localized: "Paywall – nur frei sichtbarer Teil")) }
                    if SourceTrust.isTourismBoard(host: finalHost) { sourceNotes.append(String(localized: "Offizielle Tourismusseite (Werbung) – Fakten meist korrekt, Bewertungen nicht neutral")) }
                    if SourceTrust.isPreprint(host: finalHost) { sourceNotes.append(String(localized: "Preprint (nicht begutachtet)")) }
                    let title = page.extracted.title.isEmpty ? candidate.title : page.extracted.title
                    documents.append((candidate.score, SourceDocument(
                        id: "", kind: .web, title: title, publisher: SourceTrust.registrableDomain(finalHost),
                        url: page.url, publishedAt: page.extracted.publishedAt,
                        language: page.extracted.language ?? options.language.rawValue,
                        tier: domainRules.tier(forHost: finalHost), chunks: [], notes: sourceNotes)
                        .withText(page.extracted.text)))
                    webCount += 1
                case .failure(let error):
                    if paywall.enabled, case WebPageFetcher.FetchError.tooShort = error, let url = candidate.url,
                       paywalled.count < paywall.maxArticles {
                        paywalled.append((candidate, url))
                    } else {
                        notes.append(String(localized: "\(host) nicht lesbar: \(error.localizedDescription)"))
                    }
                }
            }
        }

        // Paywall fallback (opt-in): archive.is snapshot, then Waterfox + Bypass Paywalls Clean.
        if !paywalled.isEmpty {
            await progress(PipelineEvent(stage: .fetch, fraction: nil, message: String(localized: "Paywall-Abruf für \(paywalled.count) Artikel …")))
            let results = await PaywallFetcher(config: paywall).fetch(paywalled.map(\.1)) { message in
                await progress(PipelineEvent(stage: .fetch, fraction: nil, message: message))
            }
            for (url, result) in results {
                guard let candidate = paywalled.first(where: { $0.1 == url })?.0 else { continue }
                let host = url.host() ?? "?"
                switch result {
                case .success(let fetched):
                    var document = SourceDocument(
                        id: "", kind: .web, title: fetched.page.extracted.title.isEmpty ? candidate.title : fetched.page.extracted.title,
                        publisher: SourceTrust.registrableDomain(host), url: url, publishedAt: fetched.page.extracted.publishedAt,
                        language: fetched.page.extracted.language ?? options.language.rawValue,
                        tier: domainRules.tier(forHost: host), chunks: [],
                        notes: [String(localized: "Paywall-Artikel, gelesen über \(fetched.method) – Volltext bleibt lokal, Shownotes nur mit Link")])
                    document.fetchMethod = fetched.method
                    documents.append((candidate.score, document.withText(fetched.page.extracted.text)))
                case .failure(let error):
                    notes.append(String(localized: "\(host) (Paywall) nicht lesbar: \(error.localizedDescription)"))
                }
            }
        }

        // Stable IDs S1…Sn, best sources first.
        let sorted = documents.sorted { $0.0 > $1.0 }.map(\.1)
        await progress(PipelineEvent(stage: .fetch, fraction: 1, message: String(localized: "\(sorted.count) Web-Quellen gelesen")))
        return (sorted, notes)
    }

    static func renumber(_ documents: [SourceDocument]) -> [SourceDocument] {
        documents.enumerated().map { index, document in document.renumbered("S\(index + 1)") }
    }

    // MARK: Papers, podcasts

    private func extraSources(options: EpisodeOptions, plan: ResearchPlanOutput, progress: @escaping PipelineProgress) async -> ([SourceDocument], [String]) {
        var documents: [SourceDocument] = []
        var notes: [String] = []

        // Wikivoyage (travel guide wiki, same API as Wikipedia).
        if options.sources.contains(.wikivoyage) {
            await progress(PipelineEvent(stage: .fetch, fraction: nil, message: "Wikivoyage …"))
            let voyage = WikipediaClient(site: "wikivoyage")
            let language = options.language.rawValue
            var titles = (try? await voyage.search(options.topic, language: language, limit: 2)) ?? []
            for title in plan.wikipediaTitles.prefix(2) {
                if let found = try? await voyage.search(title, language: language, limit: 1).first { titles.append(found) }
            }
            var seen = Set<String>()
            var found = 0
            for title in titles where found < 2 && seen.insert(title.lowercased()).inserted {
                guard let page = try? await voyage.page(title: title, language: language) else { continue }
                var document = SourceDocument(
                    id: "", kind: .wikivoyage, title: "\(page.title) – Wikivoyage (\(language.uppercased()))",
                    publisher: "\(language).wikivoyage.org", url: page.url, publishedAt: page.lastEdited,
                    language: language, tier: .b, chunks: [],
                    notes: [String(localized: "Reiseführer-Wiki – praktische Angaben vor Ort prüfen")])
                document.chunks = TextChunker.chunk(page.text, sourceID: "TMP")
                documents.append(document)
                found += 1
            }
            if found == 0 { notes.append(String(localized: "Kein passender Wikivoyage-Artikel gefunden.")) }
        }

        // Papers (OpenAlex): English technical queries, reviews preferred for nerds.
        if options.paperCount > 0 {
            await progress(PipelineEvent(stage: .fetch, fraction: nil, message: String(localized: "Wissenschaftliche Paper (OpenAlex) …")))
            var queries = plan.paperQueries.filter { !$0.isEmpty }
            if queries.isEmpty { queries = [options.topic] }
            var seen = Set<String>()
            var works: [PaperSearch.Work] = []
            for query in queries.prefix(2) where works.count < options.paperCount {
                do {
                    for work in try await papers.search(query, limit: options.paperCount, preferReviews: options.nerdLevel >= 4)
                    where seen.insert(work.id).inserted && works.count < options.paperCount {
                        works.append(work)
                    }
                } catch {
                    notes.append(String(localized: "OpenAlex: \(error.localizedDescription)"))
                }
            }
            for work in works {
                try? Task.checkCancellation()
                await progress(PipelineEvent(stage: .fetch, fraction: nil, message: "Paper: \(work.title)"))
                var status = CrossrefCheck.Status.ok
                if let doi = work.doi?.absoluteString { status = await CrossrefCheck().status(doi: doi) }
                if case .retracted = status {
                    notes.append(String(localized: "Paper ausgeschlossen – \(status.warning ?? ""): \(work.title)"))
                    continue
                }
                var document = await papers.document(for: work)
                if let warning = status.warning {
                    document.integrityWarning = warning
                    document.notes.append(warning)
                }
                documents.append(document)
            }
            if works.isEmpty { notes.append(String(localized: "Keine passenden Paper gefunden.")) }
        }

        // Books with legal full texts (Open Library public scans, Project Gutenberg).
        if options.bookCount > 0 {
            await progress(PipelineEvent(stage: .fetch, fraction: nil, message: String(localized: "Bücher (Open Library, Gutenberg) …")))
            let books = BookSearch()
            let query = plan.paperQueries.first ?? plan.wikipediaTitles.first ?? options.topic
            var candidates: [BookSearch.Book] = []
            if options.sources.contains(.openLibrary) {
                candidates += (try? await books.searchOpenLibrary(query, language: options.language, limit: 3)) ?? []
            }
            if options.sources.contains(.gutenberg) {
                candidates += (try? await books.searchGutenberg(query, limit: 3)) ?? []
            }
            let keywords = plan.keywords + plan.subquestions + [options.topic] + plan.paperQueries
            var found = 0
            for book in candidates where found < options.bookCount {
                try? Task.checkCancellation()
                await progress(PipelineEvent(stage: .fetch, fraction: nil, message: "Buch: \(book.title)"))
                if let document = try? await books.document(for: book, keywords: keywords) {
                    documents.append(document)
                    found += 1
                }
            }
            if found == 0 { notes.append(String(localized: "Kein passendes frei lesbares Buch gefunden.")) }
        }

        // Podcasts with transcripts (RSS podcast:transcript or local Apple Podcasts cache).
        if options.podcastCount > 0 {
            await progress(PipelineEvent(stage: .fetch, fraction: nil, message: String(localized: "Podcast-Transkripte …")))
            var found = 0
            var checked = 0
            var seen = Set<Int>()
            let queries = Array(([plan.webQueries.first].compactMap { $0 } + plan.keywords.prefix(2) + [options.topic]).prefix(3))
            outer: for query in queries {
                guard let episodes = try? await podcasts.search(query, language: options.language, limit: 8) else { continue }
                for episode in episodes where seen.insert(episode.trackID).inserted {
                    if found >= options.podcastCount || checked >= 8 { break outer }
                    checked += 1
                    await progress(PipelineEvent(stage: .fetch, fraction: nil, message: "Podcast: \(episode.show)"))
                    if let document = await podcasts.document(for: episode) {
                        documents.append(document)
                        found += 1
                    }
                }
            }
            if found == 0 {
                notes.append(String(localized: "Keine Podcast-Folge mit Transkript gefunden (\(checked) geprüft)."))
            }
        }

        return (documents, notes)
    }

    // MARK: Extract

    private func extractClaims(from source: SourceDocument, options: EpisodeOptions, keywords: [String]) async throws -> ([Claim], [String]) {
        let budget = max(2_500, await router.inputBudget(for: .research) - 2_500)
        let isSmallModel = budget < 10_000
        let relevant = TextChunker.selectRelevant(source.chunks, keywords: keywords,
                                                  budgetChars: isSmallModel ? budget * 3 : budget,
                                                  maxChunks: isSmallModel ? 4 : 10)
        guard !relevant.isEmpty else { return ([], [String(localized: "\(source.publisher): kein passender Abschnitt")]) }

        var batches: [[SourceChunk]] = [[]]
        var used = 0
        for chunk in relevant {
            if used + chunk.text.count > budget, !batches[batches.count - 1].isEmpty {
                batches.append([])
                used = 0
            }
            batches[batches.count - 1].append(chunk)
            used += chunk.text.count
        }

        var claims: [Claim] = []
        var rejected = 0
        var pending = batches
        while !pending.isEmpty {
            try Task.checkCancellation()
            let batch = pending.removeFirst()
            let prompt = try PromptLibrary.load("extract_claims", values: [
                "topic": options.topic,
                "language": options.language.promptName,
                "max_claims": String(isSmallModel ? 5 : 12),
                "source_hint": [source.kind.extractionHint, options.categoryMix.extractionHint].filter { !$0.isEmpty }.joined(separator: "\n"),
                "source_title": source.title,
                "source_publisher": source.publisher,
                "chunks": batch.map { "[\($0.id)]\n\($0.text)" }.joined(separator: "\n\n"),
            ])
            let output: ClaimExtractionOutput
            do {
                output = try await router.generate(ClaimExtractionOutput.self, role: .research, task: "extract \(source.id)",
                                                   system: prompt.system, prompt: prompt.user).value
            } catch LLMError.contextTooSmall {
                if batch.count > 1 {
                    pending.insert(contentsOf: [Array(batch.prefix(batch.count / 2)), Array(batch.suffix(batch.count - batch.count / 2))], at: 0)
                } else if let chunk = batch.first, chunk.text.count > 600 {
                    pending.insert([SourceChunk(id: chunk.id, text: String(chunk.text.prefix(chunk.text.count / 2)), offset: chunk.offset)], at: 0)
                }
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return (claims, [String(localized: "\(source.publisher): Aussagen nicht extrahierbar (\(error.localizedDescription))")])
            }
            for item in output.claims {
                guard let evidence = locate(item, in: source) else { rejected += 1; continue }
                let type = ClaimType(rawValue: item.type) ?? .fact
                var claim = Claim(id: "", text: item.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                  type: type, evidence: [evidence])
                if type == .quote {
                    let chunk = source.chunks.first { $0.id == evidence.chunkID }?.text ?? ""
                    let check = QuoteVerifier.verify(claimText: claim.text, speaker: item.speaker, chunk: chunk)
                    claim.quotedPerson = check.person
                    claim.isParaphrase = !check.verbatimAllowed
                }
                claims.append(claim)
            }
        }
        var notes: [String] = []
        if rejected > 0 {
            notes.append(String(localized: "\(source.publisher): \(rejected) Aussagen verworfen (Zitat nicht im Text gefunden)"))
        }
        return (claims, notes)
    }

    /// Finds the quote in the named chunk, else in any chunk of the source.
    private func locate(_ item: ExtractedClaimOutput, in source: SourceDocument) -> Evidence? {
        let named = source.chunks.first { $0.id.caseInsensitiveCompare(item.chunkID.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))) == .orderedSame }
        let ordered = (named.map { [$0] } ?? []) + source.chunks.filter { $0.id != named?.id }
        var approximate: Evidence?
        for chunk in ordered {
            switch EvidenceMatcher.match(quote: item.quote, in: chunk.text) {
            case .exact: return Evidence(sourceID: source.id, chunkID: chunk.id, quote: item.quote, match: .exact)
            case .approximate where approximate == nil:
                approximate = Evidence(sourceID: source.id, chunkID: chunk.id, quote: item.quote, match: .approximate)
            default: continue
            }
        }
        return approximate
    }

    // MARK: Verify

    private func verify(_ dossier: inout ResearchDossier, folder: URL, progress: @escaping PipelineProgress) async throws {
        let toVerify = dossier.claims.filter { $0.type.needsEvidence && ($0.numberCheck?.passed ?? true) && $0.verdict == nil }
        guard !toVerify.isEmpty else { return }
        let batchSize = await router.inputBudget(for: .verifier) < 10_000 ? 3 : 12
        let batches = stride(from: 0, to: toVerify.count, by: batchSize).map { Array(toVerify[$0..<min($0 + batchSize, toVerify.count)]) }
        var failedBatches = 0

        for (index, batch) in batches.enumerated() {
            try Task.checkCancellation()
            let verifierName = await router.activeClient(for: .verifier).map { FactCheckReport.modelName($0.id) } ?? "–"
            await progress(PipelineEvent(stage: .verify, fraction: Double(index) / Double(batches.count),
                                         message: String(localized: "\(verifierName) prüft \(batch.count) Aussagen …")))
            let items = batch.map { claim in
                let quotes = claim.evidence.map { "- „\($0.quote)“" }.joined(separator: "\n")
                return "ID: \(claim.id)\nAussage: \(claim.text)\nBelegstellen:\n\(quotes)"
            }.joined(separator: "\n\n")
            let prompt = try PromptLibrary.load("verify", values: ["items": items])
            do {
                let result = try await router.generate(VerificationOutput.self, role: .verifier, task: "verify",
                                                       system: prompt.system, prompt: prompt.user, reasoning: true)
                for item in result.value.results {
                    let id = item.claimID.trimmingCharacters(in: .whitespaces).uppercased()
                    guard let claimIndex = dossier.claims.firstIndex(where: { $0.id == id }),
                          let verdict = Verdict(rawValue: item.verdict) else { continue }
                    dossier.claims[claimIndex].verdict = verdict
                    dossier.claims[claimIndex].verdictReason = item.reason
                    dossier.claims[claimIndex].verifierModel = result.model
                }
                try? ArtifactStore.save(dossier, as: "dossier.json", in: folder)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedBatches += 1
            }
        }
        if failedBatches > 0 {
            dossier.notes.append(String(localized: "\(failedBatches) Prüf-Durchläufe fehlgeschlagen – betroffene Aussagen höchstens gelb."))
        }
    }

    // MARK: - Script (stages 8–10, after review)

    func writeScript(_ input: ResearchDossier, personas: [Persona], folder: URL, progress: @escaping PipelineProgress) async throws -> (EpisodeScript, ResearchDossier) {
        let usable = input.usableClaims
        guard !usable.isEmpty else { throw PipelineError.noClaims }
        let isSmallModel = await router.inputBudget(for: .writer) < 10_000
        if !isSmallModel {
            do {
                return try await writeNarrativeScript(input, personas: personas, folder: folder, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                var fallback = input
                fallback.notes.append(String(localized: "Erzähl-Skript fehlgeschlagen (\(error.localizedDescription)) – Skript kapitelweise geschrieben."))
                return try await writeScriptSectionwise(fallback, personas: personas, folder: folder, progress: progress)
            }
        }
        return try await writeScriptSectionwise(input, personas: personas, folder: folder, progress: progress)
    }

    /// Previous approach (chapter by chapter), used for small models (Apple Intelligence) and as fallback.
    func writeScriptSectionwise(_ input: ResearchDossier, personas: [Persona], folder: URL, progress: @escaping PipelineProgress) async throws -> (EpisodeScript, ResearchDossier) {
        var dossier = input
        let options = dossier.options
        let usable = dossier.usableClaims
        guard !usable.isEmpty else { throw PipelineError.noClaims }
        let speakers = options.speakerIDs.compactMap { id in personas.first { $0.id == id } }
        let cast = speakers.isEmpty ? Array(personas.prefix(2)) : speakers
        let isSmallModel = await router.inputBudget(for: .writer) < 10_000

        // Outline
        await progress(PipelineEvent(stage: .outline, fraction: nil, message: String(localized: "\(usable.count) verwendbare Aussagen")))
        let claimList = usable.prefix(isSmallModel ? 18 : 80).map(Self.claimLine).joined(separator: "\n")
        let outlinePrompt = try PromptLibrary.load("outline", values: [
            "language": options.language.promptName,
            "minutes": String(options.minutes),
            "section_count": String(options.sectionCount),
            "nerd_instruction": options.nerdInstruction,
            "digression_instruction": options.digressionInstruction,
            "style_instruction": options.style.instruction,
            "category_instruction": options.categoryMix.instruction,
            "topic": options.topic,
            "claims": claimList,
        ])
        let usableIDs = Set(usable.map(\.id))
        var outline = try await router.generate(OutlineOutput.self, role: .writer, task: "outline",
                                                system: outlinePrompt.system, prompt: outlinePrompt.user).value
        outline.sections = outline.sections.map { section in
            var copy = section
            copy.claimIDs = section.claimIDs.map { $0.uppercased() }.filter(usableIDs.contains)
            return copy
        }
        if outline.sections.isEmpty {
            outline.sections = [OutlineSectionOutput(title: options.topic, goal: options.topic, claimIDs: usable.map(\.id))]
        }
        try? ArtifactStore.save(OutlineArtifact(outline), as: "outline.json", in: folder)

        // Script, section by section.
        let middleCount = max(1, outline.sections.count - 2)
        let unit = Double(options.targetWords) / (Double(middleCount) + 1.0) // intro + outro share one unit
        var segments: [ScriptSegmentDraft] = []
        var mentioned = Set<String>()
        var failedSections: [String] = []
        /// Extra requests allowed for length corrections (free quota is limited).
        var lengthAdjustmentsLeft = max(2, outline.sections.count / 3)

        for (index, section) in outline.sections.enumerated() {
            try Task.checkCancellation()
            await progress(PipelineEvent(stage: .script, fraction: Double(index) / Double(outline.sections.count),
                                         message: String(localized: "Kapitel \(index + 1) von \(outline.sections.count): \(section.title)")))
            let isFirst = index == 0
            let isLast = index == outline.sections.count - 1 && outline.sections.count > 1
            let words = Int((isFirst || isLast) ? unit / 2 : unit)
            let sectionClaims = section.claimIDs.compactMap { id in usable.first { $0.id == id } }
            let otherPool = isLast ? usable.filter { mentioned.contains($0.id) } : usable.filter { !section.claimIDs.contains($0.id) && !mentioned.contains($0.id) }
            var otherLimit = isSmallModel ? 3 : 12
            func generate(lengthNote: String) async throws -> [ScriptSegmentDraft] {
            var drafts: [ScriptSegmentDraft]?
            while drafts == nil {
                let prompt = try PromptLibrary.load("script_section", values: [
                    "language": options.language.promptName,
                    "personas": cast.map { "- \($0.id): \($0.name), \($0.role) – \($0.style)" }.joined(separator: "\n"),
                    "nerd_instruction": options.nerdInstruction,
                    "digression_instruction": options.digressionInstruction,
                    "style_instruction": options.style.instruction,
                    "category_instruction": options.categoryMix.instruction,
                    "speech_instruction": options.speechInstruction,
                    "target_words": String(max(60, words)),
                    "max_words": String(max(80, Int(Double(words) * 1.25))),
                    "section_hint": Self.sectionHint(isFirst: isFirst, isLast: isLast, monologue: cast.count == 1)
                        + "\n- Stil laut Leitfaden:\n" + StyleGuideStore.short(styleGuide, limit: isSmallModel ? 900 : 1_800)
                        + lengthNote
                        + (options.followUpOf.map { "\n- Dies ist eine Nachfrage zur Folge „\($0)“. Beantworte die Frage direkt. Geben die Aussagen keine Antwort her, sagt das offen – nicht raten." } ?? ""),
                    "topic": options.topic,
                    "section_title": section.title,
                    "section_goal": section.goal,
                    "previous": segments.suffix(3).isEmpty ? "" : "Bisher zuletzt gesagt:\n" + segments.suffix(3).map { segment in
                        "\(cast.first { $0.id == segment.speakerID }?.name ?? segment.speakerID): \(segment.text)"
                    }.joined(separator: "\n"),
                    "claims": sectionClaims.isEmpty ? "(keine – nur Überleitung, Fragen, Meinungen)" : sectionClaims.map(Self.claimLine).joined(separator: "\n"),
                    "other_claims": otherPool.prefix(otherLimit).map(Self.claimLine).joined(separator: "\n"),
                ])
                do {
                    let output = try await router.generate(ScriptSectionOutput.self, role: .writer, task: "script \(index + 1)",
                                                           system: prompt.system, prompt: prompt.user).value
                    drafts = output.segments.map { segment in
                        ScriptSegmentDraft(speakerID: Self.resolveSpeaker(segment.speaker, cast: cast),
                                           text: Self.stripSpeakerPrefix(segment.text, cast: cast), section: section.title,
                                           claimIDs: segment.claimIDs)
                    }
                } catch LLMError.contextTooSmall where otherLimit > 0 {
                    otherLimit = 0
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failedSections.append(section.title)
                    drafts = []
                }
            }
            return drafts ?? []
            }

            var drafts = try await generate(lengthNote: "")
            // Length control: one retry if the section misses its word budget by more than 30 %.
            let draftWords = Self.wordCount(drafts)
            if !drafts.isEmpty, lengthAdjustmentsLeft > 0, let note = Self.lengthCorrection(actual: draftWords, target: words) {
                lengthAdjustmentsLeft -= 1
                await progress(PipelineEvent(stage: .script, fraction: Double(index) / Double(outline.sections.count),
                                             message: String(localized: "\(section.title): Länge nachjustieren (\(draftWords) statt ~\(words) Wörter)")))
                let retry = try await generate(lengthNote: note)
                if !retry.isEmpty, abs(Self.wordCount(retry) - words) < abs(draftWords - words) {
                    drafts = retry
                }
            }
            guard !drafts.isEmpty else { continue }

            // Check and rewrite (max. 2 rounds), then drop what still fails.
            await progress(PipelineEvent(stage: .check, fraction: (Double(index) + 0.7) / Double(outline.sections.count),
                                         message: String(localized: "Kapitel \(index + 1) von \(outline.sections.count) prüfen: \(section.title)")))
            let allowed = sectionClaims + otherPool.prefix(otherLimit)
            let checked = try await checkAndRewrite(drafts, allowed: allowed, usable: usable, options: options, cast: cast, dossier: &dossier)
            for segment in checked { mentioned.formUnion(segment.claimIDs) }
            segments += checked
        }
        if !failedSections.isEmpty {
            dossier.notes.append(String(localized: "Kapitel ohne Skript (Modellfehler): \(failedSections.joined(separator: ", "))"))
        }
        guard !segments.isEmpty else { throw PipelineError.noScript }

        let script = EpisodeScript(title: outline.title.isEmpty ? options.topic : outline.title, summary: outline.summary, segments: segments)
        let expectedMinutes = Double(Self.wordCount(segments)) / Double(options.language.wordsPerMinute)
        dossier.notes.append(String(localized: "Skript: \(Self.wordCount(segments)) Wörter ≈ \(Int(expectedMinutes.rounded())) min (Ziel ~\(options.minutes) min)."))
        dossier.calls += await router.calls
        try ArtifactStore.save(script, as: "script.json", in: folder)
        try ArtifactStore.save(dossier, as: "dossier.json", in: folder)
        try FactCheckReport.markdown(dossier, title: script.title)
            .write(to: folder.appending(path: "factcheck.md"), atomically: true, encoding: .utf8)
        try ArtifactStore.save(FactCheckExport(dossier, title: script.title), as: "factcheck.json", in: folder)
        await progress(PipelineEvent(stage: .check, fraction: 1, message: String(localized: "\(segments.count) Segmente")))
        return (script, dossier)
    }

    // MARK: Narrative script (ADR-012)

    func writeNarrativeScript(_ input: ResearchDossier, personas: [Persona], folder: URL, progress: @escaping PipelineProgress) async throws -> (EpisodeScript, ResearchDossier) {
        var dossier = input
        let options = dossier.options
        let usable = dossier.usableClaims
        let byID = Dictionary(uniqueKeysWithValues: usable.map { ($0.id, $0) })
        let speakers = options.speakerIDs.compactMap { id in personas.first { $0.id == id } }
        let cast = speakers.isEmpty ? Array(personas.prefix(2)) : speakers
        let format = DialogFormat.choose(for: options)
        let formatText = format.instruction(cast: cast)
        let personaText = cast.map { "- \($0.id): \($0.name), \($0.role) – \($0.style)" }.joined(separator: "\n")
        let line = { (claim: Claim) in Self.claimLine(claim, sources: dossier.sources) }

        // 1. Narrative plan
        await progress(PipelineEvent(stage: .outline, fraction: 0.02, message: String(localized: "Erzählplan (\(format.label)) …")))
        let planPrompt = try PromptLibrary.load("narrative_plan", values: [
            "language": options.language.promptName, "minutes": String(options.minutes),
            "guide": styleGuide, "section_count": String(options.sectionCount), "format_instruction": formatText,
            "nerd_instruction": options.nerdInstruction, "digression_instruction": options.digressionInstruction,
            "style_instruction": options.style.instruction, "category_instruction": options.categoryMix.instruction,
            "topic": options.topic, "claims": usable.map(line).joined(separator: "\n"),
        ])
        var plan = try await router.generate(NarrativePlanOutput.self, role: .writer, task: "narrative plan",
                                             system: planPrompt.system, prompt: planPrompt.user).value
        plan.sections = Self.assignUniqueClaims(plan.sections, usable: Set(byID.keys))
        guard !plan.sections.isEmpty else { throw PipelineError.noScript }
        try? ArtifactStore.save(plan, as: "narrative.json", in: folder)
        let planText = Self.planText(plan)
        await progress(PipelineEvent(stage: .outline, fraction: 0.1, message: plan.guidingQuestion))

        // 2. Script in as few calls as possible (whole episode, or batches of ~2,500 words).
        let batches = Self.sectionBatches(plan.sections.count, targetWords: options.targetWords)
        var segments: [ScriptSegmentDraft] = []
        let sectionTitles = plan.sections.map(\.title)
        for (batchIndex, batch) in batches.enumerated() {
            try Task.checkCancellation()
            await progress(PipelineEvent(stage: .script, fraction: 0.1 + 0.45 * Double(batchIndex) / Double(batches.count),
                                         message: batches.count == 1 ? String(localized: "Skript am Stück …")
                                             : String(localized: "Skript Teil \(batchIndex + 1) von \(batches.count) …")))
            let sections = batch.map { plan.sections[$0] }
            let sectionIDs = Set(sections.flatMap(\.claimIDs))
            let used = Set(segments.flatMap(\.claimIDs))
            let spare = usable.filter { !sectionIDs.contains($0.id) && !used.contains($0.id) }.prefix(15)
            let words = Int(Double(options.targetWords) * Double(batch.count) / Double(plan.sections.count))
            let prompt = try PromptLibrary.load("script_full", values: [
                "language": options.language.promptName, "guide": styleGuide, "personas": personaText,
                "format_instruction": formatText, "target_words": String(words), "max_words": String(Int(Double(words) * 1.2)),
                "speech_instruction": options.speechInstruction,
                "extra": options.followUpOf.map { "- Dies ist eine Nachfrage zur Folge „\($0)“. Beantworte die Frage direkt; geben die Aussagen keine Antwort her, sagt das offen." } ?? "",
                "topic": options.topic, "plan": planText,
                "previous": segments.isEmpty ? "" : "Bisher geschrieben (Ende, zum nahtlosen Weiterschreiben):\n" + ScriptQuality.listing(Array(segments.suffix(10)), cast: cast, withIDs: false) + "\n",
                "sections": sections.map { "„\($0.title)“" }.joined(separator: ", "),
                "claims": (sections.flatMap { $0.claimIDs.compactMap { byID[$0] } } + spare).map(line).joined(separator: "\n"),
            ])
            let output = try await router.generate(FullScriptOutput.self, role: .writer, task: "script \(batchIndex + 1)",
                                                   system: prompt.system, prompt: prompt.user).value
            segments += output.segments.map { segment in
                ScriptSegmentDraft(speakerID: Self.resolveSpeaker(segment.speaker, cast: cast),
                                   text: Self.stripSpeakerPrefix(segment.text, cast: cast),
                                   section: Self.matchSection(segment.section, titles: sections.map(\.title), fallback: sections[0].title),
                                   claimIDs: segment.claimIDs.map { $0.uppercased() })
            }.filter { !$0.text.isEmpty }
        }
        guard !segments.isEmpty else { throw PipelineError.noScript }

        // 3. Quality: measurement + test listener, then one revision if needed.
        var report = ScriptQuality.measure(segments, format: format, cast: cast, wordsPerMinute: options.language.wordsPerMinute)
        await progress(PipelineEvent(stage: .check, fraction: 0.6, message: String(localized: "Testhörer bewertet das Skript …")))
        if let review = try? await reviewScript(segments, report: report, cast: cast) {
            report.clarity = review.clarity
            report.structure = review.structure
            report.naturalness = review.naturalness
            report.verdict = review.verdict
            report.reviewIssues = review.issues.map { $0.segment >= 0 ? "Beitrag \($0.segment): \($0.problem)" : $0.problem }
        }
        let lengthRatio = Double(report.words) / Double(max(1, options.targetWords))
        var lengthNote: String?
        if lengthRatio < 0.75 { lengthNote = "Das Skript ist zu kurz (\(report.words) statt ~\(options.targetWords) Wörter): Erklärungen ausbauen, mehr Rückfragen und Bilder – keine neuen Fakten." }
        if lengthRatio > 1.3 { lengthNote = "Das Skript ist zu lang (\(report.words) statt ~\(options.targetWords) Wörter): straffen." }
        if ScriptQuality.needsRevision(report) || lengthNote != nil {
            var revised: [ScriptSegmentDraft] = []
            for (batchIndex, batch) in batches.enumerated() {
                try Task.checkCancellation()
                await progress(PipelineEvent(stage: .check, fraction: 0.65 + 0.2 * Double(batchIndex) / Double(batches.count),
                                             message: String(localized: "Überarbeitung Teil \(batchIndex + 1) von \(batches.count) …")))
                let titles = Set(batch.map { sectionTitles[$0] })
                let part = segments.filter { titles.contains($0.section) }
                guard !part.isEmpty else { continue }
                let offset = segments.firstIndex { titles.contains($0.section) } ?? 0
                let partIssues = (report.problems + [lengthNote].compactMap { $0 } + report.reviewIssues.filter { issue in
                    guard let number = Int(issue.split(separator: ":").first?.replacingOccurrences(of: "Beitrag ", with: "") ?? "") else { return true }
                    return (offset..<(offset + part.count)).contains(number)
                })
                if let rewritten = try? await revise(part, offset: offset, issues: partIssues, usable: usable, sources: dossier.sources,
                                                    cast: cast, format: formatText, options: options,
                                                    targetWords: Int(Double(options.targetWords) * Double(batch.count) / Double(plan.sections.count))),
                   !rewritten.isEmpty {
                    revised += rewritten.map { segment in
                        var copy = segment
                        copy.section = Self.matchSection(segment.section, titles: Array(titles), fallback: part[0].section)
                        return copy
                    }
                } else {
                    revised += part
                }
            }
            let after = ScriptQuality.measure(revised, format: format, cast: cast, wordsPerMinute: options.language.wordsPerMinute)
            // Keep the revision unless it made things clearly worse or lost much content.
            if after.problems.count <= report.problems.count + 1, Double(after.words) >= Double(report.words) * 0.7 {
                segments = Self.orderBySections(revised, titles: sectionTitles)
                let review = (report.clarity, report.structure, report.naturalness, report.verdict, report.reviewIssues)
                report = after
                (report.clarity, report.structure, report.naturalness, report.verdict, report.reviewIssues) = review
                report.revised = true
            }
        }

        // 4. Fact check (deterministic) with targeted rewrites.
        await progress(PipelineEvent(stage: .check, fraction: 0.88, message: String(localized: "Faktenprüfung des Skripts …")))
        let checked = try await checkAndRewrite(segments, allowed: usable, usable: usable, options: options, cast: cast, dossier: &dossier)
        guard !checked.isEmpty else { throw PipelineError.noScript }
        let final = ScriptQuality.measure(checked, format: format, cast: cast, wordsPerMinute: options.language.wordsPerMinute)
        var quality = final
        (quality.clarity, quality.structure, quality.naturalness, quality.verdict, quality.reviewIssues, quality.revised) =
            (report.clarity, report.structure, report.naturalness, report.verdict, report.reviewIssues, report.revised)
        dossier.scriptQuality = quality

        let script = EpisodeScript(title: plan.title.isEmpty ? options.topic : plan.title, summary: plan.summary, segments: checked)
        dossier.notes.append(String(localized: "Skript (\(format.label)): \(final.words) Wörter ≈ \(Int(final.estimatedMinutes.rounded())) min (Ziel ~\(options.minutes) min). \(quality.summary)"))
        dossier.calls += await router.calls
        try ArtifactStore.save(script, as: "script.json", in: folder)
        try ArtifactStore.save(dossier, as: "dossier.json", in: folder)
        try FactCheckReport.markdown(dossier, title: script.title)
            .write(to: folder.appending(path: "factcheck.md"), atomically: true, encoding: .utf8)
        try ArtifactStore.save(FactCheckExport(dossier, title: script.title), as: "factcheck.json", in: folder)
        await progress(PipelineEvent(stage: .check, fraction: 1, message: String(localized: "\(checked.count) Beiträge · \(quality.summary)")))
        return (script, dossier)
    }

    private func reviewScript(_ segments: [ScriptSegmentDraft], report: ScriptQualityReport, cast: [Persona]) async throws -> ScriptReviewOutput {
        let prompt = try PromptLibrary.load("script_review", values: [
            "guide": styleGuide,
            "metrics": ([report.summary] + report.problems).joined(separator: "\n"),
            "script": ScriptQuality.listing(segments, cast: cast, withIDs: false),
        ])
        // The verifier chain is an independent second model – a good "test listener".
        return try await router.generate(ScriptReviewOutput.self, role: .verifier, task: "review",
                                         system: prompt.system, prompt: prompt.user).value
    }

    private func revise(_ part: [ScriptSegmentDraft], offset: Int, issues: [String], usable: [Claim], sources: [SourceDocument],
                        cast: [Persona], format: String, options: EpisodeOptions, targetWords: Int) async throws -> [ScriptSegmentDraft] {
        let cited = Set(part.flatMap(\.claimIDs))
        let prompt = try PromptLibrary.load("script_revise", values: [
            "language": options.language.promptName, "guide": styleGuide,
            "personas": cast.map { "\($0.id) = \($0.name)" }.joined(separator: ", "),
            "format_instruction": format, "target_words": String(targetWords),
            "issues": issues.isEmpty ? "Allgemein natürlicher und verständlicher machen." : issues.map { "- " + $0 }.joined(separator: "\n"),
            "claims": usable.filter { cited.contains($0.id) }.map { Self.claimLine($0, sources: sources) }.joined(separator: "\n"),
            "script": ScriptQuality.listing(part, cast: cast, withIDs: true, offset: offset),
        ])
        let output = try await router.generate(FullScriptOutput.self, role: .writer, task: "revise",
                                               system: prompt.system, prompt: prompt.user).value
        return output.segments.map { segment in
            ScriptSegmentDraft(speakerID: Self.resolveSpeaker(segment.speaker, cast: cast),
                               text: Self.stripSpeakerPrefix(segment.text, cast: cast), section: segment.section,
                               // Revision must not introduce claims that were not in this part.
                               claimIDs: segment.claimIDs.map { $0.uppercased() }.filter(cited.contains))
        }.filter { !$0.text.isEmpty }
    }

    /// Each claim in at most one section; unknown IDs dropped.
    static func assignUniqueClaims(_ sections: [NarrativeSectionOutput], usable: Set<String>) -> [NarrativeSectionOutput] {
        var seen = Set<String>()
        return sections.map { section in
            var copy = section
            copy.claimIDs = section.claimIDs.map { $0.uppercased() }.filter { usable.contains($0) && seen.insert($0).inserted }
            return copy
        }
    }

    /// Groups section indices so that each script call writes about ≤ 2,500 words.
    static func sectionBatches(_ count: Int, targetWords: Int, wordsPerCall: Int = 2_500) -> [[Int]] {
        guard count > 0 else { return [] }
        let calls = max(1, Int((Double(targetWords) / Double(wordsPerCall)).rounded(.up)))
        let size = max(1, Int((Double(count) / Double(calls)).rounded(.up)))
        return stride(from: 0, to: count, by: size).map { Array($0..<min($0 + size, count)) }
    }

    static func matchSection(_ raw: String, titles: [String], fallback: String) -> String {
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: " „“\"")).lowercased()
        return titles.first { $0.lowercased() == value }
            ?? titles.first { value.contains($0.lowercased()) || $0.lowercased().contains(value) && !value.isEmpty }
            ?? fallback
    }

    /// Keeps the planned chapter order (stable within a chapter).
    static func orderBySections(_ segments: [ScriptSegmentDraft], titles: [String]) -> [ScriptSegmentDraft] {
        let rank = Dictionary(uniqueKeysWithValues: titles.enumerated().map { ($1, $0) })
        return segments.enumerated().sorted { lhs, rhs in
            let l = rank[lhs.element.section] ?? Int.max, r = rank[rhs.element.section] ?? Int.max
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func planText(_ plan: NarrativePlanOutput) -> String {
        var lines = ["Titel: \(plan.title)", "Aufhänger: \(plan.hook)", "Leitfrage: \(plan.guidingQuestion)",
                     "Kernerkenntnisse: " + plan.keyInsights.joined(separator: " → ")]
        for (index, section) in plan.sections.enumerated() {
            lines.append("Kapitel \(index + 1) „\(section.title)“: Ziel: \(section.goal) | Erklärkette: \(section.explanation)"
                + (section.analogy.isEmpty ? "" : " | Bild: \(section.analogy)")
                + (section.transition.isEmpty ? "" : " | Wegweiser: \(section.transition)")
                + " | Aussagen: \(section.claimIDs.joined(separator: ", "))")
        }
        lines.append("Schluss/Rückgriff: \(plan.callback)")
        return lines.joined(separator: "\n")
    }

    /// Concrete origin of a claim for the script ("Fachartikel in FEBS Journal, 2007").
    static func sourceDescription(_ source: SourceDocument) -> String {
        let year = source.publishedAt.map { ", \(Calendar.current.component(.year, from: $0))" } ?? ""
        let shortTitle = source.title.components(separatedBy: " – ").first ?? source.title
        switch source.kind {
        case .wikipedia: return "Lexikon Wikipedia („\(shortTitle)“)"
        case .wikivoyage: return "Reiseführer Wikivoyage"
        case .paper:
            let kind = source.notes.contains { $0.contains("Übersichtsarbeit") } ? "Übersichtsarbeit" : (source.notes.contains { $0.contains("Preprint") } ? "noch nicht begutachtete Studie" : "Fachstudie")
            return "\(kind) in \(source.publisher)\(year)"
        case .gutenberg, .openLibrary: return "Buch „\(shortTitle)“\(year)"
        case .podcast: return "Podcast „\(source.publisher)“"
        case .custom: return "eigene Quelle „\(shortTitle)“"
        case .web: return "Artikel auf \(source.publisher)\(year)"
        }
    }

    static func claimLine(_ claim: Claim, sources: [SourceDocument]) -> String {
        let origins = claim.sourceIDs.compactMap { id in sources.first { $0.id == id } }.map(sourceDescription)
        let origin = origins.isEmpty ? "" : " — Herkunft: " + Array(NSOrderedSet(array: origins)).compactMap { $0 as? String }.prefix(2).joined(separator: "; ")
        return claimLine(claim) + origin
    }

    struct OutlineArtifact: Codable {
        struct Section: Codable { let title, goal: String; let claimIDs: [String] }
        let title, summary: String
        let sections: [Section]
        init(_ outline: OutlineOutput) {
            title = outline.title
            summary = outline.summary
            sections = outline.sections.map { Section(title: $0.title, goal: $0.goal, claimIDs: $0.claimIDs) }
        }
    }

    private func checkAndRewrite(_ drafts: [ScriptSegmentDraft], allowed: [Claim], usable: [Claim], options: EpisodeOptions,
                                 cast: [Persona], dossier: inout ResearchDossier) async throws -> [ScriptSegmentDraft] {
        var (segments, issues) = ScriptChecker.check(drafts, usable: usable)
        var round = 0
        while !issues.isEmpty, round < 2 {
            round += 1
            let flagged = issues.map { issue in
                let segment = segments[issue.index]
                return "[\(issue.index)] \(segment.speakerID): \(segment.text)\n   Problem: \(issue.problem)"
            }.joined(separator: "\n")
            let citedIDs = Set(issues.flatMap { segments[$0.index].claimIDs })
            let claimPool = (allowed + usable.filter { citedIDs.contains($0.id) })
            let unique = Array(Dictionary(claimPool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values).sorted { $0.id < $1.id }
            let prompt = try PromptLibrary.load("rewrite_segments", values: [
                "language": options.language.promptName,
                "claims": unique.map(Self.claimLine).joined(separator: "\n"),
                "segments": flagged,
            ])
            guard let output = try? await router.generate(ScriptSectionOutput.self, role: .writer, task: "rewrite",
                                                          system: prompt.system, prompt: prompt.user).value else { break }
            for (issue, rewritten) in zip(issues, output.segments) {
                segments[issue.index].text = Self.stripSpeakerPrefix(rewritten.text, cast: cast)
                segments[issue.index].claimIDs = rewritten.claimIDs
            }
            (segments, issues) = ScriptChecker.check(segments, usable: usable)
        }
        let dropped = Set(issues.map(\.index))
        for issue in issues {
            dossier.scriptIssues.append("„\(segments[issue.index].text)“ – \(issue.problem)")
        }
        return segments.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }

    /// Rewrites one segment from the script editor (closed book). `instruction` is the user's
    /// wish or the checker's problem list. Returns the checked result.
    func rewriteSegment(_ draft: ScriptSegmentDraft, instruction: String, dossier: ResearchDossier,
                        personas: [Persona]) async throws -> ScriptSegmentDraft {
        let usable = dossier.usableClaims
        let cited = Set(draft.claimIDs)
        // Cited claims first, then the rest (bounded for small models).
        let limit = await router.inputBudget(for: .writer) < 10_000 ? 12 : 60
        let pool = usable.filter { cited.contains($0.id) } + usable.filter { !cited.contains($0.id) }
        let speakerName = personas.first { $0.id == draft.speakerID }?.name ?? draft.speakerID
        let prompt = try PromptLibrary.load("rewrite_segments", values: [
            "language": dossier.options.language.promptName,
            "claims": pool.prefix(limit).map(Self.claimLine).joined(separator: "\n"),
            "segments": "[0] \(speakerName): \(draft.text)\n   Problem: \(instruction)",
        ])
        let output = try await router.generate(ScriptSectionOutput.self, role: .writer, task: "rewrite segment",
                                               system: prompt.system, prompt: prompt.user)
        guard let first = output.value.segments.first else { throw PipelineError.noScript }
        var result = draft
        result.text = Self.stripSpeakerPrefix(first.text, cast: personas)
        result.claimIDs = first.claimIDs.map { $0.uppercased() }.filter { id in usable.contains { $0.id == id } }
        return result
    }

    static func wordCount(_ segments: [ScriptSegmentDraft]) -> Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// Instruction for a retry if a section is more than 30 % off its word budget; nil if fine.
    static func lengthCorrection(actual: Int, target: Int) -> String? {
        guard target > 0 else { return nil }
        let ratio = Double(actual) / Double(target)
        if ratio < 0.7 {
            return "\n- WICHTIG Länge: Dein erster Entwurf hatte nur \(actual) Wörter, Ziel sind etwa \(target). Schreibe länger: erkläre die Aussagen ausführlicher, mehr Rückfragen und Beispiele aus den Aussagen – aber keine neuen Fakten und keine Wiederholungen."
        }
        if ratio > 1.3 {
            return "\n- WICHTIG Länge: Dein erster Entwurf hatte \(actual) Wörter, Ziel sind etwa \(target). Schreibe deutlich kürzer und straffer, lass weniger wichtige Aussagen weg."
        }
        return nil
    }

    static func claimLine(_ claim: Claim) -> String {
        let light = claim.effectiveLight == .green ? "GRÜN" : "GELB"
        if claim.type == .quote {
            let marker = claim.isParaphrase == true
                ? " [NUR PARAPHRASE – nicht wörtlich zitieren, keine Anführungszeichen]"
                : " [WÖRTLICHES ZITAT von \(claim.quotedPerson ?? "?") – genau so zitieren]"
            return "\(claim.id) [\(light)]\(marker) \(claim.text)"
        }
        let contested = claim.contestedWith.map { " [UMSTRITTEN, vgl. \($0.joined(separator: ", "))]" } ?? ""
        return "\(claim.id) [\(light)]\(contested) (\(claim.type.label)) \(claim.text)"
    }

    static func sectionHint(isFirst: Bool, isLast: Bool, monologue: Bool) -> String {
        var hints: [String] = []
        if monologue { hints.append("- Nur ein Sprecher: Erzähler-Monolog mit direkter Ansprache der Hörer.") }
        if isFirst { hints.append("- Einstieg: kurz begrüßen, das Thema vorstellen, Neugier wecken. Höchstens ein Fakt.") }
        if isLast { hints.append("- Abschluss: das Wichtigste in zwei, drei Beiträgen zusammenfassen (nur bereits genannte Fakten), eine persönliche Meinung pro Person, dann herzlich verabschieden. Keine neuen Fakten.") }
        return hints.joined(separator: "\n")
    }

    /// Models sometimes repeat the name inside the text ("Max: Genial.") – it would be spoken.
    static func stripSpeakerPrefix(_ text: String, cast: [Persona]) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for persona in cast {
            for name in Set([persona.name, persona.name.components(separatedBy: " ").last ?? persona.name, persona.id]) {
                if result.lowercased().hasPrefix(name.lowercased() + ":") {
                    result = String(result.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return result
    }

    static func resolveSpeaker(_ raw: String, cast: [Persona]) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return cast.first { $0.id == value }?.id
            ?? cast.first { $0.name.lowercased() == value }?.id
            ?? cast.first { value.contains($0.id) || $0.name.lowercased().contains(value) }?.id
            ?? cast.first?.id ?? "max"
    }
}

private extension SourceDocument {
    func withText(_ text: String) -> SourceDocument {
        var copy = self
        copy.chunks = TextChunker.chunk(text, sourceID: "TMP")
        return copy
    }

    func renumbered(_ newID: String) -> SourceDocument {
        var copy = SourceDocument(id: newID, kind: kind, title: title, publisher: publisher, url: url,
                                  publishedAt: publishedAt, language: language, tier: tier, chunks: [], notes: notes, included: included)
        copy.fetchMethod = fetchMethod
        copy.integrityWarning = integrityWarning
        copy.syndicationGroup = syndicationGroup
        copy.chunks = chunks.map { SourceChunk(id: $0.id.replacingOccurrences(of: "TMP", with: newID), text: $0.text, offset: $0.offset) }
        return copy
    }
}
