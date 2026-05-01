import Foundation

// MARK: - ArtistSeeAllDestination

/// Navigation destination for an artist shelf's "See all" affordance.
///
/// A single destination type covers both `MUSIC_PAGE_TYPE_ARTIST_DISCOGRAPHY`
/// (grid of albums) and `MUSIC_PAGE_TYPE_ARTIST` (filtered artist-page
/// response, e.g. Latest episodes / Live performances). The
/// `NavigationDestinationsModifier` switches on `endpoint.pageType` to pick
/// the right view.
///
/// Playlist-backed See-all destinations (`MUSIC_PAGE_TYPE_PLAYLIST`) route
/// through the existing `Playlist` destination instead — they don't wrap in
/// this type.
struct ArtistSeeAllDestination: Hashable {
    /// Displayed in the destination view's title bar.
    let artistName: String
    /// The shelf's own title ("Albums", "Latest episodes", …) — used as the
    /// destination view's navigation title.
    let sectionTitle: String
    /// The browse endpoint to fetch and render.
    let endpoint: ShelfMoreEndpoint
}
