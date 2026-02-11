import Foundation

// MARK: - QueueDisplayMode

/// Display mode for the playback queue panel.
enum QueueDisplayMode: String, Codable, CaseIterable, Sendable {
    case popup
    case sidepanel

    var displayName: String {
        switch self {
        case .popup: return "Popup"
        case .sidepanel: return "Side Panel"
        }
    }

    var description: String {
        switch self {
        case .popup: return "Compact overlay view"
        case .sidepanel: return "Full-width panel with reordering"
        }
    }
}
