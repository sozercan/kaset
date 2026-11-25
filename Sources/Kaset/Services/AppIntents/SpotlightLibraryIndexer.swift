import AppIntents
import CoreSpotlight
import Foundation

protocol LibrarySpotlightIndex: Sendable {
    func replaceAll(playlists: [PlaylistEntity], albums: [AlbumEntity]) async throws
}

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

@MainActor
final class SpotlightLibraryIndexer {
    static let defaultDebounce: Duration = .seconds(1)
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

    func waitForPendingUpdate() async {
        await self.pendingTask?.value
    }
}
