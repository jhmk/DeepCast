import SwiftData
import SwiftUI

struct SettingsView: View {
    /// true inside the main window (sidebar), false in the separate ⌘, window.
    var embedded = false

    var body: some View {
        TabView {
            ModelSettingsView()
                .tabItem { Label("KI", systemImage: "brain") }
            SourceSettingsView()
                .tabItem { Label("Quellen", systemImage: "books.vertical") }
            StyleGuideSettingsView()
                .tabItem { Label("Leitfaden", systemImage: "text.book.closed") }
            SpeechSettingsView()
                .tabItem { Label("Stimmen", systemImage: "waveform") }
            PronunciationSettingsView()
                .tabItem { Label("Aussprache", systemImage: "character.bubble") }
            StorageSettingsView()
                .tabItem { Label("Speicher", systemImage: "internaldrive") }
            APIKeysSettingsView()
                .tabItem { Label("API-Keys", systemImage: "key") }
        }
        .frame(minWidth: 640, idealWidth: 640, maxWidth: embedded ? .infinity : 640,
               minHeight: 480, idealHeight: 480, maxHeight: embedded ? .infinity : 480)
        .padding(embedded ? 12 : 0)
    }
}

private struct ModelSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var isRefreshing = false
    @State private var refreshMessage: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                AIChoiceEditor(choice: Binding(
                    get: { settings.resolvedAI(for: nil) },
                    set: { choice in
                        settings.llmMode = choice.llmMode
                        settings.researcher = choice.research
                        settings.writer = choice.script
                        settings.useSeparateVerifier = choice.verifier != nil
                        if let verifier = choice.verifier { settings.verifier = verifier }
                        settings.speechMode = choice.speechMode
                    }))
                HStack {
                    Button(isRefreshing ? "Lädt …" : "Liste aktualisieren") { refresh() }
                        .disabled(isRefreshing)
                    if let refreshMessage { Text(refreshMessage).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Standard") { settings.resetModels() }
                }
            } header: {
                Text("Welche KI macht was (Standard für neue Folgen)")
            } footer: {
                Text("Nur kostenlose Modelle: OpenRouter „:free“ (max. 50 Anfragen/Tag) und Google AI Studio (Gratis-Kontingent). Fällt ein Modell aus, übernimmt Qwen (OpenRouter), dann Gemini Flash-Lite (Google), dann Apple Intelligence. Pro Folge in „Neue Episode“ änderbar. Gratis-Anfragen können beim Anbieter gespeichert und zum Training genutzt werden.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func modelPicker(_ title: LocalizedStringKey, selection: Binding<ModelRef>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ModelProvider.allCases, id: \.self) { provider in
                let models = settings.pickerModels(including: selection.wrappedValue).filter { $0.provider == provider }
                if !models.isEmpty {
                    Section(provider.label + (settings.hasKey(for: provider) ? "" : " – kein Key")) {
                        ForEach(models) { model in Text(model.displayName).tag(model) }
                    }
                }
            }
        }
    }

    private func refresh() {
        isRefreshing = true
        refreshMessage = nil
        Task {
            let count = await settings.refreshModelList()
            refreshMessage = count == 0 ? String(localized: "Keine Liste erhalten (offline?)") : String(localized: "\(count) Gratis-Modelle gefunden")
            isRefreshing = false
        }
    }
}

