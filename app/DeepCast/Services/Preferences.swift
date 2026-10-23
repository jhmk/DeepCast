import Foundation
import Observation

// MARK: - Domain rules (spec 5.1: "Domain-Liste editierbar: erlauben / abwerten / sperren")

enum DomainAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case trust, downgrade, block

    var id: String { rawValue }

    var label: String {
        switch self {
        case .trust: String(localized: "Vertrauen (mind. Stufe B)")
        case .downgrade: String(localized: "Abwerten (eine Stufe tiefer)")
        case .block: String(localized: "Sperren")
        }
    }
}

struct DomainRule: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var domain: String
    var action: DomainAction
}

/// Sendable snapshot used by the pipeline.
struct DomainRules: Sendable, Hashable {
    var rules: [DomainRule] = []

    static func normalize(_ domain: String) -> String {
        var value = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: value), let host = url.host() { value = host }
        for prefix in ["https://", "http://", "www."] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func action(forHost host: String) -> DomainAction? {
        let host = host.lowercased()
        // Most specific rule wins.
        return rules
            .filter { !$0.domain.isEmpty && (host == $0.domain || host.hasSuffix("." + $0.domain)) }
            .max { $0.domain.count < $1.domain.count }?.action
    }

    func isBlocked(_ host: String) -> Bool { action(forHost: host) == .block }

    /// Default tier adjusted by the user's rules.
    func tier(forHost host: String) -> TrustTier {
        let base = SourceTrust.tier(forHost: host)
        switch action(forHost: host) {
        case .trust: return min(base, .b)
        case .downgrade:
            let all = TrustTier.allCases
            return all[min(all.count - 1, (all.firstIndex(of: base) ?? 2) + 1)]
        case .block, nil: return base
        }
    }
}

// MARK: - Pronunciation dictionary

struct PronunciationEntry: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var written: String
    var spoken: String
}

/// User preferences that are lists (stored as JSON in Application Support).
@MainActor
@Observable
final class PreferencesStore {
    var domainRules: [DomainRule] { didSet { save() } }
    var pronunciations: [PronunciationEntry] { didSet { save() } }
    var defaultSources: Set<SourceKind> { didSet { save() } }

    private let fileURL: URL

    private struct Stored: Codable {
        var domainRules: [DomainRule]
        var pronunciations: [PronunciationEntry]
        var defaultSources: [String]
    }

    static let starterPronunciations: [PronunciationEntry] = [
        PronunciationEntry(written: "DNA", spoken: "D N A"),
        PronunciationEntry(written: "Dsup", spoken: "D-Sup"),
        PronunciationEntry(written: "CAHS", spoken: "C A H S"),
        PronunciationEntry(written: "SAHS", spoken: "S A H S"),
    ]

    init(fileURL: URL = AppPaths.applicationSupport().appending(path: "preferences.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            domainRules = stored.domainRules
            pronunciations = stored.pronunciations
            let sources = Set(stored.defaultSources.compactMap(SourceKind.init(rawValue:)))
            defaultSources = sources.isEmpty ? SourceKind.defaultSet : sources
        } else {
            domainRules = []
            pronunciations = Self.starterPronunciations
            defaultSources = SourceKind.defaultSet
        }
    }

    var rulesSnapshot: DomainRules {
        DomainRules(rules: domainRules.map { DomainRule(id: $0.id, domain: DomainRules.normalize($0.domain), action: $0.action) })
    }

    var pronunciationMap: [String: String] {
        var map: [String: String] = [:]
        for entry in pronunciations {
            let written = entry.written.trimmingCharacters(in: .whitespaces)
            let spoken = entry.spoken.trimmingCharacters(in: .whitespaces)
            if !written.isEmpty, !spoken.isEmpty { map[written] = spoken }
        }
        return map
    }

    func addRule(domain: String, action: DomainAction) {
        let normalized = DomainRules.normalize(domain)
        guard !normalized.isEmpty else { return }
        domainRules.removeAll { DomainRules.normalize($0.domain) == normalized }
        domainRules.append(DomainRule(domain: normalized, action: action))
    }

    private func save() {
        let stored = Stored(domainRules: domainRules, pronunciations: pronunciations,
                            defaultSources: defaultSources.map(\.rawValue).sorted())
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(stored).write(to: fileURL, options: .atomic)
        } catch {
            // Preferences are not critical; keep running with in-memory values.
        }
    }
}
