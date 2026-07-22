import Foundation
import os
import SwiftUI

// MARK: - PlaylistDetailLibraryMutationActivity

struct PlaylistDetailLibraryMutationActivity {
    private(set) var operationID: UUID?

    var isActive: Bool {
        self.operationID != nil
    }

    mutating func begin() -> UUID? {
        guard self.operationID == nil else { return nil }
        let operationID = UUID()
        self.operationID = operationID
        return operationID
    }

    mutating func finish(_ operationID: UUID) {
        guard self.operationID == operationID else { return }
        self.operationID = nil
    }
}

@available(macOS 26.0, *)
extension PlaylistDetailView {
    func toggleLibrary(_ detail: PlaylistDetail) {
        var activity = self.libraryMutationActivity
        guard let operationID = activity.begin() else { return }
        self.libraryMutationActivity = activity

        let currentlyInLibrary = self.isInLibrary
        Task { @MainActor in
            defer { self.finishLibraryMutation(operationID) }
            let mutationApplied: @MainActor @Sendable () -> Void = {
                self.finishLibraryMutation(operationID)
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

    private func finishLibraryMutation(_ operationID: UUID) {
        var activity = self.libraryMutationActivity
        activity.finish(operationID)
        self.libraryMutationActivity = activity
    }
}
