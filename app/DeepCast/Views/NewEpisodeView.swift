import SwiftData
import SwiftUI

struct NewEpisodeView: View {
    @Environment(\.modelContext) private var context
    @Environment(PersonaStore.self) private var personas
    @Environment(AppSettings.self) private var settings
    @Environment(PipelineService.self) private var pipeline
    @Environment(NavigationModel.self) private var navigation
    @Environment(SystemStatusModel.self) private var status

    @State private var options = EpisodeOptions(topic: "")
    @FocusState private var topicFocused: Bool

    private let examples = [
        "Wie funktionieren Tardigraden?",
        "Warum ist der Himmel blau?",
        "Was ist dran am Intervallfasten?",
        "Wie entstand die Hanse?",
    ]

    private var canStart: Bool {
        options.topic.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 && !options.speakerIDs.isEmpty
    }

    var body: some View {
        Form {
            if let warning = settings.modelAvailability.message {
                Section {
                    HStack {
                        Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Spacer()
                        Button("Vorschlag übernehmen") { settings.applyModelReplacements() }
                    }
                }
            }
            Section {
                TextField("Thema oder Frage", text: $options.topic, prompt: Text("z.B. Wie funktionieren Tardigraden?"), axis: .vertical)
                    .font(.title3)
                    .lineLimit(1...3)
                    .focused($topicFocused)
                    .onSubmit { if canStart { start() } }
                HStack {
                    Text("Beispiele:").foregroundStyle(.secondary)
                    ForEach(examples, id: \.self) { example in
                        Button(example) { options.topic = example }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
            }

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(EpisodeCategory.allCases.filter { $0 != .general }) { category in
                        Toggle(isOn: categoryBinding(category)) {
                            Text(category.label)
                        }
                        .toggleStyle(.checkbox)
                        .help(category.summary)
                        .disabled(!options.categories.contains(category) && options.categories.count >= CategoryMix.maximum)
                    }
                }
                if options.categories.isEmpty {
                    Text("Keine Kategorie gewählt: ausgewogene Folge ohne besonderen Schwerpunkt.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(options.categories) { category in
                        Text("\(category == options.categories.first ? "★ " : "")\(category.label): \(category.summary)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                ForEach(options.categoryMix.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
            } header: {
                Text("Kategorien (bis zu \(CategoryMix.maximum))")
            } footer: {
                Text("Die Kategorien stellen Nerd-Level, Ausschweifungen, Quellen und Faktencheck passend ein (strengster Faktencheck, höchstes Nerd-Level, alle Quellen). Stil und Sprecher kommen von der zuerst gewählten Kategorie (★). Alles bleibt änderbar.")
            }

            Section("Folge") {
                LabeledContent("Länge (ungefähr)") {
                    HStack {
                        Slider(value: Binding(get: { Double(options.minutes) }, set: { options.minutes = Int($0.rounded()) }),
                               in: Double(EpisodeOptions.minuteRange.lowerBound)...Double(EpisodeOptions.minuteRange.upperBound),
                               step: Double(EpisodeOptions.minuteStep)) {
                            Text("Länge")
                        } minimumValueLabel: {
                            Text("\(EpisodeOptions.minuteRange.lowerBound)").font(.caption)
                        } maximumValueLabel: {
                            Text("\(EpisodeOptions.minuteRange.upperBound)").font(.caption)
                        }
                        Text("~\(options.minutes) min").monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
                if options.minutes >= 40 {
                    Text("Lange Folgen brauchen mehr Quellen und Anfragen (ca. \(estimatedRequests)). Mit Apple Intelligence allein werden sie deutlich kürzer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Nerd-Level", selection: $options.nerdLevel) {
                    Text("1 · Oberflächlich").tag(1)
                    Text("2 · Einsteiger").tag(2)
                    Text("3 · Interessiert").tag(3)
                    Text("4 · Fachkundig").tag(4)
                    Text("5 · Hardcore-Nerd").tag(5)
                }
                Picker("Ausschweifungen", selection: $options.digression) {
                    Text("0 · Strikt").tag(0)
                    Text("1 · Kontext").tag(1)
                    Text("2 · Breiter").tag(2)
                    Text("3 · Frei assoziativ").tag(3)
                }
                Picker("Stil", selection: $options.style) {
                    ForEach(EpisodeStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("Sprache", selection: $options.language) {
                    ForEach(EpisodeLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Faktencheck", selection: $options.strictness) {
                    ForEach(FactCheckStrictness.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                ForEach(personas.personas) { persona in
                    Toggle(isOn: speakerBinding(persona.id)) {
                        HStack {
                            Text(persona.name).fontWeight(.medium)
                            Text(persona.role).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!options.speakerIDs.contains(persona.id) && options.speakerIDs.count >= 4)
                }
            } header: {
                Text("Sprecher (\(options.speakerIDs.count) von max. 4)")
            } footer: {
                if options.speakerIDs.count == 1 {
                    Text("Ein Sprecher = Erzähler-Monolog.")
                } else if options.language == .en {
                    Text("Englisch ist eingeschränkt: Die Stimmen sind deutsch voreingestellt.")
                }
            }

            Section {
                ForEach(SourceKind.selectable) { kind in
                    Toggle(kind.label, isOn: sourceBinding(kind))
                }
            } header: {
                Text("Quellen")
            } footer: {
                Text("Paper: \(options.paperCount) · Podcasts mit Transkript: \(options.podcastCount). Die Anzahl richtet sich nach dem Nerd-Level.")
            }

            Section {
                CustomSourceEditor(sources: $options.customSources)
            } header: {
                Text("Eigene Quellen (\(options.customSources.count))")
            } footer: {
                Text("URLs, PDFs, Text-, Markdown- und HTML-Dateien. Werden immer verwendet; Standard-Vertrauensstufe C, pro Quelle änderbar.")
            }

            Section {
                Toggle("Für diese Folge andere KI verwenden", isOn: Binding(
                    get: { options.aiOverride != nil },
                    set: { options.aiOverride = $0 ? settings.resolvedAI(for: nil) : nil }))
                if options.aiOverride != nil {
                    AIChoiceEditor(choice: Binding(
                        get: { options.aiOverride ?? settings.resolvedAI(for: nil) },
                        set: { options.aiOverride = $0 }))
                } else {
                    Text(settings.resolvedAI(for: nil).summary).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("KI für diese Folge")
            }

            Section("Ablauf") {
                if settings.resolvedAI(for: options).llmMode == .openRouter {
                    LabeledContent("Gratis-Anfragen heute") {
                        if let quota = pipeline.quota {
                            Text("\(quota.remaining) von \(quota.limit) übrig · diese Folge ca. \(estimatedRequests)")
                                .foregroundStyle(quota.remaining < estimatedRequests ? .orange : .secondary)
                        } else {
                            Text("unbekannt").foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Nach der Recherche pausiert DeepCast. Du prüfst Quellen und Aussagen, dann entstehen Skript und Audio.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Neue Episode")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { start() } label: { Label("Recherche starten", systemImage: "sparkle.magnifyingglass") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canStart)
            }
        }
        .onAppear {
            topicFocused = true
            if options.topic.isEmpty { options.sources = settings.preferences.defaultSources }
        }
        .task { await pipeline.refreshQuota(settings: settings) }
    }

    /// Rough number of OpenRouter requests for one episode.
    private var estimatedRequests: Int {
        1 + options.maxSources + options.paperCount + options.podcastCount + 4 + options.sectionCount + 3
    }

    private func categoryBinding(_ category: EpisodeCategory) -> Binding<Bool> {
        Binding {
            options.categories.contains(category)
        } set: { isOn in
            var list = options.categories
            if isOn { if !list.contains(category) { list.append(category) } } else { list.removeAll { $0 == category } }
            CategoryMix(list).apply(to: &options)
            if list.isEmpty { options.sources = settings.preferences.defaultSources }
        }
    }

    private func sourceBinding(_ kind: SourceKind) -> Binding<Bool> {
        Binding {
            options.sources.contains(kind)
        } set: { isOn in
            if isOn { options.sources.insert(kind) } else if options.sources.count > 1 { options.sources.remove(kind) }
        }
    }

    private func speakerBinding(_ id: String) -> Binding<Bool> {
        Binding {
            options.speakerIDs.contains(id)
        } set: { isOn in
            if isOn, !options.speakerIDs.contains(id) {
                options.speakerIDs.append(id)
            } else if !isOn {
                options.speakerIDs.removeAll { $0 == id }
            }
        }
    }

    private func start() {
        var normalized = options
        normalized.topic = options.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.simpleSpeech = settings.resolvedAI(for: normalized).speechMode == .appleOnly
        let episode = Episode(title: normalized.topic, topic: normalized.topic, language: normalized.language.rawValue)
        episode.options = normalized
        context.insert(episode)
        try? context.save()
        pipeline.startResearch(episode, settings: settings, context: context)
        navigation.show(episode)
        options.topic = ""
    }
}
