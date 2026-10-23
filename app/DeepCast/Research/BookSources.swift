import Foundation

/// Legal full-text books: Project Gutenberg (public domain) and Open Library / Internet Archive
/// (only `ebook_access == public`, i.e. freely readable scans). Books are large, so only the
/// chunks most relevant to the topic are kept.
struct BookSearch: Sendable {
    struct Book: Sendable, Hashable {
        enum Origin: String, Sendable { case gutenberg, openLibrary }
        let origin: Origin
        let id: String
        let title: String
        let author: String
        let year: Int?
        let textURL: URL
        let pageURL: URL
    }

    /// Chunks kept per book (≈ 13.000 words).
    static let maxChunks = 60
    static let maxDownloadBytes = 6_000_000

    // MARK: Project Gutenberg (official OPDS search)

    func searchGutenberg(_ query: String, limit: Int) async throws -> [Book] {
        var components = URLComponents(string: "https://www.gutenberg.org/ebooks/search.opds/")!
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        let (data, response) = try await HTTP.get(components.url!, timeout: 25)
        guard response.statusCode == 200, let xml = String(data: data, encoding: .utf8) else { return [] }
        return Array(Self.parseGutenberg(xml, query: query).prefix(limit))
    }

    /// Book entries only (IDs …/ebooks/<n>.opds); fuzzy hits without any query term in title/author are dropped.
    static func parseGutenberg(_ xml: String, query: String) -> [Book] {
        let terms = Set(TextChunker.terms(query).map { String($0.prefix(5)) })
        var books: [Book] = []
        for entry in xml.components(separatedBy: "<entry>").dropFirst() {
            guard let id = firstMatch(entry, #"<id>https?://www\.gutenberg\.org/ebooks/(\d+)\.opds</id>"#),
                  let title = firstMatch(entry, #"<title>([^<]+)</title>"#) else { continue }
            let author = firstMatch(entry, #"<content type="text">([^<]*)</content>"#) ?? ""
            let words = Set(TextChunker.terms(title + " " + author).map { String($0.prefix(5)) })
            guard terms.isEmpty || !words.isDisjoint(with: terms) else { continue }
            books.append(Book(origin: .gutenberg, id: id, title: HTMLTextExtractor.decodeEntities(title),
                              author: HTMLTextExtractor.decodeEntities(author), year: nil,
                              textURL: URL(string: "https://www.gutenberg.org/cache/epub/\(id)/pg\(id).txt")!,
                              pageURL: URL(string: "https://www.gutenberg.org/ebooks/\(id)")!))
        }
        return books
    }

    // MARK: Open Library (only public full texts)

    func searchOpenLibrary(_ query: String, language: EpisodeLanguage, limit: Int) async throws -> [Book] {
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        components.queryItems = [
            .init(name: "q", value: query), .init(name: "limit", value: "30"),
            .init(name: "fields", value: "key,title,author_name,first_publish_year,ia,ebook_access"),
        ]
        let (data, response) = try await HTTP.get(components.url!, timeout: 25)
        guard response.statusCode == 200 else { return [] }
        return Array(Self.parseOpenLibrary(data).prefix(limit))
    }

    static func parseOpenLibrary(_ data: Data) -> [Book] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = json["docs"] as? [[String: Any]] else { return [] }
        return docs.compactMap { doc in
            guard (doc["ebook_access"] as? String) == "public",
                  let ia = (doc["ia"] as? [String])?.first, !ia.isEmpty,
                  let title = doc["title"] as? String, let key = doc["key"] as? String else { return nil }
            return Book(origin: .openLibrary, id: ia, title: title,
                        author: (doc["author_name"] as? [String])?.first ?? "", year: doc["first_publish_year"] as? Int,
                        textURL: URL(string: "https://archive.org/download/\(ia)/\(ia)_djvu.txt")!,
                        pageURL: URL(string: "https://openlibrary.org\(key)")!)
        }
    }

    // MARK: Full text

    func document(for book: Book, keywords: [String]) async throws -> SourceDocument? {
        let (data, response) = try await HTTP.get(book.textURL, timeout: 60)
        guard response.statusCode == 200, data.count > 2_000 else { return nil }
        let raw = String(decoding: data.prefix(Self.maxDownloadBytes), as: UTF8.self)
        let text = book.origin == .gutenberg ? Self.stripGutenbergBoilerplate(raw) : Self.cleanScan(raw)
        let all = TextChunker.chunk(Self.paragraphs(text), sourceID: "TMP")
        let picked = TextChunker.selectRelevant(all, keywords: keywords, budgetChars: Int.max, maxChunks: Self.maxChunks)
        guard picked.count >= 2 else { return nil } // book does not really cover the topic
        let isGutenberg = book.origin == .gutenberg
        let date = book.year.flatMap { Calendar(identifier: .gregorian).date(from: DateComponents(year: $0, month: 7, day: 1)) }
        let kind: SourceKind = isGutenberg ? .gutenberg : .openLibrary
        return SourceDocument(
            id: "", kind: kind, title: book.author.isEmpty ? book.title : "\(book.title) – \(book.author)",
            publisher: isGutenberg ? "Project Gutenberg" : "Open Library / Internet Archive",
            url: book.pageURL, publishedAt: date, language: "en", tier: .b, chunks: picked,
            notes: [isGutenberg
                    ? String(localized: "Gemeinfreies Buch – oft alt: Stand der Forschung kann überholt sein")
                    : String(localized: "Frei lesbarer Buch-Scan (OCR, kann Lesefehler enthalten)")])
    }

    static func stripGutenbergBoilerplate(_ text: String) -> String {
        var body = text
        if let start = body.range(of: #"\*\*\* ?START OF (THE|THIS) PROJECT GUTENBERG EBOOK[^\n]*\n"#, options: [.regularExpression, .caseInsensitive]) {
            body = String(body[start.upperBound...])
        }
        if let end = body.range(of: #"\*\*\* ?END OF (THE|THIS) PROJECT GUTENBERG EBOOK"#, options: [.regularExpression, .caseInsensitive]) {
            body = String(body[..<end.lowerBound])
        }
        return body
    }

    /// OCR text: join hyphenated line breaks, drop lines that are page numbers or noise.
    static func cleanScan(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: "-\n", with: "")
        cleaned = cleaned.components(separatedBy: "\n")
            .filter { line in
                let letters = line.filter(\.isLetter).count
                return line.trimmingCharacters(in: .whitespaces).isEmpty || letters >= 3
            }
            .joined(separator: "\n")
        return cleaned
    }

    /// Hard-wrapped text → paragraphs (blank lines separate paragraphs).
    static func paragraphs(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.replacingOccurrences(of: #"\n[ \t]*\n"#, with: "\n\n", options: .regularExpression)
            .components(separatedBy: "\n\n")
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 40 }
            .joined(separator: "\n\n")
    }

    private static func firstMatch(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
