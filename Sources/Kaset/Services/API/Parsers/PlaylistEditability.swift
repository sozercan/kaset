import Foundation

/// Interprets ownership/delete affordances from YouTube Music playlist renderers.
enum PlaylistEditability {
    /// Returns true only when the response payload exposes commands that are available
    /// for playlists the signed-in user can delete. Unknown ownership is treated as false.
    static func canDeletePlaylist(from value: Any) -> Bool {
        ResponseTreeSearch.containsKey("deletePlaylistEndpoint", in: value)
            || ResponseTreeSearch.containsKey("musicEditablePlaylistDetailHeaderRenderer", in: value)
            || ResponseTreeSearch.containsText("playlist/delete", in: value)
    }
}
