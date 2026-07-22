import os
import SwiftUI

@available(macOS 26.0, *)
extension PlaylistDetailView {
    func toggleLibrary(_ detail: PlaylistDetail) {
        guard !self.isUpdatingLibrary else { return }

        let currentlyInLibrary = self.isInLibrary
        self.isUpdatingLibrary = true
        Task { @MainActor in
            defer { self.isUpdatingLibrary = false }
            let mutationApplied: @MainActor @Sendable () -> Void = {
                self.isUpdatingLibrary = false
            }
            do {
                if detail.isAlbum {
                    guard let targetPlaylistId = detail.libraryTargetId else {
                        DiagnosticsLogger.api.error(
                            "Album library target is unavailable for \(detail.id, privacy: .public)"
                        )
                        HapticService.error()
                        return
                    }
                    let album = Album(
                        id: detail.id,
                        title: detail.title,
                        artists: detail.author.map { [$0] },
                        thumbnailURL: detail.thumbnailURL,
                        year: nil,
                        trackCount: detail.trackCount,
                        libraryTargetId: targetPlaylistId
                    )

                    if currentlyInLibrary {
                        try await SongActionsHelper.removeAlbumFromLibrary(
                            album,
                            targetPlaylistId: targetPlaylistId,
                            client: self.viewModel.client,
                            libraryViewModel: self.libraryViewModel,
                            onMutationApplied: mutationApplied
                        )
                    } else {
                        try await SongActionsHelper.addAlbumToLibrary(
                            album,
                            targetPlaylistId: targetPlaylistId,
                            client: self.viewModel.client,
                            libraryViewModel: self.libraryViewModel,
                            onMutationApplied: mutationApplied
                        )
                    }
                } else if currentlyInLibrary {
                    try await SongActionsHelper.removePlaylistFromLibrary(
                        self.playlist,
                        client: self.viewModel.client,
                        libraryViewModel: self.libraryViewModel,
                        onMutationApplied: mutationApplied
                    )
                } else {
                    try await SongActionsHelper.addPlaylistToLibrary(
                        self.playlist,
                        client: self.viewModel.client,
                        libraryViewModel: self.libraryViewModel,
                        onMutationApplied: mutationApplied
                    )
                }

                HapticService.success()
            } catch is CancellationError {
                return
            } catch {
                DiagnosticsLogger.api.error("Failed to update library status: \(error.localizedDescription)")
                HapticService.error()
            }
        }
    }
}
