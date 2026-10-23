import SwiftData
import SwiftUI

@main
struct DeepCastApp: App {
    @State private var systemStatus = SystemStatusModel()
    @State private var personas = PersonaStore()
    @State private var settings = AppSettings()
    @State private var production = ProductionService()
    @State private var pipeline = PipelineService()
    @State private var player = PlayerModel()
    @State private var preview = PreviewPlayer()
    @State private var navigation = NavigationModel()

    var body: some Scene {
        WindowGroup("DeepCast", id: "main") {
            RootView()
                .frame(minWidth: 1040, minHeight: 680)
                .task {
                    await systemStatus.refresh()
                    await settings.checkModelsIfDue()
                    Task.detached(priority: .background) { StorageManager.pruneSpeechCache() }
                }
                .environment(systemStatus)
                .environment(personas)
                .environment(settings)
                .environment(production)
                .environment(pipeline)
                .environment(player)
                .environment(preview)
                .environment(navigation)
        }
        .modelContainer(for: [Episode.self, EpisodeSegment.self])
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .modelContainer(for: [Episode.self, EpisodeSegment.self])
                .environment(settings)
                .environment(personas)
                .environment(preview)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(pipeline)
                .environment(production)
                .environment(player)
        } label: {
            Image(systemName: pipeline.runningCount > 0 || production.isRunning ? "waveform.badge.magnifyingglass" : "waveform")
        }
    }
}

private struct MenuBarContent: View {
    @Environment(PipelineService.self) private var pipeline
    @Environment(ProductionService.self) private var production
    @Environment(PlayerModel.self) private var player
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let running = pipeline.runs.values.filter(\.isRunning)
        if running.isEmpty && !production.isRunning {
            Text("Keine laufenden Generierungen")
        }
        ForEach(Array(running.enumerated()), id: \.offset) { _, run in
            Text("\(run.stage.title): \(run.message)\(run.remaining.map { " · " + RemainingTimeEstimator.format($0) } ?? "")")
        }
        if production.isRunning {
            Text("Vertonen: \(Int(production.progress * 100)) %\(production.remaining.map { " · " + RemainingTimeEstimator.format($0) } ?? "")")
        }
        if let episode = player.episode {
            Divider()
            Button(player.isPlaying ? "Pause: \(episode.title)" : "Abspielen: \(episode.title)") { player.togglePlay() }
        }
        Divider()
        SettingsLink { Text("Einstellungen …") }
            .keyboardShortcut(",")
        Button("DeepCast öffnen") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Beenden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
