import Foundation
import Testing
@testable import Kaset

/// Tests for PlayerService queue operations, undo/redo, and metadata enrichment.
@Suite("PlayerService Queue", .serialized, .tags(.service))
@MainActor
struct PlayerServiceQueueTests {
    var playerService: PlayerService
    var mockClient: MockYTMusicClient

    init() {
        // Clean up UserDefaults before each test
        UserDefaults.standard.removeObject(forKey: "kaset.saved.queue")
        UserDefaults.standard.removeObject(forKey: "kaset.saved.queueIndex")

        self.mockClient = MockYTMusicClient()
        self.playerService = PlayerService()
        self.playerService.setYTMusicClient(self.mockClient)
    }

    // MARK: - Queue Reordering Tests

    @Test("Reorder queue moves song from source to destination")
    func reorderQueue() async {
        // Arrange
        let songs = TestFixtures.makeSongs(count: 5)
        await self.playerService.playQueue(songs, startingAt: 0)

        // Verify initial order
        #expect(self.playerService.queue.count == 5)
        #expect(self.playerService.queue[0].title == "Song 0")
        #expect(self.playerService.queue[4].title == "Song 4")

        // Act - Move song at index 4 to index 1
        self.playerService.reorderQueue(from: IndexSet(integer: 4), to: 1)

        // Assert
        #expect(self.playerService.queue[0].title == "Song 0")
        #expect(self.playerService.queue[1].title == "Song 4") // Moved song
        #expect(self.playerService.queue[2].title == "Song 1")
        #expect(self.playerService.queue[3].title == "Song 2")
        #expect(self.playerService.queue[4].title == "Song 3")
    }

    @Test("Reorder queue with invalid indices does nothing")
    func reorderQueueInvalidIndices() async {
        // Arrange
        let songs = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(songs, startingAt: 0)
        let originalOrder = self.playerService.queue.map(\.title)

        // Act - Try to reorder with out of bounds index
        self.playerService.reorderQueue(from: IndexSet(integer: 10), to: 1)

        // Assert - Queue unchanged
        #expect(self.playerService.queue.map(\.title) == originalOrder)
    }

    @Test("Reorder queue updates current index correctly when moving before current")
    func reorderQueueUpdatesCurrentIndexBefore() async {
        // Arrange - Current index is 2
        let songs = TestFixtures.makeSongs(count: 5)
        await self.playerService.playQueue(songs, startingAt: 2)
        #expect(self.playerService.currentIndex == 2)

        // Act - Move song at index 4 to index 0 (before current)
        self.playerService.reorderQueue(from: IndexSet(integer: 4), to: 0)

        // Assert - Current index should increment
        #expect(self.playerService.currentIndex == 3)
    }

    @Test("Reorder queue updates current index correctly when moving after current")
    func reorderQueueUpdatesCurrentIndexAfter() async {
        // Arrange - Current index is 2
        let songs = TestFixtures.makeSongs(count: 5)
        await self.playerService.playQueue(songs, startingAt: 2)
        #expect(self.playerService.currentIndex == 2)

        // Act - Move song at index 0 to index 4 (after current)
        self.playerService.reorderQueue(from: IndexSet(integer: 0), to: 5)

        // Assert - Current index should decrement
        #expect(self.playerService.currentIndex == 1)
    }

    // MARK: - Undo/Redo Tests

    @Test("Undo restores previous queue state")
    func undoQueue() async {
        // Arrange
        let songs = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(songs, startingAt: 0)
        let originalQueue = self.playerService.queue

        // Act - Make a change, then undo
        // clearQueue() keeps the current track, so queue has 1 item
        self.playerService.clearQueue()
        #expect(self.playerService.queue.count == 1)

        self.playerService.undoQueue()

        // Assert
        #expect(self.playerService.queue.count == originalQueue.count)
        #expect(self.playerService.queue[0].title == originalQueue[0].title)
    }

    @Test("Redo restores undone queue state")
    func redoQueue() async {
        // Arrange
        let songs = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(songs, startingAt: 0)

        // Act - Clear, undo, then redo
        self.playerService.clearQueue()
        self.playerService.undoQueue()
        #expect(!self.playerService.queue.isEmpty)

        self.playerService.redoQueue()

        // Assert - clearQueue() keeps the current track, so queue has 1 item
        #expect(self.playerService.queue.count == 1)
    }

