import Foundation

struct TopSongsDestination: Hashable {
    let artistId: String
    let artistName: String
    let title: String
    let songs: [Song]
    let songsBrowseId: String?
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
