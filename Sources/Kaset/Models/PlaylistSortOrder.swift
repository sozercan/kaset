import Foundation

// MARK: - PlaylistSortKey

/// A sort key for the playlist detail track list.
enum PlaylistSortKey: String, CaseIterable, Identifiable {
    case original
    case title
    case artist
    case duration
    case album

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .original: String(localized: "Original Order")
        case .title: String(localized: "Title")
        case .artist: String(localized: "Artist")
        case .duration: String(localized: "Duration")
        case .album: String(localized: "Album")
        }
    }
}

// MARK: - PlaylistSortOrder

/// A sort key plus direction. `.original` preserves the server-provided order.
struct PlaylistSortOrder: Equatable {
    var key: PlaylistSortKey
    var ascending: Bool

    static let `default` = PlaylistSortOrder(key: .original, ascending: true)
}
