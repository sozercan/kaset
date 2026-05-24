import Foundation

// MARK: - TopSongsDestination

/// Navigation destination for viewing all top songs of an artist.
struct TopSongsDestination: Hashable {
    let artistId: String
    let artistName: String
    let title: String
    let songs: [Song]
    /// Browse ID for loading all songs (if more are available).
    let songsBrowseId: String?
    /// Params for loading all songs.
    let songsParams: String?

    init(
        artistId: String,
        artistName: String,
        title: String = String(localized: "Top songs"),
        songs: [Song],
        songsBrowseId: String?,
        songsParams: String?
    ) {
        self.artistId = artistId
        self.artistName = artistName
        self.title = title
        self.songs = songs
        self.songsBrowseId = songsBrowseId
        self.songsParams = songsParams
    }
}
