import SwiftData
import SwiftUI

/// Progress of the pipeline plus the review of sources and claims (spec 4, step 8).
struct ResearchView: View {
    let episode: Episode
    @Environment(\.modelContext) private var context
    @Environment(PipelineService.self) private var pipeline
    @Environment(PersonaStore.self) private var personas
    @Environment(AppSettings.self) private var settings
    @Environment(ProductionService.self) private var production
    @State private var mode: Mode = .claims
    @State private var lightFilter: TrafficLight?
    @State private var showAddSource = false

    enum Mode: Hashable { case claims, sources, notes, stats }

    var body: some View {
        let dossier = pipeline.dossier(for: episode)
        VStack(spacing: 0) {
            StageProgressView(episode: episode)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            if let dossier, dossier.isComplete {
                review(dossier)
            } else if episode.status == .failed || pipeline.canResume(episode) && !pipeline.isRunning(episode) {
                ContentUnavailableView {
                    Label("Recherche nicht abgeschlossen", systemImage: "exclamationmark.triangle")
                } description: {
                    VStack(spacing: 4) {
                        Text(episode.lastError ?? "")
                        if let checkpoint = dossier?.checkpoint, let dossier {
                            Text("Zwischenstand: \(dossier.sources.count) Quellen, \(checkpoint.extractedSourceIDs.count) ausgewertet, \(dossier.claims.filter { $0.verdict != nil }.count) Aussagen geprüft.")
                                .font(.callout)
                        }
                    }
                } actions: {
                    if pipeline.canResume(episode) {
                        Button("Fortsetzen") { pipeline.startResearch(episode, settings: settings, context: context, resume: true) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Neu starten") { pipeline.startResearch(episode, settings: settings, context: context) }
                }
            } else {
                ContentUnavailableView("Recherche läuft …", systemImage: "magnifyingglass",
                                       description: Text("Quellen und Aussagen erscheinen hier, sobald sie geprüft sind."))
            }
        }
    }

    // MARK: Review

    @ViewBuilder
    private func review(_ dossier: ResearchDossier) -> some View {
        HStack(spacing: 14) {
            Picker("", selection: $mode) {
                Text("Aussagen (\(dossier.claims.count))").tag(Mode.claims)
                Text("Quellen (\(dossier.sources.count))").tag(Mode.sources)
                Text("Hinweise (\(dossier.notes.count))").tag(Mode.notes)
                Text("Statistik").tag(Mode.stats)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if mode == .claims {
                Picker("Filter", selection: $lightFilter) {
                    Text("Alle").tag(TrafficLight?.none)
                    ForEach(TrafficLight.allCases, id: \.self) { light in
                        Text("\(light.emoji) \(dossier.count(light))").tag(TrafficLight?.some(light))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Spacer()
            Button { showAddSource = true } label: { Label("Eigene Quelle …", systemImage: "plus") }
                .disabled(pipeline.isRunning(episode))
                .sheet(isPresented: $showAddSource) { AddCustomSourceSheet(episode: episode) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)

        switch mode {
        case .claims:
            List {
                ForEach(dossier.claims.filter { lightFilter == nil || $0.effectiveLight == lightFilter }) { claim in
                    ClaimRow(claim: claim, dossier: dossier) { override in
                        pipeline.updateDossier(for: episode) { dossier in
                            guard let index = dossier.claims.firstIndex(where: { $0.id == claim.id }) else { return }
                            dossier.claims[index].userOverride = override
                            dossier.notes.removeAll { $0.hasPrefix("Manuell: \(claim.id) ") }
                            if let override {
                                dossier.notes.append("Manuell: \(claim.id) auf \(override.emoji) gesetzt (automatisch \(claim.light.emoji))")
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        case .sources:
            List {
                ForEach(dossier.sources) { source in
                    SourceRow(source: source, claimCount: dossier.claims.filter { $0.sourceIDs.contains(source.id) }.count) { included in
                        pipeline.updateDossier(for: episode) { dossier in
                            guard let index = dossier.sources.firstIndex(where: { $0.id == source.id }) else { return }
                            dossier.sources[index].included = included
                        }
                    }
                }
            }
            .listStyle(.inset)
        case .stats:
            StatsView(dossier: dossier)
        case .notes:
            List(dossier.notes + dossier.scriptIssues.map { "Aus Skript entfernt: \($0)" }, id: \.self) { note in
                Text(note).font(.callout).textSelection(.enabled)
            }
            .listStyle(.inset)
        }

        approveBar(dossier)
    }

    private func approveBar(_ dossier: ResearchDossier) -> some View {
        let usable = dossier.usableClaims.count
        let busy = pipeline.isRunning(episode) || production.activeEpisodeID == episode.id
        return HStack(spacing: 12) {
            Text("🟢 \(dossier.count(.green))  🟡 \(dossier.count(.yellow))  🔴 \(dossier.count(.red)) werden entfernt")
                .monospacedDigit()
            if usable < 6 {
                Label("Wenig Material – die Folge wird kurz.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Spacer()
            if pipeline.isRunning(episode) {
                Button("Abbrechen") { pipeline.cancel(episode) }
            }
            Button {
                pipeline.approve(episode, personas: personas, settings: settings, production: production, context: context)
            } label: {
                Label(episode.status == .review ? "Freigeben: Skript schreiben und vertonen" : "Skript neu schreiben",
                      systemImage: "text.badge.checkmark")
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || usable == 0 || episode.status == .researching)
        }
        .font(.callout)
        .padding(12)
        .background(.bar)
    }
}

// MARK: - Rows

private struct ClaimRow: View {
    let claim: Claim
    let dossier: ResearchDossier
    let onOverride: (TrafficLight?) -> Void
    @State private var expanded = false

    private var excluded: Bool {
        !claim.evidence.contains { dossier.includedSourceIDs.contains($0.sourceID) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(claim.effectiveLight.emoji).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(claim.text).fontWeight(.medium).strikethrough(excluded)
                HStack(spacing: 6) {
                    Chip(text: claim.id)
                    Chip(text: claim.type.label)
                    ForEach(claim.sourceIDs, id: \.self) { id in
                        if let source = dossier.source(id) { Chip(text: "\(id) · \(source.publisher) · \(source.tier.rawValue)") }
                    }
                    if claim.userOverride != nil { Chip(text: "manuell", tint: .purple) }
                    if claim.type == .quote {
                        Chip(text: claim.isParaphrase == true ? "nur Paraphrase" : "Zitat: \(claim.quotedPerson ?? "?")",
                             tint: claim.isParaphrase == true ? .orange : .green)
                    }
                    if let others = claim.contestedWith { Chip(text: "umstritten ↔ \(others.joined(separator: ", "))", tint: .orange) }
                }
                if let verdict = claim.verdict {
                    Text("Prüfer (\(FactCheckReport.modelName(claim.verifierModel ?? ""))): \(verdict.label)\(claim.verdictReason.map { " – \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !claim.lightReasons.isEmpty {
                    Text(claim.lightReasons.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                if expanded {
                    ForEach(claim.evidence, id: \.self) { evidence in
                        Text("„\(evidence.quote)“ — \(evidence.sourceID)\(evidence.match == .approximate ? " (sinngemäß)" : "")")
                            .font(.callout).italic()
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            .textSelection(.enabled)
                    }
                }
            }
            .opacity(excluded ? 0.5 : 1)
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Menu {
                    Button("Automatisch (\(claim.light.emoji))") { onOverride(nil) }
                    Divider()
                    ForEach(TrafficLight.allCases, id: \.self) { light in
                        Button("\(light.emoji) \(light.label)") { onOverride(light) }
                    }
                } label: {
                    Text("Ampel")
                }
                .fixedSize()
                Button(expanded ? "Beleg ausblenden" : "Beleg zeigen") { expanded.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SourceRow: View {
    let source: SourceDocument
    let claimCount: Int
    let onToggle: @MainActor (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { source.included }, set: onToggle))
                .labelsHidden()
                .help("Quelle für das Skript verwenden")
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Chip(text: "\(source.id) · Stufe \(source.tier.rawValue)", tint: tierColor)
                    Link(source.title, destination: source.url).fontWeight(.medium).lineLimit(2)
                }
                HStack(spacing: 8) {
                    Text(source.publisher)
                    if let date = source.publishedAt { Text(date, format: .dateTime.day().month().year()) }
                    Text("\(claimCount) Aussagen")
                    Text("\(source.chunks.count) Abschnitte")
                }
                .font(.caption).foregroundStyle(.secondary)
                if !source.notes.isEmpty {
                    Text(source.notes.joined(separator: " · ")).font(.caption).foregroundStyle(.orange)
                }
            }
            .opacity(source.included ? 1 : 0.5)
        }
        .padding(.vertical, 3)
    }

    private var tierColor: Color {
        switch source.tier {
        case .a: .green
        case .b: .blue
        case .c: .orange
        case .d: .red
        }
    }
}

struct Chip: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            .lineLimit(1)
    }
}

// MARK: - Stage progress

struct StageProgressView: View {
    let episode: Episode
    @Environment(PipelineService.self) private var pipeline
    @Environment(ProductionService.self) private var production
    @State private var showLog = false

    private var currentStage: PipelineStage {
        if production.activeEpisodeID == episode.id { return .speech }
        if let run = pipeline.runs[episode.id] { return run.stage }
        switch episode.status {
        case .researching: return .plan
        case .review: return .review
        case .scripting: return .outline
        case .draft, .needsRender, .failed: return episode.segments.isEmpty ? .review : .speech
        case .rendering: return .speech
        case .ready: return .done
        }
    }

    var body: some View {
        let run = pipeline.runs[episode.id]
        let current = currentStage
        let active = (run?.isRunning ?? false) || production.activeEpisodeID == episode.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(PipelineStage.visible, id: \.self) { stage in
                    stageChip(stage, current: current, active: active)
                }
            }
            if active || run != nil {
                HStack(spacing: 8) {
                    if active {
                        if let fraction = (production.activeEpisodeID == episode.id ? production.progress : run?.fraction) {
                            ProgressView(value: fraction).frame(width: 140)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Text(production.activeEpisodeID == episode.id ? production.message : (run?.message ?? ""))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    if active, let remaining = production.activeEpisodeID == episode.id ? production.remaining : run?.remaining {
                        Text(RemainingTimeEstimator.format(remaining))
                            .font(.callout.monospacedDigit().weight(.medium))
                    }
                    Spacer()
                    if let run, !run.log.isEmpty {
                        Button(showLog ? "Protokoll ausblenden" : "Protokoll") { showLog.toggle() }.buttonStyle(.link).font(.caption)
                    }
                    if run?.isRunning == true {
                        Button("Abbrechen") { pipeline.cancel(episode) }
                    }
                }
                if showLog, let run {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(run.log.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
    }

    private func stageChip(_ stage: PipelineStage, current: PipelineStage, active: Bool) -> some View {
        let done = stage < current || current == .done
        let isCurrent = stage == current
        return HStack(spacing: 4) {
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if isCurrent && active {
                ProgressView().controlSize(.mini)
            } else if isCurrent {
                Image(systemName: stage == .review ? "hand.raised.circle.fill" : "circle.fill").foregroundStyle(.purple)
            } else {
                Image(systemName: "circle").foregroundStyle(.tertiary)
            }
            Text(stage.title).font(.caption).foregroundStyle(isCurrent ? .primary : .secondary).lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isCurrent ? Color.accentColor.opacity(0.1) : .clear, in: Capsule())
    }
}

/// Model calls and timings of the run (spec 9: "Kosten und Token-Verbrauch pro Stufe loggen").
private struct StatsView: View {
    let dossier: ResearchDossier

    private struct Row: Identifiable {
        let id: String
        let calls: Int
        let failed: Int
        let seconds: Double
    }

    private func rows(_ key: (LLMCallRecord) -> String) -> [Row] {
        Dictionary(grouping: dossier.calls, by: key).map { name, calls in
            Row(id: name, calls: calls.count, failed: calls.filter { !$0.succeeded }.count, seconds: calls.map(\.seconds).reduce(0, +))
        }.sorted { $0.seconds > $1.seconds }
    }

    var body: some View {
        let total = dossier.calls.map(\.seconds).reduce(0, +)
        Form {
            Section {
                LabeledContent("KI-Aufrufe", value: "\(dossier.calls.count) (\(dossier.calls.filter { !$0.succeeded }.count) fehlgeschlagen)")
                LabeledContent("Rechenzeit der Modelle", value: Duration.seconds(total).formatted(.units(allowed: [.minutes, .seconds])))
                LabeledContent("Quellen", value: "\(dossier.sources.count) · Aussagen \(dossier.claims.count)")
                LabeledContent("Kosten", value: "0 € (nur Gratis-Modelle)")
            }
            Section("Nach Modell") { table(rows { FactCheckReport.modelName($0.model) }) }
            Section("Nach Schritt") { table(rows { $0.task.components(separatedBy: " ").first ?? $0.task }) }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func table(_ rows: [Row]) -> some View {
        if rows.isEmpty {
            Text("Keine Aufrufe protokolliert.").foregroundStyle(.secondary)
        }
        ForEach(rows) { row in
            LabeledContent(row.id) {
                Text("\(row.calls)× · \(Int(row.seconds)) s\(row.failed > 0 ? " · \(row.failed) Fehler" : "")").monospacedDigit()
            }
        }
    }
}
