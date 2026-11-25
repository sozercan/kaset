import Foundation

enum PlaylistEditability {
    private static let deleteAffordanceKeys: Set<String> = [
        "deletePlaylistEndpoint",
        "musicEditablePlaylistDetailHeaderRenderer",
    ]

    static func canDeletePlaylist(from value: Any) -> Bool {
        ResponseTreeSearch.containsAny(
            keys: self.deleteAffordanceKeys,
            text: "playlist/delete",
            in: value
        )
    }
}
