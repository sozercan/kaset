import AppIntents
import CoreSpotlight
import Foundation

// MARK: - LibrarySpotlightIndex

/// Where Library entities are indexed. Abstracted so tests do not touch the user's index.
protocol LibrarySpotlightIndex: Sendable {
    /// Replaces every indexed playlist and album with these.
    func replaceAll(playlists: [PlaylistEntity], albums: [AlbumEntity]) async throws
}

// MARK: - CoreSpotlightLibraryIndex

struct CoreSpotlightLibraryIndex: LibrarySpotlightIndex {
    func replaceAll(playlists: [PlaylistEntity], albums: [AlbumEntity]) async throws {
        let index = CSSearchableIndex.default()
        try await index.deleteAppEntities(ofType: PlaylistEntity.self)
        try await index.deleteAppEntities(ofType: AlbumEntity.self)
        if !playlists.isEmpty {
            try await index.indexAppEntities(playlists)
        }
        if !albums.isEmpty {
            try await index.indexAppEntities(albums)
        }
    }
}

// MARK: - SpotlightLibraryIndexer

/// Keeps Spotlight's copy of the Library in step with the signed-in account.
///
/// The index is replaced wholesale: Library snapshots are small, and replacing avoids leaving
/// another account's items behind after a switch or sign-out (an empty Library clears it).
@MainActor
final class SpotlightLibraryIndexer {
    /// Library loads publish several snapshots in quick succession.
    static let defaultDebounce: Duration = .seconds(1)
    /// A failed replacement is retried after this delay, doubling each time.
    static let defaultRetryDelay: Duration = .seconds(5)
    static let maxAttempts = 3

    private let index: any LibrarySpotlightIndex
    private let debounce: Duration
    private let retryDelay: Duration
    private var indexedLibrary: AppIntentsLibrary?
    private var pendingTask: Task<Void, Never>?
    private let logger = DiagnosticsLogger.appIntents

    init(
        index: any LibrarySpotlightIndex = CoreSpotlightLibraryIndex(),
        debounce: Duration = defaultDebounce,
        retryDelay: Duration = defaultRetryDelay
    ) {
        self.index = index
        self.debounce = debounce
        self.retryDelay = retryDelay
    }

    func update(_ library: AppIntentsLibrary) {
        guard library != self.indexedLibrary else { return }
        self.indexedLibrary = library

        let playlists = library.playablePlaylists.map(PlaylistEntity.init(playlist:))
        let albums = library.playableAlbums.map(AlbumEntity.init(album:))
        let previousTask = self.pendingTask
        previousTask?.cancel()
        self.pendingTask = Task { [index, debounce, retryDelay, logger] in
            try? await Task.sleep(for: debounce)
            // Wait even when superseded, so the next snapshot cannot overlap a replacement still in flight.
            await previousTask?.value
            var delay = retryDelay
            for attempt in 1 ... Self.maxAttempts {
                guard !Task.isCancelled else { return }
                do {
                    try await index.replaceAll(playlists: playlists, albums: albums)
                    logger.info("Indexed \(playlists.count) playlists and \(albums.count) albums in Spotlight")
                    return
                } catch {
                    logger.error("Spotlight indexing attempt \(attempt) failed: \(error.localizedDescription)")
                }
                guard attempt < Self.maxAttempts else { return }
                try? await Task.sleep(for: delay)
                delay *= 2
            }
        }
    }

    /// Waits for the latest scheduled replacement. For tests.
    func waitForPendingUpdate() async {
        await self.pendingTask?.value
    }
}
