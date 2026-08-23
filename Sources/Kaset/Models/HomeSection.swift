import Foundation

// MARK: - HomeSection

/// Represents a section on the YouTube Music home page.
struct HomeSection: Identifiable {
    let id: String
    let title: String
    let items: [HomeSectionItem]
    /// Whether this section is a chart (e.g., "Top 100", "Trending", "Charts").
    /// Chart sections are rendered as vertical numbered lists instead of horizontal carousels.
    let isChart: Bool

    init(id: String, title: String, items: [HomeSectionItem], isChart: Bool = false) {
        self.id = id
        self.title = title
        self.items = items
        self.isChart = isChart
    }
}

// MARK: - HomeSectionItem

/// An item within a home section (can be song, album, playlist, or artist).
enum HomeSectionItem: Identifiable {
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
            playlist.author?.name
        case .artist:
            "Artist"
        }
    }

    var homeCardSubtitle: String? {
        guard let subtitle else { return nil }
        return Self.bulletSeparatedSubtitle(subtitle) ?? Self.viewCountSubtitle(subtitle) ?? Self.reorderedMediaSubtitle(subtitle) ?? subtitle
    }

    private static func bulletSeparatedSubtitle(_ subtitle: String) -> String? {
        guard subtitle.contains(" • ") else { return nil }
        return subtitle.replacingOccurrences(of: " • ", with: " - ")
    }

    private static func viewCountSubtitle(_ subtitle: String) -> String? {
        let components = Self.subtitleComponents(subtitle)
        guard components.count > 1,
              components.last?.lowercased().contains("views") == true
        else {
            return nil
        }

        let name = components.dropLast().joined(separator: ", ")
        return "\(name) - \(components[components.count - 1])"
    }

    private static func reorderedMediaSubtitle(_ subtitle: String) -> String? {
        let components = Self.subtitleComponents(subtitle)

        guard components.count > 1,
              let mediaType = Self.normalizedLeadingMediaType(components[0])
        else {
            return nil
        }

        return "\(components.dropFirst().joined(separator: ", ")) - \(mediaType)"
    }

    private static func subtitleComponents(_ subtitle: String) -> [String] {
        subtitle
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizedLeadingMediaType(_ value: String) -> String? {
        switch value.lowercased() {
        case "album":
            "Album"
        case "song":
            "Song"
        case "single":
            "Single"
        case "ep":
            "EP"
        case "playlist":
            "Playlist"
        case "podcast":
            "Podcast"
        case "episode":
            "Episode"
        case "video":
            "Video"
        default:
            nil
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
