import SwiftUI

// MARK: - ShareContextMenu

/// Shared context menu items for sharing items via native ShareLink.
@available(macOS 26.0, *)
@MainActor
enum ShareContextMenu {
    /// Creates a share menu item for a song.
    @ViewBuilder
    static func menuItem(for song: Song) -> some View {
        if let url = song.shareURL {
            ShareLink(item: url, message: Text(song.shareText)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    /// Creates a share menu item for a playlist.
    @ViewBuilder
    static func menuItem(for playlist: Playlist) -> some View {
        if let url = playlist.shareURL {
            ShareLink(item: url, message: Text(playlist.shareText)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    /// Creates a share menu item for an album.
    /// Only shows if the album has a navigable ID.
    @ViewBuilder
    static func menuItem(for album: Album) -> some View {
        if let url = album.shareURL {
            ShareLink(item: url, message: Text(album.shareText)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    /// Creates a share menu item for an artist.
    /// Only shows if the artist has a valid YouTube channel ID.
    @ViewBuilder
    static func menuItem(for artist: Artist) -> some View {
        if let url = artist.shareURL {
            ShareLink(item: url, message: Text(artist.shareText)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    /// Creates a share menu item for a HomeSectionItem.
    @ViewBuilder
    static func menuItem(for item: HomeSectionItem) -> some View {
        switch item {
        case let .song(song):
            Self.menuItem(for: song)
        case let .album(album):
            Self.menuItem(for: album)
        case let .playlist(playlist):
            Self.menuItem(for: playlist)
        case let .artist(artist):
            Self.menuItem(for: artist)
        }
    }

    /// Creates a share menu item for a SearchResultItem.
    @ViewBuilder
    static func menuItem(for item: SearchResultItem) -> some View {
        switch item {
        case let .song(song):
            Self.menuItem(for: song)
        case let .album(album):
            Self.menuItem(for: album)
        case let .playlist(playlist):
            Self.menuItem(for: playlist)
        case let .artist(artist):
            Self.menuItem(for: artist)
        }
    }

    /// Creates a share menu item for a FavoriteItem.
    @ViewBuilder
    static func menuItem(for item: FavoriteItem) -> some View {
        switch item.itemType {
        case let .song(song):
            Self.menuItem(for: song)
        case let .album(album):
            Self.menuItem(for: album)
        case let .playlist(playlist):
            Self.menuItem(for: playlist)
        case let .artist(artist):
            Self.menuItem(for: artist)
        }
    }
}
