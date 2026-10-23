import Foundation

/// Podcast episodes with transcripts:
/// 1. iTunes Search API (free, no key) finds episodes for the topic.
/// 2. Transcript from the publisher's RSS feed (`podcast:transcript`, Podcasting 2.0), or
/// 3. from the local Apple Podcasts cache, if the episode's transcript was opened in the
///    Podcasts app on this Mac (`transcript_<storeTrackID>.ttml`).
/// No audio is downloaded or transcribed.
struct PodcastSearch: Sendable {
    struct Episode: Sendable, Hashable {
        let trackID: Int
        let title: String
        let show: String
        let feedURL: URL?
        let guid: String?
        let pageURL: URL?
        let released: Date?
    }

    static let appleTranscriptCache = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Library/Cache/Assets/TTML")

    func search(_ query: String, language: EpisodeLanguage, limit: Int) async throws -> [Episode] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: query), .init(name: "media", value: "podcast"),
            .init(name: "entity", value: "podcastEpisode"), .init(name: "country", value: language == .de ? "de" : "us"),
            .init(name: "limit", value: String(limit)),
        ]
        let (data, response) = try await HTTP.get(components.url!, timeout: 20)
        guard response.statusCode == 200 else { throw WebPageFetcher.FetchError.http(response.statusCode) }
        return Self.parseSearch(data)
    }

    static func parseSearch(_ data: Data) -> [Episode] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { item in
            guard let id = item["trackId"] as? Int, let title = item["trackName"] as? String else { return nil }
            return Episode(
                trackID: id, title: title, show: item["collectionName"] as? String ?? "",
                feedURL: (item["feedUrl"] as? String).flatMap(URL.init(string:)),
                guid: item["episodeGuid"] as? String,
                pageURL: (item["trackViewUrl"] as? String).flatMap(URL.init(string:)),
                released: (item["releaseDate"] as? String).flatMap(HTMLTextExtractor.parseISODate)
            )
        }
    }

    /// Returns a transcript document, or nil if no transcript is available.
    func document(for episode: Episode) async -> SourceDocument? {
        var text: String?
        var origin = ""
        if let local = Self.localAppleTranscript(trackID: episode.trackID) {
            text = local
            origin = String(localized: "Transkript aus Apple Podcasts (lokal)")
        } else if let feed = episode.feedURL, let url = try? await transcriptURL(feed: feed, episode: episode),
                  let fetched = try? await fetchTranscript(url.url, type: url.type) {
            text = fetched
            origin = String(localized: "Transkript des Anbieters (RSS)")
        }
        guard let text, text.count > 1_000 else { return nil }
        var document = SourceDocument(
            id: "", kind: .podcast, title: "\(episode.title) – \(episode.show)", publisher: episode.show,
            url: episode.pageURL ?? episode.feedURL ?? URL(string: "https://podcasts.apple.com")!,
            publishedAt: episode.released, language: "de", tier: .c, chunks: [],
            notes: [origin, String(localized: "Gesprochene Sprache, automatisch transkribiert – kann Fehler enthalten")])
        document.chunks = TextChunker.chunk(Self.paragraphs(text), sourceID: "TMP")
        return document
    }

    // MARK: RSS

    func transcriptURL(feed: URL, episode: Episode) async throws -> (url: URL, type: String)? {
        let (data, response) = try await HTTP.get(feed, timeout: 25)
        guard response.statusCode == 200, data.count < 30_000_000, let xml = String(data: data, encoding: .utf8) else { return nil }
        return Self.findTranscript(in: xml, guid: episode.guid, title: episode.title)
    }

    /// Finds the matching <item> by guid (or title) and picks the best transcript format.
    static func findTranscript(in xml: String, guid: String?, title: String) -> (url: URL, type: String)? {
        let items = xml.components(separatedBy: "<item").dropFirst()
        let normalizedTitle = title.lowercased().trimmingCharacters(in: .whitespaces)
        let item = items.first { item in
            if let guid, !guid.isEmpty, item.contains(guid) { return true }
            return item.lowercased().contains(normalizedTitle) && !normalizedTitle.isEmpty
        }
        guard let item, let regex = try? NSRegularExpression(pattern: #"<podcast:transcript\b([^>]*)/?>"#) else { return nil }
        var found: [(url: URL, type: String)] = []
        let ns = item as NSString
        for match in regex.matches(in: item, range: NSRange(location: 0, length: ns.length)) {
            let attributes = ns.substring(with: match.range(at: 1))
            guard let urlString = attribute("url", in: attributes), let url = URL(string: HTMLTextExtractor.decodeEntities(urlString)) else { continue }
            found.append((url, attribute("type", in: attributes)?.lowercased() ?? ""))
        }
        let preference = ["text/plain", "application/json", "text/vtt", "application/x-subrip", "application/srt", "text/html"]
        return found.min { lhs, rhs in
            (preference.firstIndex { lhs.type.contains($0) } ?? 99) < (preference.firstIndex { rhs.type.contains($0) } ?? 99)
        }
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\(name)\\s*=\\s*[\"']([^\"']+)[\"']"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    func fetchTranscript(_ url: URL, type: String) async throws -> String? {
        let (data, response) = try await HTTP.get(url, timeout: 30)
        guard response.statusCode == 200, let raw = String(data: data, encoding: .utf8) else { return nil }
        return Self.parseTranscript(raw, type: type)
    }

    static func parseTranscript(_ raw: String, type: String) -> String {
        let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        if type.contains("json") || trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))
            let segments = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["segments"] as? [[String: Any]]) ?? []
            if !segments.isEmpty {
                return segments.compactMap { ($0["text"] as? String) ?? ($0["body"] as? String) }
                    .filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
        if type.contains("vtt") || type.contains("srt") || trimmed.hasPrefix("WEBVTT") {
            return trimmed.components(separatedBy: .newlines).filter { line in
                let line = line.trimmingCharacters(in: .whitespaces)
                return !line.isEmpty && !line.hasPrefix("WEBVTT") && !line.contains("-->") && Int(line) == nil && !line.hasPrefix("NOTE")
            }.map { $0.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression) }.joined(separator: " ")
        }
        if type.contains("html") { return HTMLTextExtractor.clean(trimmed) }
        return trimmed
    }

    // MARK: Apple Podcasts local cache

    static func localAppleTranscript(trackID: Int, cache: URL = appleTranscriptCache) -> String? {
        guard let enumerator = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil) else { return nil }
        let marker = "transcript_\(trackID)."
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix(marker) {
            guard let xml = try? String(contentsOf: url, encoding: .utf8) else { continue }
            return parseTTML(xml)
        }
        return nil
    }

    /// Apple's TTML nests word spans inside sentence spans; take the sentence-level text.
    static func parseTTML(_ xml: String) -> String {
        var paragraphs: [String] = []
        for paragraph in xml.components(separatedBy: "<p ").dropFirst() {
            var body = paragraph.components(separatedBy: "</p>").first ?? ""
            if let tagEnd = body.firstIndex(of: ">") { body = String(body[body.index(after: tagEnd)...]) }
            let words = body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            let text = HTMLTextExtractor.decodeEntities(words).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { paragraphs.append(text) }
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Transcripts often come as one block; split into ~5-sentence paragraphs for chunking.
    static func paragraphs(_ text: String) -> String {
        guard !text.contains("\n\n") else { return text }
        var result: [String] = []
        var current: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty else { return }
            current.append(sentence)
            if current.count == 5 { result.append(current.joined(separator: " ")); current = [] }
        }
        if !current.isEmpty { result.append(current.joined(separator: " ")) }
        return result.joined(separator: "\n\n")
    }
}
