import SwiftUI

struct PersonasView: View {
    @Environment(PersonaStore.self) private var store
    @State private var selection: Persona.ID? = "max"
    @State private var confirmReset = false

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(store.personas) { persona in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(persona.name).font(.headline)
                        Text(persona.role).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(persona.id)
                }
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)

            Group {
                if let persona = store.personas.first(where: { $0.id == selection }) {
                    PersonaEditorView(persona: persona).id(persona.id)
                } else {
                    ContentUnavailableView("Keine Persona ausgewählt", systemImage: "person.2")
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Personas")
        .toolbar {
            ToolbarItem {
                Button("Standard wiederherstellen") { confirmReset = true }
            }
        }
        .confirmationDialog("Alle Personas auf Standard zurücksetzen?", isPresented: $confirmReset) {
            Button("Zurücksetzen", role: .destructive) { store.resetToDefaults() }
        }
    }
}

struct PersonaEditorView: View {
    @Environment(PersonaStore.self) private var store
    @Environment(SystemStatusModel.self) private var status
    @Environment(AppSettings.self) private var settings
    @Environment(PreviewPlayer.self) private var preview
    @State private var draft: Persona
    @State private var showVoicePicker = false

    init(persona: Persona) {
        _draft = State(initialValue: persona)
    }

    private var effectiveProvider: SpeechProviderKind {
        SpeechRenderer.preferredProvider(for: draft, mode: settings.speechMode)
    }

    var body: some View {
        Form {
            Section("Rolle") {
                TextField("Name", text: $draft.name)
                TextField("Rolle", text: $draft.role)
                TextField("Sprechstil", text: $draft.style, axis: .vertical)
                TextField("Wissensgebiet", text: $draft.expertise)
                TextField("Beispielsatz", text: $draft.sampleLine, axis: .vertical)
            }

            Section {
                Picker("Bevorzugter Anbieter", selection: $draft.preferredProvider) {
                    ForEach(SpeechProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)

                LabeledContent("Fish-Audio-Stimme") {
                    HStack {
                        Text(draft.fishVoice?.title ?? String(localized: "Keine")).foregroundStyle(.secondary)
                        Button("Auswählen …") { showVoicePicker = true }
                    }
                }

                if appleVoiceNames.count < 3 || status.bestVoice(named: draft.appleVoiceName).map({ $0.quality < .enhanced }) ?? true {
                    HStack {
                        Label("Wenige hochwertige deutsche Apple-Stimmen installiert.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Stimmen laden …") { SystemSettingsLink.openSpokenContent() }
                            .font(.caption)
                    }
                }
                Picker("Apple-Stimme (Fallback)", selection: $draft.appleVoiceName) {
                    ForEach(appleVoiceNames, id: \.self) { name in
                        let quality = status.bestVoice(named: name)?.quality.label ?? ""
                        Text("\(name) (\(quality))").tag(name)
                    }
                }

                HStack {
                    previewButton
                    Text("Aktuell gesprochen von: \(effectiveProvider.displayName)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = preview.lastError {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
            } header: {
                Text("Stimme")
            } footer: {
                if settings.speechMode == .appleOnly {
                    Text("In den Einstellungen ist „Nur Apple-Stimmen“ aktiv – Fish Audio wird ignoriert.")
                } else {
                    Text("Fällt Fish Audio aus (kein Key, Fehler, Gratisangebot beendet), spricht automatisch die Apple-Stimme.")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: draft) { _, new in store.update(new) }
        .sheet(isPresented: $showVoicePicker) {
            FishVoicePickerSheet(selected: draft.fishVoice) { voice in
                draft.fishVoice = FishVoiceRef(id: voice.id, title: voice.title)
                draft.preferredProvider = .fish
            }
        }
        .onDisappear { preview.stop() }
    }

    private var appleVoiceNames: [String] {
        var names: [String] = []
        for voice in status.germanVoices where !names.contains(voice.baseName) { names.append(voice.baseName) }
        if !names.contains(draft.appleVoiceName) { names.insert(draft.appleVoiceName, at: 0) }
        return names
    }

    @ViewBuilder
    private var previewButton: some View {
        let key = "persona-\(draft.id)"
        if preview.loadingKey == key {
            ProgressView().controlSize(.small)
        } else if preview.playingKey == key {
            Button("Stopp") { preview.stop() }
        } else {
            Button("Probehören") {
                preview.preview(text: draft.sampleLine, persona: draft, mode: settings.speechMode, key: key,
                                pronunciations: settings.preferences.pronunciationMap)
            }
        }
    }
}

struct FishVoicePickerSheet: View {
    let selected: FishVoiceRef?
    let onSelect: (FishVoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(PreviewPlayer.self) private var preview
    @State private var query = ""
    @State private var licensedOnly = false
    @State private var voices: [FishVoice] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var choice: FishVoice.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fish-Audio-Stimme wählen").font(.title2.bold())
            HStack {
                TextField("Suche nach Titel (leer = beliebteste deutsche Stimmen)", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Toggle("Nur lizenzierte", isOn: $licensedOnly)
                Button("Suchen") { Task { await search() } }
            }
            Text("Die Bibliothek ist öffentlich und enthält auch Klone realer Personen – bitte neutrale Stimmen wählen.")
                .font(.caption).foregroundStyle(.secondary)

            List(voices, selection: $choice) { voice in
                HStack(alignment: .top) {
                    sampleButton(voice)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(voice.title).font(.headline)
                            if voice.licensed { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).help("Lizenziert") }
                            if voice.id == selected?.id { Text("aktuell").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(voice.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Text("\(voice.uses.formatted()) Nutzungen").font(.caption).foregroundStyle(.tertiary)
                }
                .tag(voice.id)
            }
            .overlay {
                if isLoading { ProgressView() }
                else if let error { ContentUnavailableView("Fehler", systemImage: "exclamationmark.triangle", description: Text(error)) }
            }

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { preview.stop(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Übernehmen") {
                    if let voice = voices.first(where: { $0.id == choice }) { onSelect(voice) }
                    preview.stop()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(choice == nil)
            }
        }
        .padding(20)
        .frame(width: 680, height: 560)
        .task { await search() }
    }

    private func sampleButton(_ voice: FishVoice) -> some View {
        Button {
            if preview.playingKey == voice.id { preview.stop() }
            else if let url = voice.sampleURL { preview.play(url: url, key: voice.id) }
        } label: {
            Image(systemName: preview.playingKey == voice.id ? "stop.circle.fill" : "play.circle.fill").font(.title2)
        }
        .buttonStyle(.borderless)
        .disabled(voice.sampleURL == nil)
        .help("Hörprobe der Bibliothek abspielen")
    }

    private func search() async {
        guard let key = KeychainStore.read(.fishAudio) else {
            error = FishAudioError.missingKey.localizedDescription
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            voices = try await FishAudioProvider(apiKey: key).searchVoices(title: query, licensed: licensedOnly)
            if voices.isEmpty { error = String(localized: "Keine Stimmen gefunden.") }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
