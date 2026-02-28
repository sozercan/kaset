import Foundation

// MARK: - TopSongsDestination

/// Navigation destination for viewing all top songs of an artist.
struct TopSongsDestination: Hashable, Sendable {
    let artistId: String
    let artistName: String
    let songs: [Song]
    /// Browse ID for loading all songs (if more are available).
    let songsBrowseId: String?
    /// Params for loading all songs.
    let songsParams: String?
}
