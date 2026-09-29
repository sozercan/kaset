import AppKit

/// A persisted appearance preference, independent of the macOS setting.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .system: String(localized: "System Default")
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
    static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: SettingsManager.Keys.appearance)
            .flatMap(Self.init(rawValue:)) ?? .system
    }
}
