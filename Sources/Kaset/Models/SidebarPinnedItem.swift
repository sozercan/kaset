import Foundation

// MARK: - SidebarPinnedItem

/// A playlist-like item pinned directly to the app sidebar.
struct SidebarPinnedItem: Identifiable, Codable, Hashable {
    let itemType: ItemType

    enum ItemType: Codable, Hashable {
        case album(Album)
        case playlist(Playlist)
    }

    var id: String {
        self.contentId
    }

    var contentId: String {
        switch self.itemType {
        case let .album(album):
            album.id
        case let .playlist(playlist):
            playlist.id
        }
    }

    var title: String {
        switch self.itemType {
        case let .album(album):
            album.title
        case let .playlist(playlist):
            playlist.title
        }
    }

    var subtitle: String? {
        switch self.itemType {
        case let .album(album):
            album.artistsDisplay.isEmpty ? self.typeLabel : album.artistsDisplay
        case let .playlist(playlist):
            playlist.author?.name ?? playlist.trackCountDisplay
        }
    }

    var typeLabel: String {
        switch self.itemType {
        case let .album(album):
            album.trackCount == 1 ? "Single" : "Album"
        case .playlist:
            "Playlist"
        }
    }

    var systemImage: String {
        switch self.itemType {
        case let .album(album):
            album.trackCount == 1 ? "music.note" : "square.stack"
        case .playlist:
            "music.note.list"
        }
    }

    var playlistRoute: Playlist {
        switch self.itemType {
        case let .album(album):
            Playlist(
                id: album.id,
                title: album.title,
                description: nil,
                thumbnailURL: album.thumbnailURL,
                trackCount: album.trackCount,
                author: album.artists?.first ?? Artist.inline(name: album.artistsDisplay, namespace: "album-artist")
            )
        case let .playlist(playlist):
            playlist
        }
    }

    static func from(_ album: Album) -> SidebarPinnedItem {
        Self(itemType: .album(album))
    }

    static func from(_ playlist: Playlist) -> SidebarPinnedItem {
        Self(itemType: .playlist(playlist))
    }

    static func from(_ detail: PlaylistDetail) -> SidebarPinnedItem? {
        guard !detail.isUploadedSongs else { return nil }

        if detail.isAlbum {
            return self.from(Album(
                id: detail.id,
                title: detail.title,
                artists: detail.author.map { [$0] },
                thumbnailURL: detail.thumbnailURL,
                year: nil,
                trackCount: detail.resolvedTrackCount
            ))
        }

        return self.from(Playlist(
            id: detail.id,
            title: detail.title,
            description: detail.description,
            thumbnailURL: detail.thumbnailURL,
            trackCount: detail.trackCount,
            author: detail.author,
            canDelete: detail.canDelete
        ))
    }
}
