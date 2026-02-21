import Foundation

// MARK: - QueueDisplayMode

/// Display mode for the playback queue panel.
enum QueueDisplayMode: String, Codable, CaseIterable, Sendable {
    case popup
    case sidepanel

    var displayName: String {
        switch self {
        case .popup: "Popup"
        case .sidepanel: "Side Panel"
        }
    }

    var description: String {
        switch self {
        case .popup: "Compact overlay view"
        case .sidepanel: "Full-width panel with reordering"
        }
    }
}
