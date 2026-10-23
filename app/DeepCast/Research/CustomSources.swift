import Foundation
import PDFKit
import UniformTypeIdentifiers

/// A URL or local file added by the user.
struct CustomSource: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    /// Web URL or absolute file path.
    var location: String
    var tier: TrustTier = .c

    var isFile: Bool { location.hasPrefix("/") || location.hasPrefix("file://") }

    var fileURL: URL? {
        guard isFile else { return nil }
        return location.hasPrefix("file://") ? URL(string: location) : URL(fileURLWithPath: location)
    }

    var displayName: String {
        if let fileURL { return fileURL.lastPathComponent }
        guard let url = URL(string: location), let host = url.host() else { return location }
        return host + url.path()
    }

    static let fileTypes: [UTType] = [.pdf, .plainText, .text, .html, UTType(filenameExtension: "md") ?? .plainText]

    /// From user input: http(s) URL or existing file path.
    static func parse(_ input: String) -> CustomSource? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil {
            return CustomSource(location: url.absoluteString)
        }
        let path = (value as NSString).expandingTildeInPath
        if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) { return CustomSource(location: path) }
        return nil
    }
}

enum CustomSourceError: LocalizedError {
    case unreadable, unsupported, empty
    var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "Datei nicht lesbar")
        case .unsupported: String(localized: "Dateityp nicht unterstützt (PDF, Text, Markdown, HTML)")
        case .empty: String(localized: "kein verwertbarer Text")
        }
    }
}

/// Loads own sources into SourceDocuments (URL via web fetch + paywall fallback, files locally).
struct CustomSourceLoader: Sendable {
    var paywall = PaywallConfig()
    var fetcher = WebPageFetcher()

    func load(_ source: CustomSource) async throws -> SourceDocument {
        if let fileURL = source.fileURL { return try loadFile(fileURL, tier: source.tier) }
        guard let url = URL(string: source.location) else { throw URLError(.badURL) }
        var method: String?
        let page: WebPageFetcher.Page
        do {
            page = try await fetcher.fetch(url)
            if page.extracted.paywalled, paywall.enabled, let full = try? await fetchPaywalled(url) {
                return document(url: url, page: full.page, method: full.method, tier: source.tier)
            }
        } catch WebPageFetcher.FetchError.tooShort where paywall.enabled {
            let full = try await fetchPaywalled(url)
            return document(url: url, page: full.page, method: full.method, tier: source.tier)
        }
        method = page.extracted.paywalled ? "nur frei sichtbarer Teil (Paywall)" : nil
        return document(url: url, page: page, method: method, tier: source.tier)
    }

    private func fetchPaywalled(_ url: URL) async throws -> PaywallFetcher.Result {
        let result = await PaywallFetcher(config: paywall).fetch([url]) { _ in }
        switch result.first?.1 {
        case .success(let fetched): return fetched
        case .failure(let error): throw error
        case nil: throw WebPageFetcher.FetchError.tooShort
        }
    }

    private func document(url: URL, page: WebPageFetcher.Page, method: String?, tier: TrustTier) -> SourceDocument {
        let host = url.host() ?? "?"
        var notes = [String(localized: "Eigene Quelle")]
        if let method { notes.append(String(localized: "Gelesen über \(method)")) }
        var document = SourceDocument(
            id: "", kind: .custom, title: page.extracted.title.isEmpty ? host : page.extracted.title,
            publisher: SourceTrust.registrableDomain(host), url: url, publishedAt: page.extracted.publishedAt,
            language: page.extracted.language ?? "de", tier: tier, chunks: [], notes: notes)
        document.fetchMethod = method
        document.chunks = TextChunker.chunk(page.extracted.text, sourceID: "TMP")
        return document
    }

    func loadFile(_ url: URL, tier: TrustTier) throws -> SourceDocument {
        let ext = url.pathExtension.lowercased()
        var title = url.deletingPathExtension().lastPathComponent
        let text: String
        switch ext {
        case "pdf":
            guard let pdf = PDFDocument(url: url) else { throw CustomSourceError.unreadable }
            if let pdfTitle = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !pdfTitle.isEmpty { title = pdfTitle }
            text = PaperSearch.cleanPDFText(pdf.string ?? "")
        case "txt", "md", "markdown", "text":
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { throw CustomSourceError.unreadable }
            text = raw.replacingOccurrences(of: #"(?m)^#+\s*"#, with: "", options: .regularExpression)
        case "html", "htm":
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { throw CustomSourceError.unreadable }
            let extracted = HTMLTextExtractor.extract(raw)
            if !extracted.title.isEmpty { title = extracted.title }
            text = extracted.text
        default:
            throw CustomSourceError.unsupported
        }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 100 else { throw CustomSourceError.empty }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        var document = SourceDocument(
            id: "", kind: .custom, title: title, publisher: url.lastPathComponent, url: url, publishedAt: modified,
            language: "de", tier: tier, chunks: [], notes: [String(localized: "Eigene Datei")])
        document.chunks = TextChunker.chunk(TextChunker.paragraphsIfNeeded(text), sourceID: "TMP")
        return document
    }
}
