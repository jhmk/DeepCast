import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(PlayerModel.self) private var player
    @Query(sort: \Episode.createdAt, order: .reverse) private var episodes: [Episode]
    @Environment(NavigationModel.self) private var navigation
    @State private var showNewScript = false
    @State private var searchText = ""

    private var filtered: [Episode] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return episodes }
        return episodes.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.topic.localizedCaseInsensitiveContains(query) }
    }
    @State private var episodeToDelete: Episode?

    var body: some View {
        @Bindable var navigation = navigation
        HSplitView {
            List(selection: $navigation.episodeID) {
                ForEach(filtered) { episode in
                    EpisodeRow(episode: episode).tag(episode.id)
                        .contextMenu {
                            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([episode.folderURL]) }
                            Divider()
                            Button("Löschen …", role: .destructive) { episodeToDelete = episode }
                        }
                }
            }
            .frame(minWidth: 230, idealWidth: 270, maxWidth: 360)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Episoden suchen")
            .overlay {
                if episodes.isEmpty {
                    ContentUnavailableView {
                        Label("Noch keine Episoden", systemImage: "waveform")
                    } description: {
                        Text("Starte eine Recherche zu einem Thema oder lege ein eigenes Skript an.")
                    } actions: {
                        Button("Neue Episode …") { navigation.sidebar = .newEpisode }
                        Button("Eigenes Skript …") { showNewScript = true }
                    }
                }
            }

            Group {
                if let episode = episodes.first(where: { $0.id == navigation.episodeID }) {
                    EpisodeDetailView(episode: episode)
                        .id(episode.id)
                } else {
                    ContentUnavailableView("Keine Episode ausgewählt", systemImage: "books.vertical")
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Bibliothek")
        .toolbar {
            ToolbarItem {
                Button { showNewScript = true } label: { Label("Neues Skript", systemImage: "square.and.pencil") }
                    .help("Episode aus eigenem Skript anlegen")
            }
        }
        .sheet(isPresented: $showNewScript) {
            NewScriptSheet { episode in navigation.episodeID = episode.id }
        }
        .confirmationDialog(
            "Episode löschen?",
            isPresented: Binding(get: { episodeToDelete != nil }, set: { if !$0 { episodeToDelete = nil } }),
            presenting: episodeToDelete
        ) { episode in
            Button("Episode und Dateien löschen", role: .destructive) { delete(episode) }
        } message: { episode in
            Text("„\(episode.title)“ wird inklusive Audio und Transkript gelöscht.")
        }
    }

    private func delete(_ episode: Episode) {
        if player.episode?.id == episode.id { player.unload() }
        try? FileManager.default.removeItem(at: episode.folderURL)
        if navigation.episodeID == episode.id { navigation.episodeID = nil }
        context.delete(episode)
        try? context.save()
    }
}

private struct EpisodeRow: View {
    let episode: Episode

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(episode.title).font(.headline).lineLimit(2)
            HStack(spacing: 6) {
                Text(episode.createdAt, format: .dateTime.day().month().year())
                if episode.duration > 0 {
                    Text("·")
                    Text(EpisodeExporter.shortTime(episode.duration))
                }
                Spacer()
                StatusBadge(status: episode.status)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct StatusBadge: View {
    let status: EpisodeStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .ready: .green
        case .rendering, .researching, .scripting: .blue
        case .review: .purple
        case .needsRender, .draft: .orange
        case .failed: .red
        }
    }
}

struct NewScriptSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(PersonaStore.self) private var personas
    @State private var title = "Bärtierchen – Test der Sprachausgabe"
    @State private var script = ScriptParser.exampleScript
    let onCreate: (Episode) -> Void

    private var parsed: ParsedScript { ScriptParser.parse(script, personas: personas.personas) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Neues Skript").font(.title2.bold())
            TextField("Titel", text: $title)
                .textFieldStyle(.roundedBorder)
            Text("Format: „## Kapitel“ als Überschrift, „Name: Text“ pro Wortbeitrag. Namen: \(personas.personas.map(\.name).joined(separator: ", ")).")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $script)
                .font(.body.monospaced())
                .frame(minHeight: 280)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Text("\(parsed.segments.count) Segmente")
                if !parsed.unknownSpeakers.isEmpty {
                    Label("Unbekannt: \(parsed.unknownSpeakers.joined(separator: ", ")) → \(personas.personas.first?.name ?? "")",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Anlegen") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || parsed.segments.isEmpty)
            }
            .font(.callout)
        }
        .padding(20)
        .frame(width: 680, height: 520)
    }

    private func create() {
        let episode = Episode(title: title.trimmingCharacters(in: .whitespaces), topic: title)
        context.insert(episode)
        for (index, segment) in parsed.segments.enumerated() {
            let model = EpisodeSegment(order: index, speakerID: segment.speakerID, text: segment.text, section: segment.section)
            model.episode = episode
            context.insert(model)
        }
        try? context.save()
        onCreate(episode)
        dismiss()
    }
}
