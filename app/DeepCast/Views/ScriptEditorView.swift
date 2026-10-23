import SwiftData
import SwiftUI

struct ScriptEditorView: View {
    @Bindable var episode: Episode
    @Environment(\.modelContext) private var context
    @Environment(PersonaStore.self) private var personas
    @Environment(PipelineService.self) private var pipeline

    var body: some View {
        let segments = episode.sortedSegments
        let usable = pipeline.usableClaims(for: episode)
        let issueCount = usable.map { claims in
            segments.filter { !ScriptChecker.problems(text: $0.text, claimIDs: $0.claimIDs, usable: claims).isEmpty }.count
        } ?? 0
        List {
            if let quality = pipeline.dossier(for: episode)?.scriptQuality { QualityBar(quality: quality) }
            if issueCount > 0 {
                Label("\(issueCount) Segmente mit Prüf-Hinweisen – bitte korrigieren oder mit KI neu schreiben.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ForEach(segments) { segment in
                SegmentEditorRow(segment: segment, episode: episode, usable: usable) { episode.markEdited() } onDelete: {
                    delete(segment)
                }
            }
            .onMove(perform: move)
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { addSegment(after: segments.last) } label: { Label("Segment hinzufügen", systemImage: "plus") }
                Spacer()
                Text("ca. \(EpisodeExporter.shortTime(episode.estimatedDuration))\(episode.options.map { " · Ziel ~\($0.minutes) min" } ?? "")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("Ziehen zum Umsortieren · Änderungen markieren die Episode zum Neu-Vertonen")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.bar)
        }
    }

    private func addSegment(after last: EpisodeSegment?) {
        let speaker = personas.personas.first { $0.id != last?.speakerID }?.id ?? personas.personas.first?.id ?? "max"
        let segment = EpisodeSegment(
            order: (last?.order ?? -1) + 1, speakerID: speaker, text: "", section: last?.section ?? ScriptParser.defaultSection
        )
        segment.episode = episode
        context.insert(segment)
        episode.markEdited()
    }

    private func delete(_ segment: EpisodeSegment) {
        context.delete(segment)
        episode.renumberSegments()
        episode.markEdited()
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = episode.sortedSegments
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, segment) in ordered.enumerated() { segment.order = index }
        episode.markEdited()
    }
}

private struct SegmentEditorRow: View {
    @Bindable var segment: EpisodeSegment
    let episode: Episode
    /// Usable claims of a research episode; nil for manual scripts (no fact check).
    let usable: [Claim]?
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(PersonaStore.self) private var personas
    @Environment(AppSettings.self) private var settings
    @Environment(PreviewPlayer.self) private var preview
    @Environment(PipelineService.self) private var pipeline
    @State private var showRewrite = false
    @State private var instruction = ""

    private var problems: [String] {
        guard let usable else { return [] }
        return ScriptChecker.problems(text: segment.text, claimIDs: segment.claimIDs, usable: usable)
    }

    private var key: String { segment.id.uuidString }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Sprecher", selection: $segment.speakerID) {
                    ForEach(personas.personas) { persona in Text(persona.name).tag(persona.id) }
                }
                .labelsHidden()
                .frame(width: 130)
                TextField("Kapitel", text: $segment.section)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 130)
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("Text", text: $segment.text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...8)
                    .disabled(pipeline.rewriting.contains(segment.id))
                if let usable {
                    evidenceRow(usable)
                }
                ForEach(problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                if let error = pipeline.rewriteErrors[segment.id] {
                    Label(error, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                }
            }
            VStack(spacing: 6) {
                previewButton
                if usable != nil {
                    if pipeline.rewriting.contains(segment.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { showRewrite = true } label: { Image(systemName: "sparkles") }
                            .buttonStyle(.borderless)
                            .help("Mit KI neu schreiben (nur belegte Aussagen)")
                            .popover(isPresented: $showRewrite) { rewritePopover }
                    }
                }
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Segment löschen")
            }
        }
        .padding(.vertical, 4)
        .onChange(of: segment.text) { onEdit() }
        .onChange(of: segment.speakerID) { onEdit() }
        .onChange(of: segment.section) { onEdit() }
        .onChange(of: segment.claimIDs) { onEdit() }
    }

    private func evidenceRow(_ usable: [Claim]) -> some View {
        HStack(spacing: 4) {
            ForEach(segment.claimIDs, id: \.self) { id in
                let claim = usable.first { $0.id == id }
                Chip(text: "\(claim?.effectiveLight.emoji ?? "⚠️") \(id)", tint: claim == nil ? .red : .secondary)
                    .help(claim?.text ?? "Nicht verwendbar")
            }
            Menu {
                ForEach(usable) { claim in
                    Toggle("\(claim.effectiveLight.emoji) \(claim.id): \(String(claim.text.prefix(80)))", isOn: Binding(
                        get: { segment.claimIDs.contains(claim.id) },
                        set: { isOn in
                            if isOn { segment.claimIDs.append(claim.id) } else { segment.claimIDs.removeAll { $0 == claim.id } }
                            onEdit()
                        }))
                }
            } label: {
                Text(segment.claimIDs.isEmpty ? "Beleg zuordnen" : "Belege")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
        }
    }

    private var rewritePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Segment mit KI neu schreiben").font(.headline)
            Text("Es werden nur belegte Aussagen verwendet. Optional: Was soll anders werden?")
                .font(.caption).foregroundStyle(.secondary)
            TextField("z.B. kürzer, lockerer, als Frage …", text: $instruction, axis: .vertical)
                .lineLimit(1...3)
            HStack {
                Spacer()
                Button("Abbrechen") { showRewrite = false }
                Button("Neu schreiben") {
                    let wish = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
                    let reasons = problems + (wish.isEmpty ? [] : ["Wunsch: \(wish)"])
                    pipeline.rewrite(segment, in: episode,
                                     instruction: reasons.isEmpty ? "Natürlicher und lebendiger formulieren, gleicher Inhalt." : reasons.joined(separator: " "),
                                     personas: personas, settings: settings, context: context)
                    instruction = ""
                    showRewrite = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 340)
    }

    @ViewBuilder
    private var previewButton: some View {
        if preview.loadingKey == key {
            ProgressView().controlSize(.small)
        } else if preview.playingKey == key {
            Button { preview.stop() } label: { Image(systemName: "stop.fill") }
                .buttonStyle(.borderless)
        } else {
            Button {
                guard let persona = personas.persona(id: segment.speakerID) else { return }
                preview.preview(text: segment.text, persona: persona, mode: settings.speechMode, key: key,
                                pronunciations: settings.preferences.pronunciationMap)
            } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .help("Segment probehören")
                .disabled(segment.text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
