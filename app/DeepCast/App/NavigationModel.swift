import Observation
import SwiftUI

@MainActor
@Observable
final class NavigationModel {
    var sidebar: SidebarItem? = .library
    var episodeID: UUID?

    func show(_ episode: Episode) {
        episodeID = episode.id
        sidebar = .library
    }
}