    @Test("Can undo returns correct state")
    func canUndo() async {
        // Arrange
        let songs = TestFixtures.makeSongs(count: 3)

        // Assert - Initially can't undo
        #expect(self.playerService.canUndoQueue == false)

        // Act
        await self.playerService.playQueue(songs, startingAt: 0)

        // Assert - Can undo after state change
        #expect(self.playerService.canUndoQueue == true)

        // Act - Undo all history
        self.playerService.undoQueue()

        // Assert - Can't undo anymore
        #expect(self.playerService.canUndoQueue == false)
    }

    @Test("Can redo returns correct state")
    func canRedo() async {
        // Arrange
        let songs = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(songs, startingAt: 0)

        // Assert - Initially can't redo
        #expect(self.playerService.canRedoQueue == false)

        // Act
        self.playerService.clearQueue()
        self.playerService.undoQueue()

        // Assert - Can redo after undo
        #expect(self.playerService.canRedoQueue == true)

        // Act
        self.playerService.redoQueue()

        // Assert - Can't redo anymore
        #expect(self.playerService.canRedoQueue == false)
    }

    @Test("Multiple undo operations work correctly")
    func multipleUndoOperations() async {
        // Arrange - Create 3 different states
        let songs1 = TestFixtures.makeSongs(count: 3)
        let songs2 = TestFixtures.makeSongs(count: 2)
        let songs3 = TestFixtures.makeSongs(count: 4)

        await self.playerService.playQueue(songs1, startingAt: 0)
        await self.playerService.playQueue(songs2, startingAt: 0)
        await self.playerService.playQueue(songs3, startingAt: 0)

        #expect(self.playerService.queue.count == 4)

        // Act - Undo multiple times
        self.playerService.undoQueue()
        #expect(self.playerService.queue.count == 2)

        self.playerService.undoQueue()
        #expect(self.playerService.queue.count == 3)
    }

    @Test("Undo history limit is enforced (10 states)")
    func undoHistoryLimit() async {
        // Arrange - Create more than 10 states
        for i in 1 ... 12 {
            let songs = TestFixtures.makeSongs(count: i)
            await self.playerService.playQueue(songs, startingAt: 0)
        }

        // Act - Undo 10 times (should work)
        for _ in 1 ... 10 {
            self.playerService.undoQueue()
        }

        // The 11th undo should not change anything (oldest state dropped)
        let queueAfter10Undos = self.playerService.queue.count
        self.playerService.undoQueue()

        // Assert - Queue unchanged after 10 undos
        #expect(self.playerService.queue.count == queueAfter10Undos)
    }

    // MARK: - Queue Persistence Tests

    @Test("Save and restore queue persists data correctly")
    func queuePersistence() async {
        // Arrange
        let songs = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(songs, startingAt: 1)

        // Act
        self.playerService.saveQueueForPersistence()

        // Create new service instance and restore
        let newService = PlayerService()
        newService.setYTMusicClient(self.mockClient)
        let restored = newService.restoreQueueFromPersistence()

        // Assert
        #expect(restored == true)
        #expect(newService.queue.count == 3)
        #expect(newService.currentIndex == 1)
        #expect(newService.queue[0].title == "Song 0")
    }

    @Test("Clear saved queue removes persistence data")
    func clearSavedQueue() async {
        // Arrange
        let songs = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.saveQueueForPersistence()

        // Act
        self.playerService.clearSavedQueue()

        // Create new service and try to restore
        let newService = PlayerService()
        newService.setYTMusicClient(self.mockClient)
        let restored = newService.restoreQueueFromPersistence()

        // Assert
        #expect(restored == false)
        #expect(newService.queue.isEmpty)
    }

    @Test("Restore queue with invalid data returns false")
    func restoreInvalidQueue() {
        // Arrange - Put invalid data in UserDefaults
        UserDefaults.standard.set(Data("invalid data".utf8), forKey: "kaset.saved.queue")
        UserDefaults.standard.set(0, forKey: "kaset.saved.queueIndex")

        // Act
        let restored = self.playerService.restoreQueueFromPersistence()

        // Assert
        #expect(restored == false)
    }

    // MARK: - Metadata Enrichment Tests

    @Test("Identify songs needing enrichment detects missing metadata")
    func identifySongsNeedingEnrichment() async {
        // Arrange - Create songs with incomplete metadata
        let completeSong = TestFixtures.makeSong(id: "complete", title: "Complete Song", artistName: "Test Artist")
        let incompleteSong = Song(
            id: "incomplete",
            title: "Loading...",
            artists: [],
            videoId: "incomplete"
        )

        await playerService.playQueue([completeSong, incompleteSong], startingAt: 0)

        // Act
        let needingEnrichment = self.playerService.identifySongsNeedingEnrichment()

        // Assert
        #expect(needingEnrichment.count == 1)
        #expect(needingEnrichment[0].videoId == "incomplete")
    }

