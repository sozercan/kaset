import SwiftUI

/// A consistent set of context-menu actions for items shown in discovery shelves.
struct HomeItemContextMenu: View {
    let item: HomeSectionItem
    let client: any YTMusicClientProtocol

    @Environment(AuthService.self) private var authService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(PlayerService.self) private var playerService
    @Environment(SongLikeStatusManager.self) private var likeStatusManager

    var body: some View {
        switch self.item {
        case let .song(song):
            self.songMenu(song)
        case let .album(album):
            self.albumMenu(album)
        case let .playlist(playlist):
            self.playlistMenu(playlist)
        case let .artist(artist):
            self.artistMenu(artist)
        }
    }

    @ViewBuilder
    private func songMenu(_ song: Song) -> some View {
        Button {
            Task { await self.playerService.play(song: song) }
        } label: {
            Label(String(localized: "Play"), systemImage: "play.fill")
        }

        if self.authService.hasPersonalAccount {
            Divider()
            FavoritesContextMenu.menuItem(for: song, manager: self.favoritesManager)
            Divider()
            LikeDislikeContextMenu(song: song, likeStatusManager: self.likeStatusManager)
        }

        Divider()
        StartRadioContextMenu.menuItem(for: song, playerService: self.playerService)

        if self.authService.hasPersonalAccount {
            Divider()
            Button {
                SongActionsHelper.addToLibrary(song, playerService: self.playerService)
            } label: {
                Label(String(localized: "Add to Library"), systemImage: "plus.circle")
            }
            Divider()
            AddToPlaylistContextMenu(song: song, client: self.client)
        }

        Divider()
        ShareContextMenu.menuItem(for: song)
        Divider()
        AddToQueueContextMenu(song: song, playerService: self.playerService)

        if let artist = song.artists.first(where: { $0.hasNavigableId }) {
            Divider()
            NavigationLink(value: artist) {
                Label(String(localized: "Go to Artist"), systemImage: "person")
            }
        }

        if let album = song.album, album.hasNavigableId {
            NavigationLink(value: Self.playlist(from: album, fallbackThumbnailURL: song.thumbnailURL)) {
                Label(String(localized: "Go to Album"), systemImage: "square.stack")
            }
        }
    }

    @ViewBuilder
    private func albumMenu(_ album: Album) -> some View {
        NavigationLink(value: Self.playlist(from: album)) {
            Label(String(localized: "View Album"), systemImage: "square.stack")
        }

        Divider()
        Button {
            SongActionsHelper.playAlbum(album, client: self.client, playerService: self.playerService)
        } label: {
            Label(String(localized: "Play"), systemImage: "play.fill")
        }
        Button {
            SongActionsHelper.addAlbumToQueueNext(album, client: self.client, playerService: self.playerService)
        } label: {
            Label(String(localized: "Play Next"), systemImage: "text.insert")
        }
        Button {
            SongActionsHelper.addAlbumToQueueLast(album, client: self.client, playerService: self.playerService)
        } label: {
            Label(String(localized: "Add to Queue"), systemImage: "text.append")
        }

        if self.authService.hasPersonalAccount {
            Divider()
            FavoritesContextMenu.menuItem(for: album, manager: self.favoritesManager)
        }

        Divider()
        ShareContextMenu.menuItem(for: album)
    }

    @ViewBuilder
    private func playlistMenu(_ playlist: Playlist) -> some View {
        NavigationLink(value: playlist) {
            Label(String(localized: "View Playlist"), systemImage: "music.note.list")
        }

        if SongActionsHelper.canQuickPlayPlaylist(playlist) {
            Divider()
            Button {
                SongActionsHelper.playPlaylist(
                    playlist,
                    client: self.client,
                    playerService: self.playerService
                )
            } label: {
                Label(String(localized: "Play"), systemImage: "play.fill")
            }
        }

        if self.authService.hasPersonalAccount {
            Divider()
            FavoritesContextMenu.menuItem(for: playlist, manager: self.favoritesManager)
        }

        Divider()
        ShareContextMenu.menuItem(for: playlist)
    }

    @ViewBuilder
    private func artistMenu(_ artist: Artist) -> some View {
        NavigationLink(value: artist) {
            Label(String(localized: "View Artist"), systemImage: "person")
        }

        if self.authService.hasPersonalAccount {
            Divider()
            FavoritesContextMenu.menuItem(for: artist, manager: self.favoritesManager)
        }

        Divider()
        ShareContextMenu.menuItem(for: artist)
    }

    private static func playlist(from album: Album, fallbackThumbnailURL: URL? = nil) -> Playlist {
        Playlist(
            id: album.id,
            title: album.title,
            description: nil,
            thumbnailURL: album.thumbnailURL ?? fallbackThumbnailURL,
            trackCount: album.trackCount,
            author: Artist.inline(name: album.artistsDisplay, namespace: "album-artist")
        )
    }
}
