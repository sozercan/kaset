import Foundation

/// Interprets ownership/delete affordances from YouTube Music playlist renderers.
enum PlaylistEditability {
    private static let deleteAffordanceKeys: Set<String> = [
        "deletePlaylistEndpoint",
        "musicEditablePlaylistDetailHeaderRenderer",
    ]

    /// Returns true only when the response payload exposes commands that are available
    /// for playlists the signed-in user can delete. Unknown ownership is treated as false.
    static func canDeletePlaylist(from value: Any) -> Bool {
        ResponseTreeSearch.containsAny(
            keys: self.deleteAffordanceKeys,
            text: "playlist/delete",
            in: value
        )
    }
}
