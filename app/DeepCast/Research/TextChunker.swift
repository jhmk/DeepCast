import Foundation

enum TextChunker {
    /// Splits text at paragraph boundaries into chunks of roughly `targetWords` words.
    /// Very long paragraphs are split at sentence ends.
    static func chunk(_ text: String, sourceID: String, targetWords: Int = 220) -> [SourceChunk] {
        var chunks: [SourceChunk] = []
        var current: [String] = []
        var currentWords = 0
        var offset = 0
        var chunkStart = 0

        func flush() {
            guard !current.isEmpty else { return }
            let body = current.joined(separator: "\n\n")
            chunks.append(SourceChunk(id: "\(sourceID)-C\(chunks.count + 1)", text: body, offset: chunkStart))
            current = []
            currentWords = 0
        }

        for paragraph in text.components(separatedBy: "\n\n") {
            defer { offset += paragraph.count + 2 }
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            for piece in split(trimmed, maxWords: targetWords) {
                let words = piece.split(whereSeparator: \.isWhitespace).count
                if currentWords > 0, currentWords + words > targetWords { flush() }
                if current.isEmpty { chunkStart = offset }
                current.append(piece)
                currentWords += words
            }
        }
        flush()
        return chunks
    }

    private static func split(_ paragraph: String, maxWords: Int) -> [String] {
        guard paragraph.split(whereSeparator: \.isWhitespace).count > maxWords else { return [paragraph] }
        var parts: [String] = []
        var buffer = ""
        paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            if (buffer + sentence).split(whereSeparator: \.isWhitespace).count > maxWords, !buffer.isEmpty {
                parts.append(buffer.trimmingCharacters(in: .whitespaces))
                buffer = ""
            }
            buffer += sentence
        }
        if !buffer.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(buffer.trimmingCharacters(in: .whitespaces)) }
        return parts
    }

    /// Plain text without blank lines (e.g. PDFs) → paragraphs of ~6 sentences.
    static func paragraphsIfNeeded(_ text: String) -> String {
        guard !text.contains("\n\n") else { return text }
        var result: [String] = []
        var current: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else { return }
            current.append(sentence)
            if current.count == 6 { result.append(current.joined(separator: " ")); current = [] }
        }
        if !current.isEmpty { result.append(current.joined(separator: " ")) }
        return result.joined(separator: "\n\n")
    }

    static let stopwords: Set<String> = [
        "und", "oder", "aber", "der", "die", "das", "den", "dem", "des", "ein", "eine", "einer", "eines",
        "einem", "einen", "ist", "sind", "war", "waren", "wird", "werden", "wurde", "wurden", "mit", "von",
        "für", "auf", "aus", "bei", "nach", "über", "unter", "wie", "was", "wer", "warum", "wieso", "auch",
        "nicht", "sich", "sie", "er", "es", "wir", "ihr", "dass", "diese", "dieser", "dieses", "können",
        "kann", "haben", "hat", "hatte", "the", "and", "for", "with", "that", "this", "from", "are", "was",
        "what", "how", "why", "funktionieren", "funktioniert",
    ]

    /// Lowercased content words (≥ 4 letters, no stopwords).
    static func terms(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stopwords.contains($0) }
    }

    /// Relevance by keyword hits with prefix matching (handles German inflection) and
    /// diminishing returns per keyword.
    static func relevance(of chunk: String, keywords: [String]) -> Double {
        let words = terms(chunk)
        guard !words.isEmpty else { return 0 }
        var score = 0.0
        for keyword in Set(keywords.flatMap(terms)) {
            let stem = String(keyword.prefix(max(4, keyword.count - 2)))
            let hits = words.filter { $0.hasPrefix(stem) }.count
            if hits > 0 { score += 1 + log(Double(hits)) }
        }
        return score
    }

    /// Picks the most relevant chunks that fit into `budgetChars`, returned in text order.
    static func selectRelevant(_ chunks: [SourceChunk], keywords: [String], budgetChars: Int, maxChunks: Int) -> [SourceChunk] {
        struct Ranked { let index: Int; let chunk: SourceChunk; let score: Double }
        var ranked: [Ranked] = []
        for (index, chunk) in chunks.enumerated() {
            let score = relevance(of: chunk.text, keywords: keywords)
            if score > 0 { ranked.append(Ranked(index: index, chunk: chunk, score: score)) }
        }
        ranked.sort { lhs, rhs in lhs.score != rhs.score ? lhs.score > rhs.score : lhs.index < rhs.index }
        var picked: [(Int, SourceChunk)] = []
        var used = 0
        for item in ranked where picked.count < maxChunks {
            guard used + item.chunk.text.count <= budgetChars || picked.isEmpty else { continue }
            picked.append((item.index, item.chunk))
            used += item.chunk.text.count
        }
        return picked.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
