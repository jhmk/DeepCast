import Foundation

struct SearchHit: Sendable, Hashable {
    let url: URL
    let title: String
    let snippet: String
    let provider: String
    let rank: Int
}

protocol SearchProvider: Sendable {
    var name: String { get }
    func search(_ query: String, language: EpisodeLanguage, limit: Int) async throws -> [SearchHit]
}

enum HTTP {
    static let userAgent = "DeepCast/0.1 (personal research podcast app for macOS; contact: local user)"
    static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15"

    static func get(_ url: URL, userAgent: String = userAgent, timeout: TimeInterval = 20, session: URLSession = .shared) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("de-DE,de;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// DuckDuckGo HTML endpoint. Unofficial (no API): throttled, few requests, failures tolerated.
actor DuckDuckGoSearch: SearchProvider {
    nonisolated let name = "DuckDuckGo"
    private var lastRequest = Date.distantPast
    private let minimumInterval: TimeInterval = 1.5

    func search(_ query: String, language: EpisodeLanguage, limit: Int) async throws -> [SearchHit] {
        let wait = minimumInterval - Date().timeIntervalSince(lastRequest)
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        lastRequest = Date()

        var request = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "q", value: query),
                           URLQueryItem(name: "kl", value: language == .de ? "de-de" : "us-en")]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let html = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        return Array(Self.parse(html).prefix(limit))
    }

    static func parse(_ html: String) -> [SearchHit] {
        let pattern = #"<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)</a>(?:.*?class="result__snippet"[^>]*>(.*?)</a>)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        var hits: [SearchHit] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let rawHref = HTMLTextExtractor.decodeEntities(ns.substring(with: match.range(at: 1)))
            guard let url = resolve(rawHref) else { continue }
            let title = HTMLTextExtractor.clean(ns.substring(with: match.range(at: 2)))
            let snippet = match.range(at: 3).location != NSNotFound ? HTMLTextExtractor.clean(ns.substring(with: match.range(at: 3))) : ""
            hits.append(SearchHit(url: url, title: title, snippet: snippet, provider: "DuckDuckGo", rank: hits.count))
        }
        return hits
    }

    /// Handles direct links and DuckDuckGo redirect links (`//duckduckgo.com/l/?uddg=…`); drops ads.
    static func resolve(_ href: String) -> URL? {
        var string = href
        if string.hasPrefix("//") { string = "https:" + string }
        guard let url = URL(string: string), let host = url.host() else { return nil }
        if host.hasSuffix("duckduckgo.com") {
            guard url.path().hasPrefix("/l/"),
                  let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "uddg" })?.value,
                  let resolved = URL(string: target), resolved.host()?.hasSuffix("duckduckgo.com") == false
            else { return nil }
            return resolved
        }
        return url
    }
}

/// Wikipedia via the official MediaWiki API (no key).
struct WikipediaClient: Sendable {
    /// "wikipedia" or "wikivoyage" (same MediaWiki API).
    var site = "wikipedia"

    struct Page: Sendable {
        let title: String
        let url: URL
        let text: String
        let lastEdited: Date?
        let language: String
    }

    func search(_ query: String, language: String, limit: Int) async throws -> [String] {
        var components = URLComponents(string: "https://\(language).\(site).org/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"), .init(name: "list", value: "search"),
            .init(name: "srsearch", value: query), .init(name: "srlimit", value: String(limit)),
            .init(name: "format", value: "json"), .init(name: "formatversion", value: "2"),
        ]
        let (data, _) = try await HTTP.get(components.url!)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = (json?["query"] as? [String: Any])?["search"] as? [[String: Any]] ?? []
        return results.compactMap { $0["title"] as? String }
    }

    /// Full plain-text article (follows redirects). Returns nil for missing pages.
    func page(title: String, language: String) async throws -> Page? {
        var components = URLComponents(string: "https://\(language).\(site).org/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"), .init(name: "prop", value: "extracts|info|revisions"),
            .init(name: "rvprop", value: "timestamp"), .init(name: "inprop", value: "url"),
            .init(name: "explaintext", value: "1"), .init(name: "exsectionformat", value: "plain"),
            .init(name: "redirects", value: "1"), .init(name: "titles", value: title),
            .init(name: "format", value: "json"), .init(name: "formatversion", value: "2"),
        ]
        let (data, _) = try await HTTP.get(components.url!)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let page = ((json?["query"] as? [String: Any])?["pages"] as? [[String: Any]])?.first,
              page["missing"] == nil,
              let text = page["extract"] as? String, text.count > 500,
              let urlString = page["fullurl"] as? String, let url = URL(string: urlString)
        else { return nil }
        let timestamp = ((page["revisions"] as? [[String: Any]])?.first?["timestamp"] as? String).flatMap(HTMLTextExtractor.parseISODate)
        return Page(title: page["title"] as? String ?? title, url: url, text: Self.cleanExtract(text),
                    lastEdited: timestamp, language: language)
    }

    /// Removes reference/literature sections and normalises paragraph breaks.
    static func cleanExtract(_ text: String) -> String {
        var lines: [String] = []
        let cutoffs = ["Literatur", "Weblinks", "Einzelnachweise", "Anmerkungen", "Siehe auch",
                       "References", "External links", "Further reading", "See also", "Notes"]
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if cutoffs.contains(trimmed) { break }
            lines.append(trimmed)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{2,}"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?<!\n)\n(?!\n)"#, with: "\n\n", options: .regularExpression)
    }
}

/// Downloads a web page and extracts the main text.
struct WebPageFetcher: Sendable {
    struct Page: Sendable {
        let url: URL
        let extracted: HTMLTextExtractor.Result
    }

    enum FetchError: LocalizedError {
        case notHTML, tooShort, http(Int)
        var errorDescription: String? {
            switch self {
            case .notHTML: String(localized: "kein HTML")
            case .tooShort: String(localized: "zu wenig Text (Paywall oder Skript-Seite?)")
            case .http(let code): String(localized: "HTTP \(code)")
            }
        }
    }

    static let minimumTextLength = 800
    static let maximumBytes = 3_000_000

    func fetch(_ url: URL) async throws -> Page {
        let (data, response) = try await HTTP.get(url, userAgent: HTTP.browserAgent, timeout: 20)
        guard (200..<300).contains(response.statusCode) else { throw FetchError.http(response.statusCode) }
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "text/html"
        guard type.contains("html"), data.count <= Self.maximumBytes else { throw FetchError.notHTML }
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let extracted = HTMLTextExtractor.extract(html)
        guard extracted.text.count >= Self.minimumTextLength else { throw FetchError.tooShort }
        return Page(url: response.url ?? url, extracted: extracted)
    }
}
