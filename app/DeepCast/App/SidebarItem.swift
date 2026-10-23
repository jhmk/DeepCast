import SwiftUI

/// Top-level navigation destinations shown in the sidebar.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case newEpisode
    case library
    case personas
    case systemStatus
    case settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .newEpisode: "Neue Episode"
        case .library: "Bibliothek"
        case .personas: "Personas"
        case .systemStatus: "Systemstatus"
        case .settings: "Einstellungen"
        }
    }

    var systemImage: String {
        switch self {
        case .newEpisode: "plus.bubble"
        case .library: "books.vertical"
        case .personas: "person.2.wave.2"
        case .systemStatus: "checkmark.seal"
        case .settings: "gearshape"
        }
    }
}