    @Test("Enrich queue metadata fetches and updates incomplete songs")
    func enrichQueueMetadata() async {
        // Arrange
        let incompleteSong = Song(
            id: "test-id",
            title: "Loading...",
            artists: [],
            videoId: "test-id"
        )

        let enrichedSong = Song(
            id: "test-id",
            title: "Enriched Title",
            artists: [Artist(id: "artist-1", name: "Enriched Artist")],
            videoId: "test-id"
        )

        self.mockClient.songResponses["test-id"] = enrichedSong
        await self.playerService.playQueue([incompleteSong], startingAt: 0)

        // Act
        await self.playerService.enrichQueueMetadata()

        // Assert
        #expect(self.mockClient.getSongCalled == true)
        #expect(self.playerService.queue[0].title == "Enriched Title")
        #expect(self.playerService.queue[0].artists[0].name == "Enriched Artist")
    }

    @Test("Metadata enrichment updates queue during playback")
    func metadataEnrichmentDuringPlayback() async {
        // Arrange
        let incompleteSong = Song(
            id: "playback-test",
            title: "Loading...",
            artists: [],
            videoId: "playback-test"
        )

        let enrichedSong = Song(
            id: "playback-test",
            title: "Enriched During Playback",
            artists: [Artist(id: "artist-1", name: "Playback Artist")],
            videoId: "playback-test"
        )

        self.mockClient.songResponses["playback-test"] = enrichedSong
        await self.playerService.playQueue([incompleteSong], startingAt: 0)

        // Act - Simulate playback which triggers fetchSongMetadata
        await self.playerService.play(song: incompleteSong)

        // Wait a bit for async operations
        try? await Task.sleep(for: .milliseconds(100))

        // Assert - Queue should be updated
        #expect(self.playerService.queue[0].title == "Enriched During Playback")
        #expect(self.playerService.queue[0].artists[0].name == "Playback Artist")
    }

    @Test("Enrichment does not overwrite good data with worse data")
    func enrichmentPreservesGoodData() async {
        // Arrange
        let completeSong = Song(
            id: "complete-id",
            title: "Good Title",
            artists: [Artist(id: "artist-1", name: "Good Artist")],
            videoId: "complete-id"
        )

        let differentSong = Song(
            id: "complete-id",
            title: "Different Title",
            artists: [Artist(id: "artist-2", name: "Different Artist")],
            videoId: "complete-id"
        )

        self.mockClient.songResponses["complete-id"] = differentSong
        await self.playerService.playQueue([completeSong], startingAt: 0)

        // Act
        await self.playerService.play(song: completeSong)
        try? await Task.sleep(for: .milliseconds(100))

        // Assert - Queue entry was enriched because thumbnailURL was nil (triggers needsUpdate)
        #expect(self.playerService.queue[0].title == "Different Title")
        #expect(self.playerService.queue[0].artists[0].name == "Different Artist")
    }

    @Test("Metadata enrichment handles API errors gracefully")
    func enrichmentHandlesErrors() async {
        // Arrange
        let incompleteSong = Song(
            id: "error-test",
            title: "Loading...",
            artists: [],
            videoId: "error-test"
        )

        self.mockClient.shouldThrowError = NSError(domain: "Test", code: 500)
        await self.playerService.playQueue([incompleteSong], startingAt: 0)

        // Act - Should not throw
        await self.playerService.enrichQueueMetadata()

        // Assert - Queue unchanged but no crash
        #expect(self.playerService.queue[0].title == "Loading...")
        #expect(self.mockClient.getSongCalled == true)
    }

    // MARK: - Queue Display Mode Tests

    @Test("Toggle queue display mode switches between popup and side panel")
    func toggleQueueDisplayMode() {
        // Arrange
        let initialMode = self.playerService.queueDisplayMode

        // Act
        self.playerService.toggleQueueDisplayMode()

        // Assert
        #expect(self.playerService.queueDisplayMode != initialMode)

        // Act again
        self.playerService.toggleQueueDisplayMode()

        // Assert - Back to original
        #expect(self.playerService.queueDisplayMode == initialMode)
    }

    @Test("Queue display mode persists to UserDefaults")
    func queueDisplayModePersistence() {
        // Arrange
        self.playerService.queueDisplayMode = .popup

        // Act
        self.playerService.toggleQueueDisplayMode()

        // Assert
        let savedMode = UserDefaults.standard.string(forKey: "kaset.queue.displayMode")
        #expect(savedMode == QueueDisplayMode.sidepanel.rawValue)
    }
}
