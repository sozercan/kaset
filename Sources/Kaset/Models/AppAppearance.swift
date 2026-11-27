import AppKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .system:
            String(
                localized: "Match System",
                bundle: AppLocalization.bundle,
                comment: "Appearance option that follows the macOS light or dark setting"
            )
        case .light: String(localized: "Light Mode")
        case .dark: String(localized: "Dark Mode")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    func apply() {
        NSApplication.shared.appearance = self.nsAppearance
    }
}
