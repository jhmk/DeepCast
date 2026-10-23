import Foundation

/// Retraction / correction check via Crossref (includes Retraction Watch data), free, no key.
/// https://api.crossref.org/works/{doi} → message["updated-by"].
struct CrossrefCheck: Sendable {
    enum Status: Equatable, Sendable {
        case ok
        case retracted(source: String)
        case concern
        case corrected

        var warning: String? {
            switch self {
            case .ok: nil
            case .retracted(let source): String(localized: "Zurückgezogen (Crossref/\(source))")
            case .concern: String(localized: "„Expression of Concern“ – Zweifel an der Arbeit")
            case .corrected: String(localized: "Korrektur veröffentlicht – Ergebnisse ggf. geändert")
            }
        }
    }

    func status(doi: String) async -> Status {
        let cleaned = Self.cleanDOI(doi)
        guard !cleaned.isEmpty,
              let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.crossref.org/works/\(encoded)?mailto=\(PaperSearch.mailto)"),
              let (data, response) = try? await HTTP.get(url, timeout: 15), response.statusCode == 200
        else { return .ok }
        return Self.parse(data)
    }

    static func cleanDOI(_ value: String) -> String {
        var doi = value.trimmingCharacters(in: .whitespaces)
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "doi:"] where doi.lowercased().hasPrefix(prefix) {
            doi.removeFirst(prefix.count)
        }
        return doi
    }

    static func parse(_ data: Data) -> Status {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any] else { return .ok }
        let updates = (message["updated-by"] as? [[String: Any]] ?? []) + (message["update-to"] as? [[String: Any]] ?? [])
        let types = updates.map { (($0["type"] as? String) ?? "").lowercased() }
        if let index = types.firstIndex(where: { ["retraction", "withdrawal", "removal"].contains($0) }) {
            return .retracted(source: (updates[index]["source"] as? String) ?? "publisher")
        }
        if types.contains(where: { $0.contains("concern") }) { return .concern }
        if types.contains(where: { ["correction", "erratum", "corrigendum"].contains($0) }) { return .corrected }
        if (message["type"] as? String) == "retraction" { return .retracted(source: "publisher") }
        return .ok
    }
}
