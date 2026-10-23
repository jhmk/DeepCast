import Foundation

/// A parsed line of dialogue, independent of SwiftData.
struct ParsedSegment: Equatable, Sendable {
    var speakerID: String
    var text: String
    var section: String
}

struct ParsedScript: Equatable, Sendable {
    var segments: [ParsedSegment]
    /// Speaker names that did not match a persona (assigned to the first persona).
    var unknownSpeakers: [String]
}

/// Parses plain text scripts:
/// ```
/// ## Kapitelname
/// Max: Text …
/// Dr. Lena: Text …
/// Fortsetzung ohne Sprecher gehört zum vorherigen Segment.
/// ```
enum ScriptParser {
    static let defaultSection = "Intro"

    static func parse(_ text: String, personas: [Persona]) -> ParsedScript {
        var segments: [ParsedSegment] = []
        var unknown: [String] = []
        var section = defaultSection
        let fallbackID = personas.first?.id ?? "max"

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { section = title }
                continue
            }

            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                let body = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if let persona = match(name, in: personas) {
                    if !body.isEmpty {
                        segments.append(ParsedSegment(speakerID: persona.id, text: body, section: section))
                    }
                    continue
                }
                // Short, capitalised prefix without spaces in odd places looks like a speaker name.
                if looksLikeSpeaker(name), !body.isEmpty {
                    if !unknown.contains(name) { unknown.append(name) }
                    segments.append(ParsedSegment(speakerID: fallbackID, text: body, section: section))
                    continue
                }
            }

            if var last = segments.last, last.section == section {
                last.text += " " + line
                segments[segments.count - 1] = last
            } else {
                segments.append(ParsedSegment(speakerID: fallbackID, text: line, section: section))
            }
        }
        return ParsedScript(segments: segments, unknownSpeakers: unknown)
    }

    static func match(_ name: String, in personas: [Persona]) -> Persona? {
        let needle = name.lowercased()
        return personas.first { $0.name.lowercased() == needle }
            ?? personas.first { $0.name.lowercased().split(separator: " ").last.map(String.init) == needle }
    }

    private static func looksLikeSpeaker(_ name: String) -> Bool {
        let words = name.split(separator: " ")
        return !name.isEmpty && name.count <= 25 && words.count <= 3
            && (name.first?.isUppercase ?? false) && !name.contains(where: \.isNumber)
    }

    /// Example used for a quick test of the audio chain.
    static let exampleScript = """
    ## Intro
    Max: Hallo und willkommen bei DeepCast! Heute geht es um winzige Tiere, die fast alles überleben: Bärtierchen.
    Dr. Lena: Hallo Max. Bärtierchen, auf Latein Tardigrada, sind meist kleiner als einen Millimeter.
    Max: Kleiner als einen Millimeter? Und warum heißen die Bärtierchen?
    Dr. Lena: Wegen ihres Aussehens und ihrer tapsigen Fortbewegung. Sie erinnern ein bisschen an kleine Bären.

    ## Überlebenskünstler
    Max: Was macht sie denn so besonders?
    Dr. Lena: Sie können in einen Zustand namens Kryptobiose übergehen. Dabei kommt ihr Stoffwechsel fast vollständig zum Erliegen.
    Tobi: Und das Verrückte ist: In diesem Zustand überstehen sie Temperaturen von fast dem absoluten Nullpunkt bis über 150 Grad Celsius!
    Max: Das klingt unglaublich.
    Dr. Lena: Ja, aber wichtig ist: Das gilt für den Zustand der Kryptobiose, nicht für aktive Tiere.
    """
}
