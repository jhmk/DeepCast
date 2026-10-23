import Foundation
import PDFKit

/// Scientific papers via OpenAlex (https://docs.openalex.org, free, no key; "polite pool" via
/// mailto). Covers journals, arXiv/bioRxiv preprints and repositories. Uses the abstract and,
/// where an open-access copy exists, the full text (HTML or PDF via PDFKit).
struct PaperSearch: Sendable {
    struct Work: Sendable, Hashable {
        let id: String
        let title: String
        let year: Int?
        let venue: String?
        let doi: URL?
        let landingPage: URL?
        let openAccessURL: URL?
        let abstract: String
        let citations: Int
        let isPreprint: Bool
        let isRetracted: Bool
        let isReview: Bool
        let language: String?
    }

    static let mailto = "deepcast-local@users.noreply.github.com"
    var fetcher = WebPageFetcher()

    func search(_ query: String, limit: Int, preferReviews: Bool) async throws -> [Work] {
        var components = URLComponents(string: "https://api.openalex.org/works")!
        components.queryItems = [
            .init(name: "search", value: query),
            .init(name: "per_page", value: String(max(limit * 3, 10))),
            .init(name: "filter", value: "has_abstract:true,is_retracted:false"),
            .init(name: "select", value: "id,display_name,publication_year,primary_location,doi,open_access,abstract_inverted_index,cited_by_count,type,is_retracted,language,best_oa_location"),
            .init(name: "mailto", value: Self.mailto),
        ]
        let (data, response) = try await HTTP.get(components.url!, timeout: 25)
        guard response.statusCode == 200 else { throw WebPageFetcher.FetchError.http(response.statusCode) }
        let works = try Self.parse(data)
        // Relevance from OpenAlex, nudged towards cited works and (for nerds) reviews.
        let ranked = works.enumerated().sorted { lhs, rhs in
            score(lhs.element, rank: lhs.offset, preferReviews: preferReviews) > score(rhs.element, rank: rhs.offset, preferReviews: preferReviews)
        }.map(\.element)
        return Array(ranked.prefix(limit))
    }

    private func score(_ work: Work, rank: Int, preferReviews: Bool) -> Double {
        var value = 10.0 / Double(rank + 1)
        value += log(Double(work.citations) + 1)
        if preferReviews, work.isReview { value += 3 }
        if work.openAccessURL != nil { value += 1 }
        if work.isPreprint { value -= 1 }
        return value
    }

    static func parse(_ data: Data) throws -> [Work] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { item in
            guard let title = item["display_name"] as? String, !title.isEmpty,
                  let inverted = item["abstract_inverted_index"] as? [String: [Int]] else { return nil }
            let abstract = rebuildAbstract(inverted)
            guard abstract.count > 200 else { return nil }
            let primary = item["primary_location"] as? [String: Any]
            let source = primary?["source"] as? [String: Any]
            let sourceType = (source?["type"] as? String) ?? ""
            let version = (primary?["version"] as? String) ?? ""
            let bestOA = item["best_oa_location"] as? [String: Any]
            let oaURL = (bestOA?["pdf_url"] as? String) ?? (bestOA?["landing_page_url"] as? String)
                ?? ((item["open_access"] as? [String: Any])?["oa_url"] as? String)
            let type = (item["type"] as? String) ?? ""
            return Work(
                id: (item["id"] as? String) ?? title,
                title: title,
                year: item["publication_year"] as? Int,
                venue: source?["display_name"] as? String,
                doi: (item["doi"] as? String).flatMap(URL.init(string:)),
                landingPage: (primary?["landing_page_url"] as? String).flatMap(URL.init(string:)),
                openAccessURL: oaURL.flatMap(URL.init(string:)),
                abstract: abstract,
                citations: item["cited_by_count"] as? Int ?? 0,
                isPreprint: type == "preprint" || sourceType == "repository" || version == "submittedVersion",
                isRetracted: item["is_retracted"] as? Bool ?? false,
                isReview: type == "review",
                language: item["language"] as? String
            )
        }.filter { !$0.isRetracted }
    }

    /// OpenAlex ships abstracts as {word: [positions]}.
    static func rebuildAbstract(_ inverted: [String: [Int]]) -> String {
        var words: [Int: String] = [:]
        for (word, positions) in inverted { for position in positions { words[position] = word } }
        return words.keys.sorted().compactMap { words[$0] }.joined(separator: " ")
    }

    /// Builds a source document: abstract always, full text if an open copy can be read.
    func document(for work: Work) async -> SourceDocument {
        var text = "Abstract\n\n" + work.abstract
        var notes: [String] = []
        if let url = work.openAccessURL, let fullText = await fullText(url), fullText.count > work.abstract.count * 2 {
            text += "\n\n" + fullText
            notes.append(String(localized: "Volltext (Open Access)"))
        } else {
            notes.append(String(localized: "Nur Abstract"))
        }
        if work.isPreprint { notes.append(String(localized: "Preprint (nicht begutachtet)")) }
        if work.isReview { notes.append(String(localized: "Übersichtsarbeit")) }
        notes.append("\(work.citations) Zitationen")
        let url = work.doi ?? work.landingPage ?? work.openAccessURL ?? URL(string: work.id)!
        let date = work.year.flatMap { Calendar(identifier: .gregorian).date(from: DateComponents(year: $0, month: 7, day: 1)) }
        var document = SourceDocument(
            id: "", kind: .paper, title: work.title,
            publisher: work.venue ?? (work.isPreprint ? "Preprint" : "Fachzeitschrift"),
            url: url, publishedAt: date, language: work.language ?? "en",
            tier: work.isPreprint ? .b : .a, chunks: [], notes: notes)
        document.chunks = TextChunker.chunk(text, sourceID: "TMP")
        return document
    }

    private func fullText(_ url: URL) async -> String? {
        if url.pathExtension.lowercased() == "pdf" || url.absoluteString.contains("/pdf") {
            guard let (data, response) = try? await HTTP.get(url, userAgent: HTTP.browserAgent, timeout: 30),
                  response.statusCode == 200, data.count < 25_000_000,
                  data.starts(with: Data("%PDF".utf8)),
                  let pdf = PDFDocument(data: data) else { return nil }
            return Self.cleanPDFText(pdf.string ?? "")
        }
        return try? await fetcher.fetch(url).extracted.text
    }

    /// PDF text has hard line breaks and hyphenation; rebuild paragraphs, drop references.
    static func cleanPDFText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "-\n", with: "")
        if let range = text.range(of: #"\n(References|REFERENCES|Literatur|Bibliography)\s*\n"#, options: .regularExpression) {
            text = String(text[..<range.lowerBound])
        }
        text = text.replacingOccurrences(of: #"\n\s*\n"#, with: "\u{2029}", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(of: "\u{2029}", with: "\n\n")
        return text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
