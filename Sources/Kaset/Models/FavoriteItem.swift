import Foundation

// MARK: - FavoriteItem

/// An item pinned to Favorites.
struct FavoriteItem: Identifiable, Codable, Sendable {
    let id: UUID
    let pinnedAt: Date
    let itemType: ItemType

    /// The type of item that can be pinned to Favorites.
    enum ItemType: Codable, Sendable {
        case song(Song)
        case album(Album)
        case playlist(Playlist)
        case artist(Artist)
        case podcastShow(PodcastShow)
    }

    /// Creates a new FavoriteItem with current timestamp.
    init(itemType: ItemType) {
        self.id = UUID()
        self.pinnedAt = Date()
        self.itemType = itemType
    }

    /// Creates a FavoriteItem with explicit ID and timestamp (for testing/restoration).
    init(id: UUID, pinnedAt: Date, itemType: ItemType) {
        self.id = id
        self.pinnedAt = pinnedAt
        self.itemType = itemType
    }

    // MARK: - Convenience Initializers

    /// Creates a FavoriteItem from a Song.
    static func from(_ song: Song) -> FavoriteItem {
        FavoriteItem(itemType: .song(song))
    }

    /// Creates a FavoriteItem from an Album.
    static func from(_ album: Album) -> FavoriteItem {
        FavoriteItem(itemType: .album(album))
    }

    /// Creates a FavoriteItem from a Playlist.
    static func from(_ playlist: Playlist) -> FavoriteItem {
        FavoriteItem(itemType: .playlist(playlist))
    }

    /// Creates a FavoriteItem from an Artist.
    static func from(_ artist: Artist) -> FavoriteItem {
        FavoriteItem(itemType: .artist(artist))
    }

    /// Creates a FavoriteItem from a PodcastShow.
    static func from(_ podcastShow: PodcastShow) -> FavoriteItem {
        FavoriteItem(itemType: .podcastShow(podcastShow))
    }

    // MARK: - Display Properties

    /// Display title for the item.
    var title: String {
        switch self.itemType {
        case let .song(song):
            song.title
        case let .album(album):
            album.title
        case let .playlist(playlist):
            playlist.title
        case let .artist(artist):
            artist.name
        case let .podcastShow(show):
            show.title
        }
    }

    /// Subtitle (artist, author, etc.).
    var subtitle: String? {
        switch self.itemType {
        case let .song(song):
            song.artistsDisplay
        case let .album(album):
            album.artistsDisplay
        case let .playlist(playlist):
            playlist.author ?? playlist.trackCountDisplay
        case .artist:
            "Artist"
        case let .podcastShow(show):
            show.author ?? "Podcast"
        }
    }

    /// Thumbnail URL.
    var thumbnailURL: URL? {
        switch self.itemType {
        case let .song(song):
            song.thumbnailURL
        case let .album(album):
            album.thumbnailURL
        case let .playlist(playlist):
            playlist.thumbnailURL
        case let .artist(artist):
            artist.thumbnailURL
        case let .podcastShow(show):
            show.thumbnailURL
        }
    }

    /// Unique content identifier for duplicate detection.
    /// Uses videoId for songs, browseId for others.
    var contentId: String {
        switch self.itemType {
        case let .song(song):
            song.videoId
        case let .album(album):
            album.id
        case let .playlist(playlist):
            playlist.id
        case let .artist(artist):
            artist.id
        case let .podcastShow(show):
            show.id
        }
    }

    /// Type indicator for UI display.
    var typeLabel: String {
        switch self.itemType {
        case .song:
            "Song"
        case .album:
            "Album"
        case .playlist:
            "Playlist"
        case .artist:
            "Artist"
        case .podcastShow:
            "Podcast"
        }
    }
}

// MARK: Hashable

extension FavoriteItem: Hashable {
    static func == (lhs: FavoriteItem, rhs: FavoriteItem) -> Bool {
        lhs.contentId == rhs.contentId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.contentId)
    }
}

// MARK: - HomeSectionItem Conversion

extension FavoriteItem {
    /// Converts the FavoriteItem to a HomeSectionItem for display.
    /// Returns nil for podcast shows since HomeSectionItem doesn't support podcasts.
    var asHomeSectionItem: HomeSectionItem? {
        switch self.itemType {
        case let .song(song):
            .song(song)
        case let .album(album):
            .album(album)
        case let .playlist(playlist):
            .playlist(playlist)
        case let .artist(artist):
            .artist(artist)
        case .podcastShow:
            nil
        }
    }
}
