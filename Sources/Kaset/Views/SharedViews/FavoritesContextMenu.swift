import SwiftUI

// MARK: - FavoritesContextMenu

/// Shared context menu items for adding/removing items from Favorites.
@MainActor
enum FavoritesContextMenu {
    /// Creates a context menu button for toggling a song in/out of Favorites.
    static func menuItem(for song: Song, manager: FavoritesManager) -> some View {
        FavoriteContextMenuItem(
            isPinned: manager.isPinned(song: song),
            toggle: { manager.toggle(song: song) }
        )
    }

    /// Creates a context menu button for toggling an album in/out of Favorites.
    static func menuItem(for album: Album, manager: FavoritesManager) -> some View {
        FavoriteContextMenuItem(
            isPinned: manager.isPinned(album: album),
            toggle: { manager.toggle(album: album) }
        )
    }

    /// Creates a context menu button for toggling a playlist in/out of Favorites.
    static func menuItem(for playlist: Playlist, manager: FavoritesManager) -> some View {
        FavoriteContextMenuItem(
            isPinned: manager.isPinned(playlist: playlist),
            toggle: { manager.toggle(playlist: playlist) }
        )
    }

    /// Creates a context menu button for toggling an artist in/out of Favorites.
    static func menuItem(for artist: Artist, manager: FavoritesManager) -> some View {
        FavoriteContextMenuItem(
            isPinned: manager.isPinned(artist: artist),
            toggle: { manager.toggle(artist: artist) }
        )
    }

    /// Creates a context menu button for toggling a podcast show in/out of Favorites.
    static func menuItem(for podcastShow: PodcastShow, manager: FavoritesManager) -> some View {
        FavoriteContextMenuItem(
            isPinned: manager.isPinned(podcastShow: podcastShow),
            toggle: { manager.toggle(podcastShow: podcastShow) }
        )
    }

    /// Creates a context menu button for toggling a HomeSectionItem in/out of Favorites.
    @ViewBuilder
    static func menuItem(for item: HomeSectionItem, manager: FavoritesManager) -> some View {
        switch item {
        case let .song(song):
            Self.menuItem(for: song, manager: manager)
        case let .album(album):
            Self.menuItem(for: album, manager: manager)
        case let .playlist(playlist):
            Self.menuItem(for: playlist, manager: manager)
        case let .artist(artist):
            Self.menuItem(for: artist, manager: manager)
        }
    }

    /// Creates a context menu button for toggling a SearchResultItem in/out of Favorites.
    @ViewBuilder
    static func menuItem(for item: SearchResultItem, manager: FavoritesManager) -> some View {
        switch item {
        case let .song(song):
            Self.menuItem(for: song, manager: manager)
        case let .album(album):
            Self.menuItem(for: album, manager: manager)
        case let .playlist(playlist):
            Self.menuItem(for: playlist, manager: manager)
        case let .artist(artist):
            Self.menuItem(for: artist, manager: manager)
        case let .podcastShow(show):
            Self.menuItem(for: show, manager: manager)
        }
    }
}

// MARK: - FavoriteContextMenuItem

private struct FavoriteContextMenuItem: View {
    let isPinned: Bool
    let toggle: @MainActor () -> Void

    @Environment(AuthService.self) private var authService

    var body: some View {
        if self.authService.hasPersonalAccount {
            Button {
                self.toggle()
            } label: {
                Label(
                    self.isPinned ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: self.isPinned ? "heart.slash" : "heart"
                )
            }
        }
    }
}