private struct SourceSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var newDomain = ""
    @State private var newAction: DomainAction = .block

    var body: some View {
        let preferences = settings.preferences
        Form {
            Section("Standard-Quellen für neue Episoden") {
                ForEach(SourceKind.selectable) { kind in
                    Toggle(kind.label, isOn: Binding(
                        get: { preferences.defaultSources.contains(kind) },
                        set: { isOn in
                            if isOn { preferences.defaultSources.insert(kind) }
                            else if preferences.defaultSources.count > 1 { preferences.defaultSources.remove(kind) }
                        }))
                }
            }
            PaywallSettingsSection()

            Section {
                ForEach(preferences.domainRules) { rule in
                    HStack {
                        Text(rule.domain).font(.body.monospaced())
                        Spacer()
                        Picker("", selection: Binding(
                            get: { rule.action },
                            set: { action in
                                if let index = preferences.domainRules.firstIndex(where: { $0.id == rule.id }) {
                                    preferences.domainRules[index].action = action
                                }
                            })) {
                            ForEach(DomainAction.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button(role: .destructive) {
                            preferences.domainRules.removeAll { $0.id == rule.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Domain, z.B. beispiel.de", text: $newDomain)
                        .onSubmit(add)
                    Picker("", selection: $newAction) {
                        ForEach(DomainAction.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Hinzufügen", action: add)
                        .disabled(DomainRules.normalize(newDomain).isEmpty)
                }
            } header: {
                Text("Domain-Liste")
            } footer: {
                Text("Gilt für Web-Quellen. „Vertrauen“ hebt eine Seite mindestens auf Stufe B, „Abwerten“ senkt sie um eine Stufe, „Sperren“ schließt sie aus. Subdomains sind eingeschlossen.")
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        settings.preferences.addRule(domain: newDomain, action: newAction)
        newDomain = ""
    }
}

private struct PronunciationSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PreviewPlayer.self) private var preview
    @Environment(PersonaStore.self) private var personas
    @State private var written = ""
    @State private var spoken = ""

    var body: some View {
        let preferences = settings.preferences
        Form {
            Section {
                ForEach(preferences.pronunciations) { entry in
                    HStack {
                        Text(entry.written).font(.body.monospaced()).frame(width: 160, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("gesprochen", text: Binding(
                            get: { entry.spoken },
                            set: { value in
                                if let index = preferences.pronunciations.firstIndex(where: { $0.id == entry.id }) {
                                    preferences.pronunciations[index].spoken = value
                                }
                            }))
                        Button { listen(entry.written) } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.borderless)
                            .help("Probehören mit der ersten Persona")
                        Button(role: .destructive) {
                            preferences.pronunciations.removeAll { $0.id == entry.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Geschrieben, z.B. NASA", text: $written)
                    TextField("Gesprochen, z.B. Nasa", text: $spoken)
                        .onSubmit(add)
                    Button("Hinzufügen", action: add)
                        .disabled(written.trimmingCharacters(in: .whitespaces).isEmpty || spoken.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Aussprache-Wörterbuch")
            } footer: {
                Text("Ersetzt ganze Wörter vor der Sprachausgabe (Groß-/Kleinschreibung beachten). Transkript und Shownotes behalten die geschriebene Form. Geänderte Segmente werden beim nächsten Vertonen neu erzeugt.")
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        settings.preferences.pronunciations.append(PronunciationEntry(
            written: written.trimmingCharacters(in: .whitespaces), spoken: spoken.trimmingCharacters(in: .whitespaces)))
        written = ""
        spoken = ""
    }

    private func listen(_ word: String) {
        guard let persona = personas.personas.first else { return }
        preview.preview(text: "Das Wort lautet: \(word).", persona: persona, mode: settings.speechMode,
                        key: "pron-\(word)", pronunciations: settings.preferences.pronunciationMap)
    }
}

private struct SpeechSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Sprachausgabe", selection: $settings.speechMode) {
                ForEach(SpeechMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Picker("Klang", selection: $settings.soundProfile) {
                ForEach(SoundProfile.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Natürlicher Dialog (Fish: Kapitel am Stück vertonen)", isOn: $settings.naturalDialog)
                .disabled(settings.speechMode != .fishWithAppleFallback)
            Text("Sprecherwechsel und Betonung klingen natürlicher. Die Satz-Zeitpunkte im Transkript werden dann geschätzt. Fällt Fish aus, wird Satz für Satz vertont.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Fish Audio (s2.1-pro-free) ist laut Anbieter bis 30.11.2026 kostenlos. Texte gehen an Fish Audio und dürfen dort zur Modellverbesserung genutzt werden. Die Stimme pro Persona stellst du unter „Personas“ ein.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }
}

private struct APIKeysSettingsView: View {
    @State private var storage = KeychainStore.storage
    @State private var storageError: String?
    @State private var reloadToken = UUID()

    var body: some View {
        Form {
            Section {
                ForEach(KeychainStore.Account.allCases, id: \.self) { account in
                    KeyRow(account: account).id("\(account.rawValue)-\(reloadToken)")
                }
            } header: {
                Text("API-Keys")
            }
            Section {
                Picker("Speicherort", selection: Binding(
                    get: { storage },
                    set: { new in
                        do {
                            try KeychainStore.setStorage(new)
                            storage = new
                            storageError = nil
                            reloadToken = UUID()
                        } catch {
                            storageError = error.localizedDescription
                        }
                    })) {
                    ForEach(KeychainStore.Storage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if let storageError { Text(storageError).font(.caption).foregroundStyle(.red) }
            } footer: {
                Text(storage == .keychain
                     ? "Keys liegen verschlüsselt im Schlüsselbund. Falls macOS fragt: „Immer erlauben“."
                     : "Keys liegen unverschlüsselt in ~/Library/Application Support/DeepCast/keys.json (nur für deinen Benutzer lesbar, landet aber in Backups). Beim Umschalten werden vorhandene Keys automatisch übertragen.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeyRow: View {
    let account: KeychainStore.Account
    @State private var isStored = false
    @State private var newValue = ""
    @State private var error: String?
    @State private var testResult: (ok: Bool, text: String)?
    @State private var isTesting = false

    var body: some View {
        LabeledContent(account.displayName) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SecureField(isStored ? "Gespeichert – neuen Key eingeben zum Ersetzen" : "Key eingeben", text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("Sichern") { save() }.disabled(newValue.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(isTesting ? "Teste …" : "Testen") { test() }
                        .disabled(isTesting || (!isStored && newValue.trimmingCharacters(in: .whitespaces).isEmpty))
                    if isStored {
                        Button("Entfernen", role: .destructive) { remove() }
                    }
                }
                HStack(spacing: 12) {
                    Label(isStored ? "Gespeichert" : "Nicht gesetzt", systemImage: isStored ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isStored ? .green : .secondary)
                    Link("Key erstellen ↗", destination: account.createURL)
                    if let testResult {
                        Label(testResult.text, systemImage: testResult.ok ? "checkmark.seal.fill" : "xmark.octagon.fill")
                            .foregroundStyle(testResult.ok ? .green : .red)
                    }
                }
                .font(.caption)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
        .onAppear { isStored = KeychainStore.read(account) != nil }
    }

    private func save() {
        guard !newValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try KeychainStore.save(newValue, for: account)
            newValue = ""
            isStored = true
            error = nil
            testResult = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func test() {
        let typed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = typed.isEmpty ? KeychainStore.read(account) : typed else { return }
        isTesting = true
        testResult = nil
        Task {
            switch await KeychainStore.test(value, for: account) {
            case .success(let text): testResult = (true, text)
            case .failure(let error): testResult = (false, error.localizedDescription)
            }
            isTesting = false
        }
    }

    private func remove() {
        do {
            try KeychainStore.delete(account)
            isStored = false
            testResult = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Paywall fallback (opt-in): archive.is + Waterfox with Bypass Paywalls Clean.
private struct PaywallSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @State private var testURL = ""
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var setupError: String?

    var body: some View {
        @Bindable var settings = settings
        let config = settings.paywallConfig
        Section {
            Toggle("Paywall-Artikel lesen (Ausweichweg)", isOn: $settings.paywallEnabled)
            if settings.paywallEnabled {
                Toggle("1. Archiv-Schnappschuss (archive.is) verwenden", isOn: $settings.paywallUseArchive)
                Toggle("2. Waterfox mit Bypass Paywalls Clean verwenden", isOn: $settings.paywallUseWaterfox)
                if settings.paywallUseWaterfox {
                    TextField("Waterfox-Programm", text: $settings.waterfoxBinary).font(.caption.monospaced())
                    TextField("DeepCast-Profil", text: $settings.waterfoxProfile).font(.caption.monospaced())
                    statusRow("Waterfox", FileManager.default.isExecutableFile(atPath: config.waterfoxBinary))
                    statusRow("geckodriver", FileManager.default.isExecutableFile(atPath: config.geckodriver))
                    statusRow("DeepCast-Profil", config.waterfoxReady)
                    statusRow("Bypass Paywalls Clean im Profil", config.extensionInstalled)
                    HStack {
                        Button("Profil einrichten …") {
                            do { try WaterfoxSession.openProfileForSetup(config); setupError = nil }
                            catch { setupError = error.localizedDescription }
                        }
                        if let setupError { Text(setupError).font(.caption).foregroundStyle(.red) }
                    }
                    Text("""
                    Einmalig: „Profil einrichten“ öffnet ein eigenes Waterfox-Fenster (dein normales Waterfox läuft weiter) mit der Download-Seite der Erweiterung. Dort die neueste .xpi installieren, dann in den Erweiterungs-Einstellungen von Bypass Paywalls Clean unter „opt-in“ das Laden von Inhalten externer Seiten erlauben (fetch). Danach dieses Waterfox-Fenster schließen. DeepCast nutzt das Profil anschließend unsichtbar im Hintergrund.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    TextField("Test-URL eines Paywall-Artikels", text: $testURL)
                    Button(isTesting ? "Teste …" : "Selbsttest") { runTest() }
                        .disabled(isTesting || URL(string: testURL)?.host() == nil)
                }
                if let testResult { Text(testResult).font(.caption).textSelection(.enabled) }
            }
        } header: {
            Text("Paywall-Abruf")
        } footer: {
            Text("Greift nur, wenn eine Seite hinter einer Paywall liegt (max. \(config.maxArticles) Artikel pro Folge). Nur für den privaten Gebrauch – rechtliche Grauzone. Volltexte bleiben lokal; Shownotes und Bericht enthalten nur Link und kurze Belegstellen.")
        }
    }

    private func statusRow(_ title: String, _ ok: Bool) -> some View {
        Label(title, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(ok ? .green : .secondary)
            .font(.caption)
    }

    private func runTest() {
        guard let url = URL(string: testURL.trimmingCharacters(in: .whitespaces)) else { return }
        isTesting = true
        testResult = nil
        let config = settings.paywallConfig
        Task {
            let normal = (try? await WebPageFetcher().fetch(url))?.extracted.text.split(whereSeparator: \.isWhitespace).count ?? 0
            let results = await PaywallFetcher(config: config).fetch([url]) { _ in }
            switch results.first?.1 {
            case .success(let fetched):
                let words = fetched.page.extracted.text.split(whereSeparator: \.isWhitespace).count
                testResult = "✅ \(fetched.method): \(words) Wörter (normaler Abruf: \(normal))"
            case .failure(let error):
                testResult = "❌ \(error.localizedDescription) (normaler Abruf: \(normal) Wörter)"
            case nil:
                testResult = "❌ Kein Weg aktiv oder Waterfox-Profil nicht eingerichtet."
            }
            isTesting = false
        }
    }
}

private struct StorageSettingsView: View {
    @Query private var episodes: [Episode]
    @State private var usage = StorageManager.Usage()
    @State private var message: String?

    private var finishedFolders: [URL] { episodes.filter { $0.status == .ready }.map(\.folderURL) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Episoden (~/Music/DeepCast)", value: StorageManager.format(usage.episodes))
                LabeledContent("Sprach-Zwischenspeicher", value: StorageManager.format(usage.speechCache))
                LabeledContent("Zwischenstände fertiger Folgen", value: StorageManager.format(usage.intermediates))
            } footer: {
                Text("Der Sprach-Zwischenspeicher wird automatisch auf \(StorageManager.format(StorageManager.speechCacheLimit)) begrenzt (älteste zuerst). Gelöscht wird nie: Audio, Transkript, Shownotes, Faktencheck und Belege (dossier.json).")
            }
            Section {
                Button("Sprach-Zwischenspeicher leeren") {
                    let freed = StorageManager.clearSpeechCache()
                    message = String(localized: "\(StorageManager.format(freed)) freigegeben. Folgen werden beim nächsten Vertonen neu erzeugt.")
                    refresh()
                }
                Button("Zwischenstände fertiger Folgen löschen (\(finishedFolders.count))") {
                    let freed = StorageManager.clearIntermediates(in: finishedFolders)
                    message = String(localized: "\(StorageManager.format(freed)) freigegeben.")
                    refresh()
                }
                .disabled(finishedFolders.isEmpty)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task { refresh() }
    }

    private func refresh() {
        let folders = finishedFolders
        Task.detached {
            let result = StorageManager.usage(finishedFolders: folders)
            await MainActor.run { usage = result }
        }
    }
}

/// Editable podcast style guide (sent to the AI for plan, script, review and revision).
private struct StyleGuideSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var draft = ""
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wie DeepCast-Folgen klingen sollen. Die KI bekommt diesen Text bei Erzählplan, Skript, Überarbeitung und Testhörer-Bewertung. Faktenregeln bleiben davon unberührt.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $draft)
                .font(.body.monospaced())
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([settings.styleGuide.fileURL]) }
                Button("Standard wiederherstellen …") { confirmReset = true }
                Spacer()
                Button("Sichern") { settings.styleGuide.update(draft) }
                    .keyboardShortcut("s")
                    .disabled(draft == settings.styleGuide.text)
            }
        }
        .padding(16)
        .onAppear { draft = settings.styleGuide.text }
        .onChange(of: settings.styleGuide.text) { _, new in draft = new }
        .confirmationDialog("Leitfaden auf Standard zurücksetzen? Eigene Regeln gehen verloren.", isPresented: $confirmReset) {
            Button("Zurücksetzen", role: .destructive) { settings.styleGuide.resetToDefault() }
        }
    }
}
