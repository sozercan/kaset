import Foundation
import Testing
@testable import Kaset

// MARK: - SpotlightLibraryIndexerTests

@Suite("Spotlight Library indexer", .serialized, .tags(.service))
@MainActor
struct SpotlightLibraryIndexerTests {
    /// Records replacements instead of touching the user's Spotlight index.
    private actor RecordingIndex: LibrarySpotlightIndex {
        private(set) var replacements: [(playlists: [String], albums: [String])] = []

        func replaceAll(playlists: [PlaylistEntity], albums: [AlbumEntity]) async throws {
            self.replacements.append((playlists.map(\.id), albums.map(\.id)))
        }
    }

    /// Fails the first `failures` replacements.
    private actor FlakyIndex: LibrarySpotlightIndex {
        private var failures: Int
        private(set) var attempts = 0

        init(failures: Int) {
            self.failures = failures
        }

        func replaceAll(playlists _: [PlaylistEntity], albums _: [AlbumEntity]) async throws {
            self.attempts += 1
            if self.failures > 0 {
                self.failures -= 1
                throw URLError(.cannotWriteToFile)
            }
        }
    }

    /// Holds the first replacement open and records how many ever overlap.
    private actor GatedIndex: LibrarySpotlightIndex {
        let firstStarted = AsyncGate()
        let releaseFirst = AsyncGate()
        private(set) var started: [[String]] = []
        private(set) var maxConcurrent = 0
        private var inFlight = 0

        func replaceAll(playlists: [PlaylistEntity], albums _: [AlbumEntity]) async throws {
            self.inFlight += 1
            self.maxConcurrent = max(self.maxConcurrent, self.inFlight)
            self.started.append(playlists.map(\.id))
            if self.started.count == 1 {
                await self.firstStarted.open()
                await self.releaseFirst.wait()
            }
            self.inFlight -= 1
        }
    }

    private func makeLibrary(playlistIDs: [String], albumIDs: [String] = []) -> AppIntentsLibrary {
        AppIntentsLibrary(
            playlists: playlistIDs.map { TestFixtures.makePlaylist(id: $0, title: $0) },
            albums: albumIDs.map { TestFixtures.makeAlbum(id: $0, title: $0) }
        )
    }

    @Test("Quick successive snapshots coalesce into one replacement with the latest")
    func coalescesUpdates() async {
        let index = RecordingIndex()
        let indexer = SpotlightLibraryIndexer(index: index, debounce: .milliseconds(30))

        indexer.update(self.makeLibrary(playlistIDs: ["PL-first"]))
        indexer.update(self.makeLibrary(playlistIDs: ["PL-first", "PL-second"], albumIDs: ["MPREb_album"]))
        await indexer.waitForPendingUpdate()

        let replacements = await index.replacements
        #expect(replacements.count == 1)
        #expect(replacements.first?.playlists == ["PL-first", "PL-second"])
        #expect(replacements.first?.albums == ["MPREb_album"])
    }

    @Test("An unchanged snapshot does not reindex")
    func skipsUnchangedLibrary() async {
        let index = RecordingIndex()
        let indexer = SpotlightLibraryIndexer(index: index, debounce: .milliseconds(10))
        let library = self.makeLibrary(playlistIDs: ["PL-same"])

        indexer.update(library)
        await indexer.waitForPendingUpdate()
        indexer.update(library)
        await indexer.waitForPendingUpdate()

        #expect(await index.replacements.count == 1)
    }

    @Test("Uploads and albums without a playable ID are not indexed")
    func indexesOnlyPlayableItems() async {
        let index = RecordingIndex()
        let indexer = SpotlightLibraryIndexer(index: index, debounce: .milliseconds(10))

        indexer.update(self.makeLibrary(
            playlistIDs: [Playlist.uploadedSongsBrowseID, "PL-kept"],
            albumIDs: ["MPREb_kept", UUID().uuidString]
        ))
        await indexer.waitForPendingUpdate()

        let replacement = await index.replacements.first
        #expect(replacement?.playlists == ["PL-kept"])
        #expect(replacement?.albums == ["MPREb_kept"])
    }

