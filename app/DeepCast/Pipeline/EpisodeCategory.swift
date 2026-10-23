import Foundation

/// What the episode is for (content and goal). Complements `EpisodeStyle` (the form).
/// A category only pre-sets options in "Neue Episode"; everything stays editable.
enum EpisodeCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case general, introduction, scientific, everyday, travel, history, news, howTo, portrait, curiosities, analysis, relaxed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: String(localized: "Allgemein")
        case .introduction: String(localized: "Einstieg ins Thema")
        case .scientific: String(localized: "Wissenschaftlich")
        case .everyday: String(localized: "Lebensnah")
        case .travel: String(localized: "Reiseführer")
        case .history: String(localized: "Geschichte / Zeitreise")
        case .news: String(localized: "Aktuell / Nachrichten")
        case .howTo: String(localized: "Ratgeber / How-to")
        case .portrait: String(localized: "Porträt")
        case .curiosities: String(localized: "Kurios & Fun Facts")
        case .analysis: String(localized: "Hintergrund & Analyse")
        case .relaxed: String(localized: "Entspannt / Gute Nacht")
        }
    }

    var summary: String {
        switch self {
        case .general: String(localized: "Ausgewogene Folge ohne besonderen Schwerpunkt.")
        case .introduction: String(localized: "Überblick für Neulinge: Grundbegriffe zuerst, am Ende „Was du jetzt weißt“.")
        case .scientific: String(localized: "Forschungsstand mit Methodik und Grenzen, viele Paper, strenger Faktencheck.")
        case .everyday: String(localized: "„Was heißt das für mich?“ – Alltagsbeispiele und belegte Tipps.")
        case .travel: String(localized: "Ort erleben: Geschichte, Sehenswertes, Kultur, Essen, Anreise. Mit Wikivoyage, Reiseführern, Blogs und Tourismusseiten.")
        case .history: String(localized: "Chronologisch erzählt, Jahreszahlen streng geprüft.")
        case .news: String(localized: "Was gerade passiert – nur aktuelle Quellen, mit Stand-Datum.")
        case .howTo: String(localized: "Schritt für Schritt, Optionen mit Pro und Contra.")
        case .portrait: String(localized: "Person, Firma oder Erfindung: Werdegang, Wirkung, Kontroversen.")
        case .curiosities: String(localized: "Überraschende Fakten zum Staunen – trotzdem voll geprüft.")
        case .analysis: String(localized: "Ursachen und Zusammenhänge aus mehreren Perspektiven.")
        case .relaxed: String(localized: "Ruhig und langsamer gesprochen, wenige Zahlen.")
        }
    }

    // MARK: Presets (only applied in the form, user can change everything)

    struct Preset {
        var nerdLevel: Int
        var digression: Int
        var strictness: FactCheckStrictness
        var style: EpisodeStyle
        var sources: Set<SourceKind>
        var speakerIDs: [String]
    }

    var preset: Preset {
        let base = SourceKind.defaultSet
        switch self {
        case .general:
            return Preset(nerdLevel: 3, digression: 1, strictness: .standard, style: .discussion, sources: base, speakerIDs: ["max", "lena"])
        case .introduction:
            return Preset(nerdLevel: 1, digression: 1, strictness: .standard, style: .interview,
                          sources: [.wikipedia, .web, .podcast], speakerIDs: ["max", "lena"])
        case .scientific:
            return Preset(nerdLevel: 4, digression: 0, strictness: .strict, style: .interview,
                          sources: [.wikipedia, .paper, .web], speakerIDs: ["max", "lena", "sabine"])
        case .everyday:
            return Preset(nerdLevel: 2, digression: 1, strictness: .standard, style: .discussion,
                          sources: [.wikipedia, .web, .podcast], speakerIDs: ["max", "jonas"])
        case .travel:
            return Preset(nerdLevel: 2, digression: 2, strictness: .standard, style: .discussion,
                          sources: [.wikivoyage, .wikipedia, .web, .podcast], speakerIDs: ["max", "tobi"])
        case .history:
            return Preset(nerdLevel: 3, digression: 1, strictness: .standard, style: .narrative,
                          sources: [.wikipedia, .web, .paper, .podcast, .openLibrary, .gutenberg], speakerIDs: ["max", "lena"])
        case .news:
            return Preset(nerdLevel: 3, digression: 0, strictness: .standard, style: .discussion,
                          sources: [.web, .wikipedia], speakerIDs: ["max", "sabine"])
        case .howTo:
            return Preset(nerdLevel: 2, digression: 0, strictness: .strict, style: .interview,
                          sources: [.web, .wikipedia, .paper], speakerIDs: ["max", "jonas"])
        case .portrait:
            return Preset(nerdLevel: 3, digression: 1, strictness: .standard, style: .narrative,
                          sources: [.wikipedia, .web, .podcast], speakerIDs: ["max", "lena"])
        case .curiosities:
            return Preset(nerdLevel: 2, digression: 3, strictness: .standard, style: .discussion,
                          sources: base, speakerIDs: ["max", "tobi"])
        case .analysis:
            return Preset(nerdLevel: 4, digression: 1, strictness: .standard, style: .debate,
                          sources: [.web, .wikipedia, .paper], speakerIDs: ["max", "lena", "sabine"])
        case .relaxed:
            return Preset(nerdLevel: 2, digression: 2, strictness: .standard, style: .narrative,
                          sources: [.wikipedia, .web], speakerIDs: ["lena"])
        }
    }

    // MARK: Prompt instructions

    /// For planning (search queries) and outline/script.
    var instruction: String {
        switch self {
        case .general:
            "Kategorie: allgemeine Wissensfolge."
        case .introduction:
            "Kategorie: Einstieg ins Thema. Zuerst Grundbegriffe und das große Bild, dann Details. Letztes Kapitel: „Was du jetzt weißt“ mit den wichtigsten Punkten."
        case .scientific:
            "Kategorie: wissenschaftlich. Forschungsstand, Studiendesign (Labor, Tier, Mensch, Stichprobe), Grenzen und offene Fragen. Einzelstudien als Einzelstudien bezeichnen, Übersichtsarbeiten hervorheben."
        case .everyday:
            "Kategorie: lebensnah. Immer der Bezug „Was heißt das für mich im Alltag?“, konkrete Beispiele. Ein Kapitel „Was du konkret tun kannst“ – nur mit belegten Aussagen, keine eigenen Ratschläge."
        case .travel:
            "Kategorie: Reiseführer. Gliederung etwa: Ankommen und Überblick, Geschichte in Kürze, Sehenswertes, Viertel und Atmosphäre, Essen und Kultur, praktische Tipps (Anreise, Fortbewegung, beste Reisezeit). Persönliche Empfehlungen aus Blogs als Erfahrung kennzeichnen („Eine Reisebloggerin empfiehlt …“). Preise, Öffnungszeiten und Fahrpläne immer mit „Stand <Jahr>, bitte vor Ort prüfen“."
        case .history:
            "Kategorie: Geschichte. Chronologisch erzählen, Ursachen und Folgen, Jahreszahlen exakt aus den Aussagen. Quellenlage und Deutungsstreit erwähnen."
        case .news:
            "Kategorie: aktuell. Was ist passiert, warum ist es wichtig, wie geht es weiter. Jede Aussage mit Datum bzw. „Stand <Datum>“, keine Spekulationen."
        case .howTo:
            "Kategorie: Ratgeber. Schritt für Schritt, Optionen mit Pro und Contra, typische Fehler. Nur belegte Empfehlungen; bei Gesundheit, Recht oder Geld ausdrücklich auf Fachleute verweisen."
        case .portrait:
            "Kategorie: Porträt. Herkunft, Werdegang, wichtigste Leistungen, Wirkung, Kontroversen. Zitate nur wörtlich mit Quelle, sonst als Paraphrase."
        case .curiosities:
            "Kategorie: Kurios & Fun Facts. Überraschende, erstaunliche Fakten mit Aha-Effekt, verbunden durch einen roten Faden. Trotzdem nur belegte Aussagen."
        case .analysis:
            "Kategorie: Hintergrund & Analyse. Ursachen und Zusammenhänge, mehrere Perspektiven, Widersprüche offen benennen, Korrelation nicht als Kausalität darstellen."
        case .relaxed:
            "Kategorie: entspannt zum Zuhören (auch zum Einschlafen). Ruhiger Ton, sanfter Erzählfluss, wenige Zahlen, keine Aufregung, keine Cliffhanger, ruhiger Abschluss."
        }
    }

    /// Additional hint for claim extraction.
    var extractionHint: String {
        switch self {
        case .travel: "Bei Reiseseiten: persönliche Tipps und Empfehlungen als opinion oder anecdote. Preise, Öffnungszeiten und Fahrpläne mit Jahr übernehmen, falls angegeben."
        case .news: "Datum des Ereignisses in die Aussage übernehmen, falls angegeben."
        case .howTo: "Handlungsempfehlungen nur übernehmen, wenn die Quelle sie ausdrücklich gibt; nicht verallgemeinern."
        default: ""
        }
    }

    /// Extra web searches (DuckDuckGo) for the category.
    func extraQueries(topic: String, language: EpisodeLanguage) -> [String] {
        switch self {
        case .travel:
            language == .de
                ? ["\(topic) Reiseführer", "\(topic) Reiseblog Tipps", "\(topic) offizielle Tourismus Seite"]
                : ["\(topic) travel guide", "\(topic) travel blog tips", "\(topic) official tourism"]
        case .news:
            language == .de ? ["\(topic) aktuell \(Calendar.current.component(.year, from: .now))"] : ["\(topic) news \(Calendar.current.component(.year, from: .now))"]
        default: []
        }
    }

    // MARK: Delivery

    /// Speaking speed (1.0 = normal).
    var speechRate: Double { self == .relaxed ? 0.9 : 1.0 }
    /// Factor for pauses between segments.
    var pauseFactor: Double { self == .relaxed ? 1.6 : 1.0 }
}

