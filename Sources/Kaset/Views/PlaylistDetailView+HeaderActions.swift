import SwiftUI

@available(macOS 26.0, *)
extension PlaylistDetailView {
    private func makeFallbackAlbum(from detail: PlaylistDetail) -> Album {
        Album(
            id: detail.id,
            title: detail.title,
            artists: detail.author.map { [$0] },
            thumbnailURL: detail.thumbnailURL,
            year: nil,
            trackCount: detail.trackCount ?? detail.tracks.count
        )
    }

    func headerButtons(_ detail: PlaylistDetail) -> some View {
        let fallbackAlbum = self.makeFallbackAlbum(from: detail)
        let playableTracks = self.playableTracks(
            detail.tracks,
            fallbackArtist: detail.author?.name,
            fallbackAlbum: fallbackAlbum
        )

        return ViewThatFits(in: .horizontal) {
            self.headerActionButtons(
                detail,
                playableTracks: playableTracks,
                fallbackAlbum: fallbackAlbum,
                showsTitles: true
            )
            .fixedSize(horizontal: true, vertical: false)

            self.headerActionButtons(
                detail,
                playableTracks: playableTracks,
                fallbackAlbum: fallbackAlbum,
                showsTitles: false
            )
        }
    }

    private func headerActionButtons(
        _ detail: PlaylistDetail,
        playableTracks: [Song],
        fallbackAlbum: Album,
        showsTitles: Bool
    ) -> some View {
        HStack(spacing: 16) {
            self.playbackButtons(
                detail,
                playableTracks: playableTracks,
                fallbackAlbum: fallbackAlbum,
                showsTitles: showsTitles
            )

            self.sidebarButton(detail, showsTitles: showsTitles)
            self.libraryButton(detail, showsTitles: showsTitles)
            self.playlistManagementButtons(detail, showsTitles: showsTitles)
        }
    }

    @ViewBuilder
    private func playbackButtons(
        _ detail: PlaylistDetail,
        playableTracks: [Song],
        fallbackAlbum: Album,
        showsTitles: Bool
    ) -> some View {
        Button {
            self.playAll(
                detail.tracks, fallbackArtist: detail.author?.name,
                fallbackAlbum: fallbackAlbum
            )
        } label: {
            self.headerActionLabel(localized: "Play", systemImage: "play.fill", showsTitle: showsTitles)
                .foregroundStyle(.white)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(playableTracks.isEmpty)

        Button {
            SongActionsHelper.addSongsToQueueNext(
                playableTracks,
                playerService: self.playerService,
                fallbackArtist: detail.author?.name,
                fallbackAlbum: fallbackAlbum
            )
        } label: {
            self.headerActionLabel(localized: "Play Next", systemImage: "text.insert", showsTitle: showsTitles)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(playableTracks.isEmpty)

        Button {
            SongActionsHelper.addSongsToQueueLast(
                playableTracks,
                playerService: self.playerService,
                fallbackArtist: detail.author?.name,
                fallbackAlbum: fallbackAlbum
            )
        } label: {
            self.headerActionLabel(localized: "Add to Queue", systemImage: "text.append", showsTitle: showsTitles)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(playableTracks.isEmpty)
    }

    @ViewBuilder
    private func sidebarButton(_ detail: PlaylistDetail, showsTitles: Bool) -> some View {
        if let sidebarItem = SidebarPinnedItem.from(detail) {
            let isPinnedToSidebar = self.sidebarPinnedItemsManager?.isPinned(sidebarItem) ?? false
            Button {
                self.sidebarPinnedItemsManager?.toggle(sidebarItem)
            } label: {
                self.headerActionLabel(
                    isPinnedToSidebar ? String(localized: "In Sidebar") : String(localized: "Add to Sidebar"),
                    systemImage: isPinnedToSidebar ? "checkmark.circle.fill" : "sidebar.left",
                    showsTitle: showsTitles
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help(
                isPinnedToSidebar
                    ? String(localized: "Remove from Sidebar")
                    : String(localized: "Add to Sidebar")
            )
        }
    }

    @ViewBuilder
    private func libraryButton(_ detail: PlaylistDetail, showsTitles: Bool) -> some View {
        if !detail.isUploadedSongs {
            let currentlyInLibrary = self.isInLibrary || self.isAddedToLibrary
            let libraryTitle = currentlyInLibrary
                ? String(localized: "Added to Library")
                : String(localized: "Add to Library")
            Button {
                self.toggleLibrary()
            } label: {
                self.headerActionLabel(
                    libraryTitle,
                    systemImage: currentlyInLibrary ? "checkmark.circle.fill" : "plus.circle",
                    showsTitle: showsTitles
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func playlistManagementButtons(_ detail: PlaylistDetail, showsTitles: Bool) -> some View {
        if !detail.isAlbum, !detail.isUploadedSongs {
            Button {
                self.showRefineSheet = true
            } label: {
                self.headerActionLabel(localized: "Refine", systemImage: "sparkles", showsTitle: showsTitles)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .requiresIntelligence()

            self.deletePlaylistButton(detail, showsTitles: showsTitles)
        }
    }

    @ViewBuilder
    private func deletePlaylistButton(_ detail: PlaylistDetail, showsTitles: Bool) -> some View {
        if detail.canDelete {
            Button(role: .destructive) {
                SongActionsHelper.confirmDeletePlaylist(
                    Playlist(
                        id: detail.id,
                        title: detail.title,
                        description: detail.description,
                        thumbnailURL: detail.thumbnailURL,
                        trackCount: detail.trackCount,
                        author: detail.author,
                        canDelete: detail.canDelete
                    ),
                    client: self.viewModel.client,
                    libraryViewModel: self.libraryViewModel
                ) {
                    self.dismiss()
                }
            } label: {
                self.headerActionLabel(
                    localized: "Delete Playlist",
                    systemImage: "trash",
                    showsTitle: showsTitles
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.red)
        }
    }

    @ViewBuilder
    private func headerActionLabel(
        localized title: LocalizedStringKey,
        systemImage: String,
        showsTitle: Bool
    ) -> some View {
        if showsTitle {
            Label(title, systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
                .accessibilityLabel(Text(title))
        }
    }

    @ViewBuilder
    private func headerActionLabel(
        _ title: String,
        systemImage: String,
        showsTitle: Bool
    ) -> some View {
        if showsTitle {
            Label(title, systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
                .accessibilityLabel(title)
        }
    }
}
