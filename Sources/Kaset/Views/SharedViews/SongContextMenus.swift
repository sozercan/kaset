import Foundation
import SwiftUI

struct LikeDislikeContextMenu: View {
    let song: Song
    let likeStatusManager: SongLikeStatusManager

    @Environment(AuthService.self) private var authService

    var body: some View {
        if self.authService.hasPersonalAccount {
            self.menuItems
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if self.likeStatusManager.isLiked(self.song) {
            Button {
                SongActionsHelper.unlikeSong(self.song, likeStatusManager: self.likeStatusManager)
            } label: {
                Label(String(localized: "Unlike"), systemImage: "hand.thumbsup.fill")
            }
        } else {
            Button {
                SongActionsHelper.likeSong(self.song, likeStatusManager: self.likeStatusManager)
            } label: {
                Label(String(localized: "Like"), systemImage: "hand.thumbsup")
            }

            if self.likeStatusManager.isDisliked(self.song) {
                Button {
                    SongActionsHelper.undislikeSong(self.song, likeStatusManager: self.likeStatusManager)
                } label: {
                    Label(String(localized: "Remove Dislike"), systemImage: "hand.thumbsdown.fill")
                }
            } else {
                Button {
                    SongActionsHelper.dislikeSong(self.song, likeStatusManager: self.likeStatusManager)
                } label: {
                    Label(String(localized: "Dislike"), systemImage: "hand.thumbsdown")
                }
            }
        }
    }
}

struct AddToQueueContextMenu: View {
    let song: Song
    let playerService: PlayerService

    var body: some View {
        Button {
            SongActionsHelper.addToQueueNext(self.song, playerService: self.playerService)
        } label: {
            Label(String(localized: "Play Next"), systemImage: "text.insert")
        }

        Button {
            SongActionsHelper.addToQueueLast(self.song, playerService: self.playerService)
        } label: {
            Label(String(localized: "Add to Queue"), systemImage: "text.append")
        }
    }
}

struct AddToPlaylistContextMenu: View {
    let song: Song
    let client: any YTMusicClientProtocol

    @Environment(AuthService.self) private var authService
    @Environment(PlayerService.self) private var playerService

    @State private var loadState: PlaylistLoadState = .idle
    @State private var isCreatingPlaylist = false

    private static let playlistLoadTimeout: Duration = .seconds(12)

    private enum PlaylistLoadError: Error {
        case timedOut
    }

    private enum PlaylistLoadState {
        case idle
        case loading
        case loaded(AddToPlaylistMenu)
        case failed(String)
    }

    var body: some View {
        if self.authService.hasPersonalAccount {
            self.menu
        }
    }

    private var menu: some View {
        Menu {
            Group {
                switch self.loadState {
                case .idle, .loading:
                    Label(String(localized: "Loading Playlists…"), systemImage: "hourglass")

                case let .loaded(menu):
                    if menu.options.isEmpty {
                        Label(String(localized: "No Playlists"), systemImage: "music.note.list")
                    } else {
                        ForEach(menu.options) { option in
                            Button {
                                Task {
                                    await SongActionsHelper.addSongToPlaylist(
                                        self.song,
                                        playlist: option,
                                        client: self.client
                                    )
                                }
                            } label: {
                                Label(
                                    option.title,
                                    systemImage: option.isSelected ? "checkmark.circle.fill" : "music.note.list"
                                )
                            }
                            .disabled(option.isSelected)
                        }
                    }

                case let .failed(errorMessage):
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                    Button {
                        Task { await self.loadPlaylists(forceRefresh: true) }
                    } label: {
                        Label(String(localized: "Retry Loading Playlists"), systemImage: "arrow.clockwise")
                    }
                }

                if self.canCreatePlaylist {
                    Divider()
                    self.createPlaylistButton
                }
            }
            .onAppear {
                self.startLoadingPlaylistsIfNeeded()
            }
        } label: {
            Label(String(localized: "Add to Playlist"), systemImage: "text.badge.plus")
        }
        .onAppear {
            self.startLoadingPlaylistsIfNeeded()
        }
    }

    private var canCreatePlaylist: Bool {
        guard case let .loaded(menu) = self.loadState else { return false }
        return menu.canCreatePlaylist
    }

    private var createPlaylistButton: some View {
        Button {
            Task { @MainActor in self.presentCreatePlaylistDialog() }
        } label: {
            Label(self.isCreatingPlaylist ? "Creating Playlist…" : "Create Playlist…", systemImage: "plus.rectangle.on.rectangle")
        }
        .disabled(self.isCreatingPlaylist)
    }

    private func startLoadingPlaylistsIfNeeded() {
        guard case .idle = self.loadState else { return }

        Task { await self.loadPlaylists(forceRefresh: false) }
    }

    private func loadPlaylists(forceRefresh: Bool = false) async {
        guard !Task.isCancelled else { return }
        self.loadState = .loading
        if forceRefresh {
            APICache.shared.invalidate(matching: "playlist/get_add_to_playlist:")
        }

        do {
            let menu = try await self.fetchAddToPlaylistOptionsWithTimeout()
            self.loadState = .loaded(menu)
        } catch is CancellationError {
            self.loadState = .idle
        } catch {
            self.loadState = .failed("Unable to Load Playlists")
            DiagnosticsLogger.ui.error("Failed to load add-to-playlist options: \(error.localizedDescription)")
        }
    }

    private func fetchAddToPlaylistOptionsWithTimeout() async throws -> AddToPlaylistMenu {
        let client = self.client
        let videoId = self.song.videoId

        return try await withThrowingTaskGroup(of: AddToPlaylistMenu.self) { group in
            group.addTask {
                try await client.getAddToPlaylistOptions(videoId: videoId)
            }

            group.addTask {
                try await Task.sleep(for: Self.playlistLoadTimeout)
                throw PlaylistLoadError.timedOut
            }

            defer { group.cancelAll() }

            guard let result = try await group.next() else {
                throw CancellationError()
            }

            return result
        }
    }

    private func presentCreatePlaylistDialog() {
        guard !self.isCreatingPlaylist else { return }
        let owner = self.playerService.currentAccountMutationOwner

        SongActionsHelper.presentCreatePlaylistDialog(
            informativeText: "Create a private playlist and add \"\(self.song.title)\" to it.",
            request: SongActionsHelper.PlaylistCreationRequest(
                client: self.client,
                videoIds: [self.song.videoId],
                thumbnailURL: self.song.thumbnailURL,
                whileValid: { self.playerService.acceptsAccountMutationOwner(owner) }
            ),
            onWillCreate: {
                guard !self.isCreatingPlaylist else { return false }
                self.isCreatingPlaylist = true
                return true
            },
            completion: { result in
                self.isCreatingPlaylist = false
                guard self.playerService.acceptsAccountMutationOwner(owner) else { return }

                switch result {
                case .success:
                    Task {
                        guard self.playerService.acceptsAccountMutationOwner(owner) else { return }
                        await self.loadPlaylists(forceRefresh: true)
                    }
                case let .failure(failure):
                    self.loadState = .failed(failure.message)
                }
            }
        )
    }
}
