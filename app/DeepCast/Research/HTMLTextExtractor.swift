import Foundation

/// Lightweight main-text extraction (a small stand-in for trafilatura): drops boilerplate
/// elements, prefers <article>/<main>, keeps paragraphs and headings with real sentences.
enum HTMLTextExtractor {
    struct Result: Sendable, Equatable {
        var title: String
        var text: String
        var publishedAt: Date?
        var language: String?
        var paywalled: Bool
    }

    static func extract(_ html: String) -> Result {
        let title = metaContent(html, property: "og:title") ?? tagText(html, tag: "title") ?? ""
        let date = publishedDate(html)
        let language = firstMatch(html, #"<html[^>]*\blang=["']?([a-zA-Z-]{2,5})"#).map { String($0.prefix(2)).lowercased() }
        let paywalled = html.range(of: #""isAccessibleForFree"\s*:\s*"?false"#, options: [.regularExpression, .caseInsensitive]) != nil

        var body = html
        for tag in ["script", "style", "noscript", "svg", "nav", "header", "footer", "aside", "form", "figure", "button", "iframe", "template"] {
            body = body.replacingOccurrences(of: "(?s)<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        body = body.replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
        if let main = largestBlock(body, tags: ["article", "main"]) { body = main }

        var blocks: [(text: String, isHeading: Bool)] = []
        let pattern = #"<(p|h2|h3|li|blockquote)\b[^>]*>(.*?)</\1>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return Result(title: clean(title), text: "", publishedAt: date, language: language, paywalled: paywalled)
        }
        let ns = body as NSString
        for match in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range(at: 1)).lowercased()
            let text = clean(ns.substring(with: match.range(at: 2)))
            switch tag {
            case "h2", "h3": if text.count >= 3, text.count <= 120 { blocks.append((text, true)) }
            case "li": if text.count >= 80, text.contains(" ") { blocks.append((text, false)) }
            default: if text.count >= 50, text.contains(". ") || text.hasSuffix(".") || text.count > 120 { blocks.append((text, false)) }
            }
        }
        // Drop headings that are not followed by content, and repeated blocks.
        var filtered: [String] = []
        for (index, block) in blocks.enumerated() {
            if block.isHeading, index + 1 >= blocks.count || blocks[index + 1].isHeading { continue }
            if filtered.last != block.text { filtered.append(block.text) }
        }
        return Result(title: clean(title), text: filtered.joined(separator: "\n\n"),
                      publishedAt: date, language: language, paywalled: paywalled)
    }

    // MARK: - Helpers

    static func clean(_ fragment: String) -> String {
        var text = fragment.replacingOccurrences(of: "<br\\s*/?>", with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "\u{00AD}", with: "")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "shy": "",
            "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß",
            "eacute": "é", "egrave": "è", "aacute": "á", "ndash": "–", "mdash": "—", "hellip": "…",
            "laquo": "«", "raquo": "»", "bdquo": "„", "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’",
            "sbquo": "‚", "deg": "°", "euro": "€", "times": "×", "middot": "·", "thinsp": " ", "ensp": " ",
        ]
        guard let regex = try? NSRegularExpression(pattern: "&(#x?[0-9a-fA-F]+|[a-zA-Z]+);") else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let entity = ns.substring(with: match.range(at: 1))
            var replacement: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if entity.hasPrefix("#") {
                replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[entity]
            }
            result += replacement ?? ns.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func largestBlock(_ html: String, tags: [String]) -> String? {
        var best: String?
        for tag in tags {
            guard let regex = try? NSRegularExpression(pattern: "<\(tag)\\b[^>]*>(.*?)</\(tag)>", options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let inner = ns.substring(with: match.range(at: 1))
                if inner.count > (best?.count ?? 0) { best = inner }
            }
        }
        // Only trust the block if it holds a meaningful part of the page.
        guard let best, best.count > 2_000 else { return nil }
        return best
    }

    private static func metaContent(_ html: String, property: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        return firstMatch(html, #"<meta[^>]+(?:property|name)=["']\#(escaped)["'][^>]+content=["']([^"']+)["']"#)
            ?? firstMatch(html, #"<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']\#(escaped)["']"#)
    }

    private static func tagText(_ html: String, tag: String) -> String? {
        firstMatch(html, "<\(tag)[^>]*>(.*?)</\(tag)>")
    }

    static func publishedDate(_ html: String) -> Date? {
        let candidates = [
            metaContent(html, property: "article:published_time"),
            metaContent(html, property: "date"),
            metaContent(html, property: "dc.date"),
            firstMatch(html, #""datePublished"\s*:\s*"([^"]+)""#),
            firstMatch(html, #"<time[^>]+datetime=["']([^"']+)["']"#),
            metaContent(html, property: "article:modified_time"),
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let date = parseISODate(candidate) { return date }
        }
        return nil
    }

    static func parseISODate(_ string: String) -> Date? {
        let prefix = String(string.prefix(10))
        guard prefix.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = prefix.split(separator: "-").compactMap { Int($0) }
        let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        guard let date, date <= Date().addingTimeInterval(86_400), parts[0] > 1990 else { return nil }
        return date
    }

    private static func firstMatch(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
