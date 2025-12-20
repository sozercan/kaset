import Foundation

// MARK: - HomeSection

/// Represents a section on the YouTube Music home page.
struct HomeSection: Identifiable, Sendable {
    let id: String
    let title: String
    let items: [HomeSectionItem]
}

// MARK: - HomeSectionItem

/// An item within a home section (can be song, album, playlist, or artist).
enum HomeSectionItem: Identifiable, Sendable {
    case song(Song)
    case album(Album)
    case playlist(Playlist)
    case artist(Artist)

    var id: String {
        switch self {
        case let .song(song):
            "song-\(song.id)"
        case let .album(album):
            "album-\(album.id)"
        case let .playlist(playlist):
            "playlist-\(playlist.id)"
        case let .artist(artist):
            "artist-\(artist.id)"
        }
    }

    var title: String {
        switch self {
        case let .song(song):
            song.title
        case let .album(album):
            album.title
        case let .playlist(playlist):
            playlist.title
        case let .artist(artist):
            artist.name
        }
    }

    var subtitle: String? {
        switch self {
        case let .song(song):
            song.artistsDisplay
        case let .album(album):
            album.artistsDisplay
        case let .playlist(playlist):
            playlist.author
        case .artist:
            "Artist"
        }
    }

    var thumbnailURL: URL? {
        switch self {
        case let .song(song):
            song.thumbnailURL
        case let .album(album):
            album.thumbnailURL
        case let .playlist(playlist):
            playlist.thumbnailURL
        case let .artist(artist):
            artist.thumbnailURL
        }
    }

    /// Returns the video ID if this item is playable.
    var videoId: String? {
        switch self {
        case let .song(song):
            song.videoId
        default:
            nil
        }
    }

    /// Returns the browse ID for navigation (playlists, albums, artists).
    var browseId: String? {
        switch self {
        case .song:
            nil
        case let .album(album):
            album.id
        case let .playlist(playlist):
            playlist.id
        case let .artist(artist):
            artist.id
        }
    }

    /// Returns the underlying playlist if this is a playlist item.
    var playlist: Playlist? {
        if case let .playlist(playlist) = self {
            return playlist
        }
        return nil
    }

    /// Returns the underlying album if this is an album item.
    var album: Album? {
        if case let .album(album) = self {
            return album
        }
        return nil
    }
}
