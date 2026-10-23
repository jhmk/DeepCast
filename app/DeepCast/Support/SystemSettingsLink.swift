import AppKit

/// Deep links into System Settings. Apple does not document these URLs; we try the most
/// specific one first and fall back to the Accessibility pane.
enum SystemSettingsLink {
    static let spokenContentCandidates = [
        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
        "x-apple.systempreferences:com.apple.preference.universalaccess?SpeakableItems",
        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension",
    ]

    @MainActor
    static func openSpokenContent() {
        for candidate in spokenContentCandidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}
