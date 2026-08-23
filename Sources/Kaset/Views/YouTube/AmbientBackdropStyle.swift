import SwiftUI

// MARK: - AmbientBackdropStyle

/// The visual style of the YouTube watch-page ambient backdrop.
///
/// Shared between `SettingsManager` (persistence) and `AmbientVideoBackdrop`
/// (rendering). `off` is reached by disabling the feature rather than being a
/// user-pickable style — see `userSelectableCases`.
enum AmbientBackdropStyle: String, CaseIterable, Identifiable {
    /// No ambient — the plain window background.
    case off
    /// A steady (non-drifting) soft version of the aurora glow.
    case soft
    /// Drifting multi-color aurora from the static thumbnail.
    case glow
    /// Drifting aurora whose colors crossfade through the storyboard
    /// sprite-sheet cells as the video plays.
    case live

    var id: String {
        self.rawValue
    }

    /// The styles a user can choose in Settings. `off` is excluded — turning
    /// the feature off is the master toggle's job, so the picker never offers a
    /// redundant second "off".
    static var userSelectableCases: [AmbientBackdropStyle] {
        [.soft, .glow, .live]
    }

    /// User-facing name shown in Settings.
    var displayName: String {
        switch self {
        case .off: String(localized: "Off")
        case .soft: String(localized: "Soft")
        case .glow: String(localized: "Glow")
        case .live: String(localized: "Live (follows video)")
        }
    }

    /// Terse label for the DEBUG developer style picker.
    var debugLabel: String {
        switch self {
        case .off: "Off"
        case .soft: "Soft"
        case .glow: "Glow"
        case .live: "Live (storyboard)"
        }
    }
}