/// Combination of up to three categories (spec: several categories at once).
/// Rules: strictest fact check, highest nerd level and digression, union of sources,
/// style and speakers from the first category, all instructions combined.
struct CategoryMix: Sendable, Hashable {
    static let maximum = 3

    let categories: [EpisodeCategory]

    init(_ categories: [EpisodeCategory]) {
        var seen = Set<EpisodeCategory>()
        self.categories = categories.filter { $0 != .general && seen.insert($0).inserted }.prefix(Self.maximum).map { $0 }
    }

    var isEmpty: Bool { categories.isEmpty }
    var primary: EpisodeCategory { categories.first ?? .general }
    var label: String { isEmpty ? EpisodeCategory.general.label : categories.map(\.label).joined(separator: " + ") }

    var preset: EpisodeCategory.Preset {
        guard !categories.isEmpty else { return EpisodeCategory.general.preset }
        let presets = categories.map(\.preset)
        var result = presets[0]
        result.nerdLevel = presets.map(\.nerdLevel).max() ?? result.nerdLevel
        result.digression = presets.map(\.digression).max() ?? result.digression
        result.strictness = presets.contains { $0.strictness == .strict } ? .strict : .standard
        result.sources = presets.reduce(into: Set<SourceKind>()) { $0.formUnion($1.sources) }
        return result
    }

