import Foundation
import Observation

/// Loads and saves personas as JSON in Application Support (editable by hand as well).
@MainActor
@Observable
final class PersonaStore {
    private(set) var personas: [Persona] = []
    private(set) var lastError: String?
    private let fileURL: URL

    init(fileURL: URL = AppPaths.personasFile()) {
        self.fileURL = fileURL
        load()
    }

    func persona(id: String) -> Persona? {
        personas.first { $0.id == id }
    }

    /// Finds a persona by display name, ignoring case and a leading "Dr." etc.
    func persona(named name: String) -> Persona? {
        let needle = name.trimmingCharacters(in: .whitespaces).lowercased()
        return personas.first { $0.name.lowercased() == needle }
            ?? personas.first { $0.name.lowercased().hasSuffix(" " + needle) }
    }

    func update(_ persona: Persona) {
        guard let index = personas.firstIndex(where: { $0.id == persona.id }) else { return }
        personas[index] = persona
        save()
    }

    func resetToDefaults() {
        personas = Persona.defaults
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            personas = Persona.defaults
            return
        }
        do {
            personas = try JSONDecoder().decode([Persona].self, from: data)
        } catch {
            lastError = String(localized: "Personas konnten nicht gelesen werden, Standard wird verwendet.")
            personas = Persona.defaults
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(personas).write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
