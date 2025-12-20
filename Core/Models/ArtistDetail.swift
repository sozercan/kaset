import Foundation

// MARK: - ArtistDetail

/// Contains detailed artist information including their songs.
struct ArtistDetail: Sendable {
    let artist: Artist
    let description: String?
    let songs: [Song]
    let albums: [Album]
    let thumbnailURL: URL?

    var id: String { artist.id }
    var name: String { artist.name }
}
