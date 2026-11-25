import Foundation

enum ArtistShelfKind: Hashable {
    case albums
    case singles
    case videos
    case episodes
    case livePerformances
    case featuredOn
    case playlistsByArtist
    case podcasts
    case relatedArtists
}

struct ShelfMoreEndpoint: Hashable {
    enum PageType: String, Hashable {
        case playlist = "MUSIC_PAGE_TYPE_PLAYLIST"
        case artist = "MUSIC_PAGE_TYPE_ARTIST"
        case discography = "MUSIC_PAGE_TYPE_ARTIST_DISCOGRAPHY"
    }

    let browseId: String
    let params: String?
    let pageType: PageType
}
