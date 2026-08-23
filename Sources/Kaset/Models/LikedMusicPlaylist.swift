import Foundation

/// Shared identifiers for the YouTube Music "Liked Music" playlist.
enum LikedMusicPlaylist {
    static let id = "LM"
    static let browseID = "VLLM"

    static var playlist: Playlist {
        Playlist(
            id: id,
            title: String(localized: "Liked Music"),
            description: nil,
            thumbnailURL: nil,
            trackCount: nil,
            author: nil
        )
    }

    static func matches(id playlistID: String) -> Bool {
        let normalizedID = playlistID.hasPrefix("VL")
            ? String(playlistID.dropFirst(2))
            : playlistID
        return normalizedID == Self.id
    }
}
