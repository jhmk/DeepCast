import SwiftUI

struct RootView: View {
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            List(selection: $navigation.sidebar) {
                Section("Erstellen") {
                    sidebarRow(.newEpisode)
                }
                Section("Hören") {
                    sidebarRow(.library)
                }
                Section("Einrichtung") {
                    sidebarRow(.personas)
                    sidebarRow(.systemStatus)
                    sidebarRow(.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch navigation.sidebar {
            case .library, .none:
                LibraryView()
            case .personas:
                PersonasView()
            case .systemStatus:
                SystemStatusView()
            case .newEpisode:
                NewEpisodeView()
            case .settings:
                SettingsView(embedded: true)
                    .navigationTitle("Einstellungen")
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { navigation.sidebar = .settings } label: { Label("Einstellungen", systemImage: "gearshape") }
                    .help("Einstellungen (⌘,)")
            }
        }
    }

    private func sidebarRow(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.systemImage).tag(item)
    }
}
