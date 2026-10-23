import SwiftData
import SwiftUI

struct EpisodeDetailView: View {
    @Bindable var episode: Episode
    @Environment(\.modelContext) private var context
    @Environment(ProductionService.self) private var production
    @Environment(PersonaStore.self) private var personas
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerModel.self) private var player
    @Environment(PipelineService.self) private var pipeline
    @State private var tab: Tab
    @State private var exportMessage: String?
    @State private var showFollowUp = false
    @Environment(NavigationModel.self) private var navigation

    enum Tab: Hashable { case research, listen, script }

    init(episode: Episode) {
        self.episode = episode
        let researchFirst = [.researching, .review, .scripting].contains(episode.status)
            || (episode.isResearchEpisode && episode.status == .failed && episode.segments.isEmpty)
        _tab = State(initialValue: researchFirst ? .research : .listen)
    }

    private var isRenderingThis: Bool { production.activeEpisodeID == episode.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            switch tab {
            case .research:
                ResearchView(episode: episode)
            case .listen:
                if episode.audioURL != nil, episode.status != .rendering {
                    VStack(spacing: 0) {
                        PlayerControlsView()
                            .padding(16)
                        SaveBar(episode: episode) { exportMessage = $0 }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)
                        if let quality = pipeline.dossier(for: episode)?.scriptQuality {
                            QualityBar(quality: quality)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                        }
                        FeedbackBar(episode: episode)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)
                        Divider()
                        TranscriptView(episode: episode)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Noch kein Audio", systemImage: "waveform.badge.plus")
                    } description: {
                        Text("Vertone das Skript, um die Episode zu hören.")
                    }
                }
            case .script:
                ScriptEditorView(episode: episode)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Ansicht", selection: $tab) {
                    if episode.isResearchEpisode { Text("Recherche").tag(Tab.research) }
                    Text("Hören").tag(Tab.listen)
                    Text("Skript").tag(Tab.script)
                }
                .pickerStyle(.segmented)
                .frame(width: episode.isResearchEpisode ? 270 : 180)
            }
        }
        .onAppear { player.load(episode) }
        .sheet(isPresented: $showFollowUp) { FollowUpSheet(parent: episode) }
        .onChange(of: episode.statusRaw) { _, new in
            if new == EpisodeStatus.ready.rawValue {
                player.reload(episode)
                tab = .listen
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Titel", text: $episode.title)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                StatusBadge(status: episode.status)
                Spacer()
                actions
            }
            HStack(spacing: 12) {
                Text(episode.createdAt, format: .dateTime.day().month().year())
                if let mix = episode.options?.categoryMix, !mix.isEmpty { Text(mix.label) }
                Text("\(episode.segments.count) Segmente")
                if episode.duration > 0 {
                    Text(EpisodeExporter.shortTime(episode.duration))
                } else if !episode.segments.isEmpty {
                    Text("ca. \(EpisodeExporter.shortTime(episode.estimatedDuration)) (geschätzt)")
                        .help("Aus der Wortzahl des Skripts berechnet")
                }
                if let target = episode.options?.minutes, !episode.segments.isEmpty {
                    Text("Ziel ~\(target) min")
                }
                Text(settings.resolvedAI(for: episode.options).speechMode == .appleOnly ? "Nur Apple" : "Fish Audio + Apple-Fallback")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if isRenderingThis {
                HStack {
                    ProgressView(value: production.progress)
                    Text(production.message).font(.callout).foregroundStyle(.secondary)
                        .frame(minWidth: 220, alignment: .leading)
                    if let remaining = production.remaining {
                        Text(RemainingTimeEstimator.format(remaining)).font(.callout.monospacedDigit())
                    }
                }
            }
            if let error = episode.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            if let note = episode.renderNote {
                Label(note, systemImage: "info.circle")
                    .foregroundStyle(.orange).font(.callout).textSelection(.enabled)
            }
            if let exportMessage {
                Label(exportMessage, systemImage: "icloud.and.arrow.up").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if isRenderingThis {
            Button("Abbrechen") { production.cancel() }
        } else {
            Button {
                if player.episode?.id == episode.id { player.pause() }
                production.produce(episode, personas: personas, settings: settings, context: context)
            } label: {
                Label(episode.audioURL == nil ? "Vertonen" : "Neu vertonen", systemImage: "waveform")
            }
            .buttonStyle(.borderedProminent)
            .disabled(production.isRunning || episode.segments.isEmpty || pipeline.isRunning(episode))
            .help("Nur geänderte Segmente werden neu erzeugt (Cache).")

            if episode.isResearchEpisode {
                Menu {
                    Button("Nachfrage stellen …") { showFollowUp = true }
                        .disabled(!(pipeline.dossier(for: episode)?.isComplete ?? false))
                    Menu("Tiefer eintauchen") {
                        ForEach(Array(Set(episode.segments.map(\.section))).sorted(), id: \.self) { chapter in
                            Button(chapter) {
                                if let new = pipeline.deepDive(chapter: chapter, from: episode, settings: settings, context: context) {
                                    navigation.show(new)
                                }
                            }
                        }
                    }
                    .disabled(episode.segments.isEmpty)
                } label: {
                    Label("Weiter", systemImage: "arrow.turn.down.right")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Nachfrage oder Folge-Episode")
            }

            Menu {
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([episode.audioURL ?? episode.folderURL]) }
                    .disabled(!FileManager.default.fileExists(atPath: episode.folderURL.path))
                Button("Auf iPhone verfügbar machen (iCloud Drive)") { exportToICloud() }
                    .disabled(episode.audioURL == nil || episode.status == .rendering)
                Button("Als MP3 exportieren") { exportMP3() }
                    .disabled(episode.audioURL == nil || episode.status == .rendering)
                Button("Faktencheck-Bericht öffnen") { NSWorkspace.shared.open(episode.folderURL.appending(path: "factcheck.md")) }
                    .disabled(!FileManager.default.fileExists(atPath: episode.folderURL.appending(path: "factcheck.md").path))
            } label: {
                Label("Teilen", systemImage: "square.and.arrow.up")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func exportMP3() {
        guard let m4a = episode.audioURL else { return }
        let mp3 = m4a.deletingPathExtension().appendingPathExtension("mp3")
        exportMessage = String(localized: "MP3 wird erstellt …")
        Task {
            do {
                try await AudioAssembler().exportMP3(from: m4a, to: mp3)
                exportMessage = String(localized: "MP3 gespeichert: \(mp3.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([mp3])
            } catch {
                exportMessage = String(localized: "MP3-Export fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    private func exportToICloud() {
        guard let url = episode.audioURL else { return }
        do {
            let target = try EpisodeExporter.copyToICloud(url, fileName: url.lastPathComponent)
            exportMessage = String(localized: "Kopiert nach iCloud Drive/DeepCast/\(target.lastPathComponent) – auf dem iPhone in der Dateien-App abspielbar.")
        } catch {
            exportMessage = String(localized: "iCloud-Export fehlgeschlagen: \(error.localizedDescription)")
        }
    }
}

struct PlayerControlsView: View {
    @Environment(PlayerModel.self) private var player
    @State private var scrubPosition: Double?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 18) {
                Button { player.previousChapter() } label: { Image(systemName: "backward.end.fill") }
                    .help("Vorheriges Kapitel")
                Button { player.skip(by: -PlayerModel.skipBack) } label: { Image(systemName: "gobackward.15") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38))
                }
                .keyboardShortcut(.space, modifiers: [])
                Button { player.skip(by: PlayerModel.skipForward) } label: { Image(systemName: "goforward.30") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button { player.nextChapter() } label: { Image(systemName: "forward.end.fill") }
                    .help("Nächstes Kapitel")
                Spacer()
                chapterMenu
                speedMenu
            }
            .buttonStyle(.borderless)
            .font(.title3)

            VStack(spacing: 2) {
                Slider(
                    value: Binding(
                        get: { scrubPosition ?? player.currentTime },
                        set: { scrubPosition = $0 }
                    ),
                    in: 0...max(player.duration, 1)
                ) { editing in
                    if !editing, let position = scrubPosition {
                        player.seek(to: position)
                        scrubPosition = nil
                    }
                }
                HStack {
                    Text(EpisodeExporter.shortTime(scrubPosition ?? player.currentTime))
                    Spacer()
                    if let chapter = player.currentChapter { Text(chapter.title).lineLimit(1) }
                    Spacer()
                    Text("-" + EpisodeExporter.shortTime(player.duration - (scrubPosition ?? player.currentTime)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var chapterMenu: some View {
        Menu {
            ForEach(player.chapters, id: \.self) { chapter in
                Button("\(EpisodeExporter.shortTime(chapter.start))  \(chapter.title)") { player.seek(to: chapter.start) }
            }
        } label: {
            Label("Kapitel", systemImage: "list.bullet")
        }
        .fixedSize()
        .disabled(player.chapters.isEmpty)
    }

    private var speedMenu: some View {
        @Bindable var player = player
        return Picker("Tempo", selection: $player.rate) {
            ForEach(PlayerModel.speeds, id: \.self) { speed in
                Text(speed.formatted(.number.precision(.fractionLength(1))) + "×").tag(speed)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("Wiedergabegeschwindigkeit (ohne Tonhöhenänderung)")
    }
}

struct TranscriptView: View {
    let episode: Episode
    @Environment(PlayerModel.self) private var player
    @Environment(PersonaStore.self) private var personas
    @State private var infoSegment: UUID?

    var body: some View {
        let segments = episode.sortedSegments
        let currentID = segments.first { $0.contains(time: player.currentTime) }?.id
        ScrollViewReader { proxy in
            List {
                ForEach(segments) { segment in
                    if segment.order == 0 || segments[max(0, segment.order - 1)].section != segment.section {
                        Text(segment.section).font(.headline).padding(.top, 6)
                    }
                    row(segment, isCurrent: segment.id == currentID)
                        .id(segment.id)
                }
            }
            .listStyle(.inset)
            .onChange(of: currentID) { _, id in
                guard let id, player.isPlaying else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func row(_ segment: EpisodeSegment, isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(personas.persona(id: segment.speakerID)?.name ?? segment.speakerID)
                .font(.callout.weight(.semibold))
                .frame(width: 80, alignment: .trailing)
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
            Text(segment.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isCurrent ? .primary : .secondary)
            Button { infoSegment = segment.id } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .help("Belege und Quelle")
                .popover(isPresented: Binding(get: { infoSegment == segment.id }, set: { if !$0 { infoSegment = nil } })) {
                    EvidencePopover(segment: segment)
                }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            player.seek(to: segment.startTime)
            if !player.isPlaying { player.play() }
        }
    }
}

private struct EvidencePopover: View {
    let segment: EpisodeSegment
    @Environment(PipelineService.self) private var pipeline

    var body: some View {
        let dossier = segment.episode.flatMap { pipeline.dossier(for: $0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Belege").font(.headline)
                if segment.claimIDs.isEmpty {
                    Text(dossier == nil
                         ? "Keine Belege verknüpft – dieses Segment stammt aus einem manuellen Skript."
                         : "Dieser Beitrag enthält keine Tatsachenbehauptung (Frage, Überleitung oder Meinung).")
                        .foregroundStyle(.secondary)
                }
                ForEach(segment.claimIDs, id: \.self) { id in
                    if let claim = dossier?.claim(id) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(claim.effectiveLight.emoji) \(claim.text)").fontWeight(.medium)
                            ForEach(claim.evidence, id: \.self) { evidence in
                                if let source = dossier?.source(evidence.sourceID) {
                                    Text("„\(evidence.quote)“").italic().font(.callout)
                                    Link("\(source.title) · \(source.publisher) · Stufe \(source.tier.rawValue)", destination: source.url)
                                        .font(.caption)
                                }
                            }
                        }
                        Divider()
                    } else {
                        Text(id).foregroundStyle(.secondary)
                    }
                }
                Text("\(EpisodeExporter.shortTime(segment.startTime)) · \(segment.renderedProvider.flatMap(SpeechProviderKind.init)?.displayName ?? "–")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .frame(width: 380)
        .frame(maxHeight: 420)
    }
}

/// Asks a follow-up question that is answered from the existing dossier (no new research).
struct FollowUpSheet: View {
    let parent: Episode
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(PipelineService.self) private var pipeline
    @Environment(PersonaStore.self) private var personas
    @Environment(AppSettings.self) private var settings
    @Environment(ProductionService.self) private var production
    @Environment(NavigationModel.self) private var navigation
    @State private var question = ""
    @State private var minutes = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nachfrage stellen").font(.title2.bold())
            Text("Die Antwort entsteht nur aus den bereits geprüften Aussagen von „\(parent.title)“ – ohne neue Recherche. Steht etwas nicht in der Mappe, sagen die Sprecher das.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Deine Frage", text: $question, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
            Stepper("Länge: \(minutes) min", value: $minutes, in: 2...8)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Antwort-Episode erstellen") {
                    let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let episode = pipeline.askFollowUp(text, minutes: minutes, from: parent, personas: personas, settings: settings,
                                                          production: production, context: context) {
                        navigation.show(episode)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).count < 5)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// Save buttons below the player: audio, transcript, everything.
private struct SaveBar: View {
    let episode: Episode
    let report: (String) -> Void
    @State private var isSaving = false

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("M4A (mit Kapiteln)") { saveAudio(.m4a) }
                Button("MP3 (mit Kapiteln)") { saveAudio(.mp3) }
            } label: {
                Label("Audio speichern …", systemImage: "square.and.arrow.down")
            }
            .fixedSize()
            Menu {
                ForEach(EpisodeSaver.TranscriptFormat.allCases, id: \.self) { format in
                    Button(format.label) { saveTranscript(format) }
                }
            } label: {
                Label("Transkript speichern …", systemImage: "doc.text")
            }
            .fixedSize()
            Button {
                run { try await EpisodeSaver.saveAll(episode) }
            } label: {
                Label("Alles speichern …", systemImage: "folder.badge.plus")
            }
            if isSaving { ProgressView().controlSize(.small) }
            Spacer()
        }
        .disabled(isSaving)
    }

    private func saveAudio(_ format: EpisodeSaver.AudioFormat) {
        run { try await EpisodeSaver.saveAudio(episode, format: format) }
    }

    private func saveTranscript(_ format: EpisodeSaver.TranscriptFormat) {
        run { try EpisodeSaver.saveTranscript(episode, format: format) }
    }

    private func run(_ action: @escaping @MainActor () async throws -> URL?) {
        isSaving = true
        Task {
            do {
                if let url = try await action() {
                    report(String(localized: "Gespeichert: \(url.path)"))
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                report(String(localized: "Speichern fehlgeschlagen: \(error.localizedDescription)"))
            }
            isSaving = false
        }
    }
}

/// Measured script quality and test-listener verdict.
struct QualityBar: View {
    let quality: ScriptQualityReport
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                if let verdict = quality.verdict { Text(verdict).font(.callout) }
                if let clarity = quality.clarity, let structure = quality.structure, let naturalness = quality.naturalness {
                    Text("Verständlichkeit \(clarity)/10 · Roter Faden \(structure)/10 · Natürlichkeit \(naturalness)/10\(quality.revised ? " · überarbeitet" : "")")
                        .font(.caption)
                }
                ForEach(quality.problems + quality.reviewIssues.prefix(5), id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        } label: {
            Label("Skript-Qualität (\(quality.format.label)): \(quality.summary)", systemImage: "chart.bar.doc.horizontal")
                .font(.callout)
        }
    }
}

/// "Rückmeldung zur Folge → in den Leitfaden übernehmen".
struct FeedbackBar: View {
    let episode: Episode
    @Environment(PipelineService.self) private var pipeline
    @Environment(AppSettings.self) private var settings
    @State private var feedback = ""
    @State private var proposed: [String] = []
    @State private var isWorking = false
    @State private var showSheet = false
    @State private var saved = false

    var body: some View {
        HStack(alignment: .top) {
            TextField("Rückmeldung zur Folge – was hat dir nicht gefallen?", text: $feedback, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            Button(isWorking ? "Formuliere …" : "In den Leitfaden übernehmen …") {
                isWorking = true
                Task {
                    proposed = await pipeline.proposeGuideRules(feedback: feedback, episode: episode, settings: settings)
                    isWorking = false
                    showSheet = !proposed.isEmpty
                }
            }
            .disabled(isWorking || feedback.trimmingCharacters(in: .whitespaces).count < 5)
            if saved { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Im Leitfaden gespeichert") }
        }
        .sheet(isPresented: $showSheet) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Neue Regeln für den Leitfaden").font(.title3.bold())
                Text("Prüfe und bearbeite die Regeln. Sie gelten für alle künftigen Folgen.").font(.callout).foregroundStyle(.secondary)
                ForEach(proposed.indices, id: \.self) { index in
                    HStack {
                        TextField("Regel", text: $proposed[index], axis: .vertical).textFieldStyle(.roundedBorder)
                        Button(role: .destructive) { proposed.remove(at: index) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Spacer()
                    Button("Abbrechen", role: .cancel) { showSheet = false }.keyboardShortcut(.cancelAction)
                    Button("Übernehmen") {
                        settings.styleGuide.appendRules(proposed, episodeTitle: episode.title)
                        feedback = ""
                        saved = true
                        showSheet = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(proposed.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                }
            }
            .padding(20)
            .frame(width: 520)
        }
    }
}
