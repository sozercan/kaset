import Foundation

// MARK: - SearchResponse

/// Response from a YouTube Music search query.
struct SearchResponse: Sendable {
    let songs: [Song]
    let albums: [Album]
    let artists: [Artist]
    let playlists: [Playlist]

    /// All results as a flat array of items.
    var allItems: [SearchResultItem] {
        var items: [SearchResultItem] = []
        items.append(contentsOf: self.songs.map { .song($0) })
        items.append(contentsOf: self.albums.map { .album($0) })
        items.append(contentsOf: self.artists.map { .artist($0) })
        items.append(contentsOf: self.playlists.map { .playlist($0) })
        return items
    }

    /// Whether the search returned any results.
    var isEmpty: Bool {
        self.songs.isEmpty && self.albums.isEmpty && self.artists.isEmpty && self.playlists.isEmpty
    }

    static let empty = SearchResponse(songs: [], albums: [], artists: [], playlists: [])
}

// MARK: - SearchResultItem

/// A search result item (can be any content type).
enum SearchResultItem: Identifiable, Sendable {
    case song(Song)
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)

    var id: String {
        switch self {
        case let .song(song):
            "song-\(song.id)"
        case let .album(album):
            "album-\(album.id)"
        case let .artist(artist):
            "artist-\(artist.id)"
        case let .playlist(playlist):
            "playlist-\(playlist.id)"
        }
    }

    var title: String {
        switch self {
        case let .song(song):
            song.title
        case let .album(album):
            album.title
        case let .artist(artist):
            artist.name
        case let .playlist(playlist):
            playlist.title
        }
    }

    var subtitle: String? {
        switch self {
        case let .song(song):
            song.artistsDisplay
        case let .album(album):
            album.artistsDisplay
        case .artist:
            "Artist"
        case let .playlist(playlist):
            playlist.author
        }
    }

    var thumbnailURL: URL? {
        switch self {
        case let .song(song):
            song.thumbnailURL
        case let .album(album):
            album.thumbnailURL
        case let .artist(artist):
            artist.thumbnailURL
        case let .playlist(playlist):
            playlist.thumbnailURL
        }
    }

    var resultType: String {
        switch self {
        case .song:
            "Song"
        case .album:
            "Album"
        case .artist:
            "Artist"
        case .playlist:
            "Playlist"
        }
    }

    /// Returns the video ID if this item is directly playable.
    var videoId: String? {
        switch self {
        case let .song(song):
            song.videoId
        default:
            nil
        }
    }
}
