import CoreTransferable
import Foundation

struct FavoriteItem: Identifiable, Codable {
    let id: UUID
    let pinnedAt: Date
    let itemType: ItemType

    enum ItemType: Codable {
        case song(Song)
        case album(Album)
        case playlist(Playlist)
        case artist(Artist)
        case podcastShow(PodcastShow)
    }

    init(itemType: ItemType) {
        self.id = UUID()
        self.pinnedAt = Date()
        self.itemType = itemType
    }

    init(id: UUID, pinnedAt: Date, itemType: ItemType) {
        self.id = id
        self.pinnedAt = pinnedAt
        self.itemType = itemType
    }

    static func from(_ song: Song) -> FavoriteItem {
        FavoriteItem(itemType: .song(song))
    }

    static func from(_ album: Album) -> FavoriteItem {
        FavoriteItem(itemType: .album(album))
    }

    static func from(_ playlist: Playlist) -> FavoriteItem {
        FavoriteItem(itemType: .playlist(playlist))
    }

    static func from(_ artist: Artist) -> FavoriteItem {
        FavoriteItem(itemType: .artist(artist))
    }

    static func from(_ podcastShow: PodcastShow) -> FavoriteItem {
        FavoriteItem(itemType: .podcastShow(podcastShow))
    }

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

    var subtitle: String? {
        switch self.itemType {
        case let .song(song):
            song.artistsDisplay
        case let .album(album):
            album.artistsDisplay
        case let .playlist(playlist):
            playlist.author?.name ?? playlist.trackCountDisplay
        case .artist:
            "Artist"
        case let .podcastShow(show):
            show.author ?? "Podcast"
        }
    }

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

extension FavoriteItem: Hashable {
    static func == (lhs: FavoriteItem, rhs: FavoriteItem) -> Bool {
        lhs.contentId == rhs.contentId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.contentId)
    }
}

extension FavoriteItem: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(for: FavoriteItem.self, contentType: .data)
    }
}

extension FavoriteItem {
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