    func apply(to options: inout EpisodeOptions) {
        let preset = preset
        options.categories = categories
        options.nerdLevel = preset.nerdLevel
        options.digression = preset.digression
        options.strictness = preset.strictness
        options.style = preset.style
        options.sources = preset.sources
        options.speakerIDs = preset.speakerIDs
    }

    var instruction: String {
        guard !categories.isEmpty else { return EpisodeCategory.general.instruction }
        let parts = categories.map(\.instruction)
        guard parts.count > 1 else { return parts[0] }
        return "Kombinierte Kategorien – verbinde die Schwerpunkte zu einer stimmigen Folge, Hauptkategorie zuerst:\n"
            + parts.map { "  • " + $0 }.joined(separator: "\n")
    }

    var extractionHint: String {
        categories.map(\.extractionHint).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func extraQueries(topic: String, language: EpisodeLanguage) -> [String] {
        var seen = Set<String>()
        return categories.flatMap { $0.extraQueries(topic: topic, language: language) }.filter { seen.insert($0).inserted }
    }

    var speechRate: Double { categories.map(\.speechRate).min() ?? 1.0 }
    var pauseFactor: Double { categories.map(\.pauseFactor).max() ?? 1.0 }

    /// Pairs whose goals pull in opposite directions.
    static let conflicts: [(EpisodeCategory, EpisodeCategory, String)] = [
        (.relaxed, .news, "„Entspannt“ und „Aktuell“: ruhiger Ton passt schlecht zu Nachrichten."),
        (.relaxed, .scientific, "„Entspannt“ und „Wissenschaftlich“: viele Zahlen und Methodik stören den ruhigen Fluss."),
        (.relaxed, .analysis, "„Entspannt“ und „Hintergrund & Analyse“: Streitfragen passen schlecht zum Einschlafen."),
        (.introduction, .scientific, "„Einstieg“ und „Wissenschaftlich“: es gilt das höhere Nerd-Level – ggf. von Hand senken."),
        (.curiosities, .news, "„Kurios“ und „Aktuell“: Ausschweifungen können die Nachrichtenlage verwässern."),
    ]

    var warnings: [String] {
        Self.conflicts.filter { categories.contains($0.0) && categories.contains($0.1) }.map(\.2)
    }
}
