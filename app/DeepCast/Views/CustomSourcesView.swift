import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// List of own sources with URL field, file picker and drag & drop (Finder files, Safari links).
struct CustomSourceEditor: View {
    @Binding var sources: [CustomSource]
    @State private var input = ""
    @State private var showImporter = false
    @State private var error: String?
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($sources) { $source in
                HStack {
                    Image(systemName: source.isFile ? "doc" : "link").foregroundStyle(.secondary)
                    Text(source.displayName).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Picker("Stufe", selection: $source.tier) {
                        ForEach(TrustTier.allCases, id: \.self) { Text("Stufe \($0.rawValue)").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Vertrauensstufe dieser Quelle")
                    Button(role: .destructive) { sources.removeAll { $0.id == source.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("URL oder Dateipfad – oder hierher ziehen", text: $input)
                    .onSubmit(addInput)
                Button("Hinzufügen", action: addInput).disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Dateien …") { showImporter = true }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(6)
        .background(isTargeted ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return !urls.isEmpty
        } isTargeted: { isTargeted = $0 }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: CustomSource.fileTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
    }

    private func addInput() {
        guard let source = CustomSource.parse(input) else {
            error = String(localized: "Keine gültige http(s)-Adresse oder vorhandene Datei.")
            return
        }
        append(source)
        input = ""
    }

    private func add(_ urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                append(CustomSource(location: url.path))
            } else if let source = CustomSource.parse(url.absoluteString) {
                append(source)
            }
        }
    }

    private func append(_ source: CustomSource) {
        error = nil
        guard !sources.contains(where: { $0.location == source.location }) else { return }
        sources.append(source)
    }
}

/// Adds own sources to a finished research (review step).
struct AddCustomSourceSheet: View {
    let episode: Episode
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(PipelineService.self) private var pipeline
    @Environment(AppSettings.self) private var settings
    @State private var sources: [CustomSource] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Eigene Quelle hinzufügen").font(.title2.bold())
            Text("Die Quelle wird gelesen, Aussagen werden herausgezogen und geprüft. Die übrige Recherche bleibt erhalten.")
                .font(.callout).foregroundStyle(.secondary)
            CustomSourceEditor(sources: $sources)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Hinzufügen und prüfen") {
                    if let source = sources.first {
                        pipeline.addCustomSource(source, to: episode, settings: settings, context: context)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sources.count != 1)
            }
            if sources.count > 1 { Text("Bitte eine Quelle nach der anderen hinzufügen.").font(.caption).foregroundStyle(.orange) }
        }
        .padding(20)
        .frame(width: 560)
    }
}
