import SwiftUI

struct SystemStatusView: View {
    @Environment(SystemStatusModel.self) private var status
    @Environment(PipelineService.self) private var pipeline
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Form {
            Section {
                aiRow
            } header: {
                Text("Sprachmodell")
            }

            Section {
                ForEach(SystemStatusModel.requiredVoiceNames, id: \.self) { name in
                    voiceRow(name)
                }
                if status.germanVoices.count > 0 {
                    DisclosureGroup("Alle deutschen Stimmen (\(status.germanVoices.count))") {
                        ForEach(status.germanVoices) { voice in
                            LabeledContent(voice.name, value: voice.quality.label)
                        }
                    }
                }
                HStack {
                    Button("Stimmen in Systemeinstellungen verwalten …") { SystemSettingsLink.openSpokenContent() }
                    Button("Stimmen neu einlesen") { Task { await status.refresh() } }
                }
            } header: {
                Text("Stimmen")
            } footer: {
                Text("Pfad: Systemeinstellungen → Bedienungshilfen → Gesprochene Inhalte → Systemstimme → „i“ bzw. „Stimmen verwalten …“. Empfohlen: deutsche Stimmen in „Premium“ oder „Erweitert“ laden (z.B. Petra, Yannick, Helena). Nach dem Laden „Stimmen neu einlesen“.")
            }

            Section {
                ForEach(KeychainStore.Account.allCases, id: \.self) { account in
                    StatusRow(
                        title: account.displayName,
                        ok: status.storedKeys.contains(account),
                        detail: status.storedKeys.contains(account)
                            ? String(localized: "Key im Schlüsselbund")
                            : String(localized: "Kein Key – Einstellungen → API-Keys")
                    )
                }
                if let quota = pipeline.quota {
                    LabeledContent("OpenRouter heute", value: "\(quota.remaining) von \(quota.limit) Gratis-Anfragen übrig")
                }
            } header: {
                Text("Cloud-Dienste (optional, kostenlos)")
            }

            Section("Audio") {
                StatusRow(
                    title: "ffmpeg",
                    ok: status.ffmpegURL != nil,
                    detail: status.ffmpegURL?.path ?? String(localized: "Nicht gefunden – brew install ffmpeg")
                )
            }

            Section("Speicherort") {
                LabeledContent("Episoden", value: AppPaths.episodesRoot().path)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Systemstatus")
        .task { await pipeline.refreshQuota(settings: settings) }
        .toolbar {
            ToolbarItem {
                Button {
                    Task {
                        await status.refresh()
                        await pipeline.refreshQuota(settings: settings)
                    }
                } label: {
                    Label("Erneut prüfen", systemImage: "arrow.clockwise")
                }
                .disabled(status.isRefreshing)
            }
        }
    }

    @ViewBuilder
    private var aiRow: some View {
        switch status.aiState {
        case .unknown:
            LabeledContent("Apple Intelligence") { ProgressView().controlSize(.small) }
        case .available(let contextSize, let supportsGerman):
            StatusRow(
                title: "Apple Intelligence",
                ok: supportsGerman,
                detail: supportsGerman
                    ? String(localized: "Bereit · Deutsch · Kontext \(contextSize) Tokens")
                    : String(localized: "Verfügbar, aber Deutsch wird nicht unterstützt")
            )
        case .unavailable(let reason):
            StatusRow(title: "Apple Intelligence", ok: false, detail: reason)
        }
    }

    private func voiceRow(_ name: String) -> some View {
        let voice = status.bestVoice(named: name)
        let ok = (voice?.quality ?? .standard) >= .enhanced
        let detail = voice.map { "\($0.name) · \($0.quality.label)" }
            ?? String(localized: "Nicht installiert")
        return StatusRow(title: name, ok: ok, detail: detail)
    }
}

struct StatusRow: View {
    let title: String
    let ok: Bool
    let detail: String

    var body: some View {
        LabeledContent {
            Text(detail).foregroundStyle(.secondary).textSelection(.enabled)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
            }
        }
    }
}