    @Test("Signing out clears the index")
    func emptyLibraryClearsIndex() async {
        let index = RecordingIndex()
        let indexer = SpotlightLibraryIndexer(index: index, debounce: .milliseconds(10))

        indexer.update(self.makeLibrary(playlistIDs: ["PL-signed-in"]))
        await indexer.waitForPendingUpdate()
        indexer.update(.empty)
        await indexer.waitForPendingUpdate()

        let replacements = await index.replacements
        #expect(replacements.count == 2)
        #expect(replacements.last?.playlists.isEmpty == true)
        #expect(replacements.last?.albums.isEmpty == true)
    }

    @Test("A failed replacement is retried a bounded number of times")
    func retriesFailedReplacement() async {
        let recovering = FlakyIndex(failures: 2)
        let recoveringIndexer = SpotlightLibraryIndexer(index: recovering, debounce: .zero, retryDelay: .milliseconds(1))
        recoveringIndexer.update(self.makeLibrary(playlistIDs: ["PL-retry"]))
        await recoveringIndexer.waitForPendingUpdate()
        #expect(await recovering.attempts == 3)

        let broken = FlakyIndex(failures: .max)
        let brokenIndexer = SpotlightLibraryIndexer(index: broken, debounce: .zero, retryDelay: .milliseconds(1))
        brokenIndexer.update(self.makeLibrary(playlistIDs: ["PL-retry"]))
        await brokenIndexer.waitForPendingUpdate()
        #expect(await broken.attempts == SpotlightLibraryIndexer.maxAttempts)
    }

    @Test("A superseded update still waits for the replacement in flight")
    func supersededUpdateStaysSerialized() async {
        let index = GatedIndex()
        let indexer = SpotlightLibraryIndexer(index: index, debounce: .zero)

        indexer.update(self.makeLibrary(playlistIDs: ["PL-first"]))
        await index.firstStarted.wait()
        indexer.update(self.makeLibrary(playlistIDs: ["PL-superseded"]))
        indexer.update(self.makeLibrary(playlistIDs: ["PL-latest"]))
        // Gives an unserialized replacement time to start before the first one finishes.
        try? await Task.sleep(for: .milliseconds(50))
        await index.releaseFirst.open()
        await indexer.waitForPendingUpdate()

        #expect(await index.maxConcurrent == 1)
        #expect(await index.started == [["PL-first"], ["PL-latest"]])
    }
}

// MARK: - AppIntentsEntityTests

@Suite("App Intents entities", .tags(.service))
@MainActor
struct AppIntentsEntityTests {
    @Test("A song entity carries the song's display metadata")
    func songEntityMapsSong() {
        let song = Song(
            id: "song-id",
            title: "Get Lucky",
            artists: [Artist(id: "UC1", name: "Daft Punk"), Artist(id: "UC2", name: "Pharrell Williams")],
            album: TestFixtures.makeAlbum(title: "Random Access Memories"),
            thumbnailURL: URL(string: "https://example.com/art.jpg"),
            videoId: "video-id"
        )

        let entity = SongEntity(song: song)

        #expect(entity.id == "video-id")
        #expect(entity.title == "Get Lucky")
        #expect(entity.artist == "Daft Punk, Pharrell Williams")
        #expect(entity.album == "Random Access Memories")
        #expect(entity.song.videoId == "video-id")
        #expect(entity.song.title == "Get Lucky")
    }

    @Test("Title matching ignores case, diacritics, and blank queries")
    func titleMatching() {
        #expect(AppIntentsSearch.title("Beyoncé Essentials", matches: "beyonce"))
        #expect(AppIntentsSearch.title("Road Trip", matches: "  TRIP "))
        #expect(!AppIntentsSearch.title("Road Trip", matches: "   "))
        #expect(!AppIntentsSearch.title("Road Trip", matches: "workout"))
    }

    @Test("Merging keeps preferred items first and drops duplicate IDs")
    func mergeDeduplicates() {
        let merged = AppIntentsSearch.merge(["a", "b"], ["b", "c", "a", "d"]) { $0 }
        #expect(merged == ["a", "b", "c", "d"])
    }
}
