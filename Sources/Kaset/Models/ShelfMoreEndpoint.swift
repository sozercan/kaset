import Foundation

// MARK: - ArtistShelfKind

/// Identifies which carousel shelf an artist-page More/See-all endpoint belongs to.
///
/// Shelves are matched by renderer shape + browseId prefix at parse time
/// (see `ArtistParser.classifyCarouselItem`). Each kind corresponds to one
/// bucket on `ArtistDetail` and — when its shelf exposes a `moreContentButton`
/// in the API response — one entry in `ArtistDetail.moreEndpoints`.
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

// MARK: - ShelfMoreEndpoint

/// A browse endpoint captured from a carousel shelf's `moreContentButton`.
///
/// Send `browseId` (+ optional `params`) to the standard `/browse` API to
/// fetch the full list behind a shelf's "See all" affordance. The `pageType`
/// dictates which parser and which destination view to route to:
///
/// - `MUSIC_PAGE_TYPE_PLAYLIST` → reuse the existing `Playlist` navigation
///   and `PlaylistDetailView`.
/// - `MUSIC_PAGE_TYPE_ARTIST_DISCOGRAPHY` → `ArtistDiscographyView` (grid of
///   `musicTwoRowItemRenderer` album cards).
/// - `MUSIC_PAGE_TYPE_ARTIST` → `ArtistEpisodesListView` (vertical list built
///   from a filtered artist-page response; the filter is encoded in
///   `params`).
///
/// Unknown `pageType` values should render no See-all link — we only surface
/// affordances we know how to navigate to.
struct ShelfMoreEndpoint: Hashable {
    /// Page-type tags observed in practice on artist-page shelves.
    enum PageType: String, Hashable {
        case playlist = "MUSIC_PAGE_TYPE_PLAYLIST"
        case artist = "MUSIC_PAGE_TYPE_ARTIST"
        case discography = "MUSIC_PAGE_TYPE_ARTIST_DISCOGRAPHY"
    }

    let browseId: String
    let params: String?
    let pageType: PageType
}
