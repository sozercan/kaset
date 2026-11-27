import SwiftUI

@MainActor
enum FavoritesContextMenu {
    static func menuItem(for song: Song, manager: FavoritesManager) -> some View {
        FavoriteContextMenuItem(
            isPinned: manager.isPinned(song: song),
            canMutate: manager.canMutate,
            toggle: { manager.toggle(song: song) }
        )
    }

    static func menuItem(for album: Album, manager: FavoritesManager) -> some View {
        FavoriteContextMenuItem(
            isPinned: manager.isPinned(album: album),
            canMutate: manager.canMutate,
            toggle: { manager.toggle(album: album) }
        )
    }

    static func menuItem(for playlist: Playlist, manager: FavoritesManager) -> some View {
        FavoriteContextMenuItem(
            isPinned: manager.isPinned(playlist: playlist),
            canMutate: manager.canMutate,
            toggle: { manager.toggle(playlist: playlist) }
        )
    }

    static func menuItem(for artist: Artist, manager: FavoritesManager) -> some View {
        FavoriteContextMenuItem(
            isPinned: manager.isPinned(artist: artist),
            canMutate: manager.canMutate,
            toggle: { manager.toggle(artist: artist) }
        )
    }

    static func menuItem(for podcastShow: PodcastShow, manager: FavoritesManager) -> some View {
        FavoriteContextMenuItem(
            isPinned: manager.isPinned(podcastShow: podcastShow),
            canMutate: manager.canMutate,
            toggle: { manager.toggle(podcastShow: podcastShow) }
        )
    }

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

    @ViewBuilder
    static func menuItem(for item: SearchResultItem, manager: FavoritesManager) -> some View {
        switch item {
        case let .song(song), let .video(song):
            Self.menuItem(for: song, manager: manager)
        case let .album(album), let .audiobook(album):
            Self.menuItem(for: album, manager: manager)
        case let .playlist(playlist):
            Self.menuItem(for: playlist, manager: manager)
        case let .artist(artist), let .profile(artist):
            Self.menuItem(for: artist, manager: manager)
        case let .podcastShow(show):
            Self.menuItem(for: show, manager: manager)
        case .podcastEpisode:
            EmptyView()
        }
    }
}

private struct FavoriteContextMenuItem: View {
    let isPinned: Bool
    let canMutate: Bool
    let toggle: @MainActor () -> Void

    @Environment(AuthService.self) private var authService

    var body: some View {
        if self.authService.hasPersonalAccount, self.canMutate {
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
