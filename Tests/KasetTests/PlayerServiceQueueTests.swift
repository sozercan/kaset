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
        
        mockClient = MockYTMusicClient()
        playerService = PlayerService()
        playerService.setYTMusicClient(mockClient)
    }

    // MARK: - Queue Reordering Tests

    @Test("Reorder queue moves song from source to destination")
    func reorderQueue() async throws {
        // Arrange
        let songs = TestFixtures.makeSongs(count: 5)
        await playerService.playQueue(songs, startingAt: 0)
        
        // Verify initial order
        #expect(playerService.queue.count == 5)
        #expect(playerService.queue[0].title == "Song 0")
        #expect(playerService.queue[4].title == "Song 4")
        
        // Act - Move song at index 4 to index 1
        playerService.reorderQueue(from: IndexSet(integer: 4), to: 1)
        
        // Assert
        #expect(playerService.queue[0].title == "Song 0")
        #expect(playerService.queue[1].title == "Song 4") // Moved song
        #expect(playerService.queue[2].title == "Song 1")
        #expect(playerService.queue[3].title == "Song 2")
        #expect(playerService.queue[4].title == "Song 3")
    }

    @Test("Reorder queue with invalid indices does nothing")
    func reorderQueueInvalidIndices() async throws {
        // Arrange
        let songs = TestFixtures.makeSongs(count: 3)
        await playerService.playQueue(songs, startingAt: 0)
        let originalOrder = playerService.queue.map { $0.title }
        
        // Act - Try to reorder with out of bounds index
        playerService.reorderQueue(from: IndexSet(integer: 10), to: 1)
        
        // Assert - Queue unchanged
        #expect(playerService.queue.map { $0.title } == originalOrder)
    }

    @Test("Reorder queue updates current index correctly when moving before current")
    func reorderQueueUpdatesCurrentIndexBefore() async throws {
        // Arrange - Current index is 2
        let songs = TestFixtures.makeSongs(count: 5)
        await playerService.playQueue(songs, startingAt: 2)
        #expect(playerService.currentIndex == 2)
        
        // Act - Move song at index 4 to index 0 (before current)
        playerService.reorderQueue(from: IndexSet(integer: 4), to: 0)
        
        // Assert - Current index should increment
        #expect(playerService.currentIndex == 3)
    }

    @Test("Reorder queue updates current index correctly when moving after current")
    func reorderQueueUpdatesCurrentIndexAfter() async throws {
        // Arrange - Current index is 2
        let songs = TestFixtures.makeSongs(count: 5)
        await playerService.playQueue(songs, startingAt: 2)
        #expect(playerService.currentIndex == 2)
        
        // Act - Move song at index 0 to index 4 (after current)
        playerService.reorderQueue(from: IndexSet(integer: 0), to: 5)
        
        // Assert - Current index should decrement
        #expect(playerService.currentIndex == 1)
    }

    // MARK: - Undo/Redo Tests

    @Test("Undo restores previous queue state")
    func undoQueue() async throws {
        // Arrange
        let songs = TestFixtures.makeSongs(count: 3)
        await playerService.playQueue(songs, startingAt: 0)
        let originalQueue = playerService.queue
        
        // Act - Make a change, then undo
        playerService.clearQueue()
        #expect(playerService.queue.isEmpty)
        
        playerService.undoQueue()
        
        // Assert
        #expect(playerService.queue.count == originalQueue.count)
        #expect(playerService.queue[0].title == originalQueue[0].title)
    }

    @Test("Redo restores undone queue state")
    func redoQueue() async throws {
        // Arrange
        let songs = TestFixtures.makeSongs(count: 3)
        await playerService.playQueue(songs, startingAt: 0)
        
        // Act - Clear, undo, then redo
        playerService.clearQueue()
        playerService.undoQueue()
        #expect(!playerService.queue.isEmpty)
        
        playerService.redoQueue()
        
        // Assert
        #expect(playerService.queue.isEmpty)
    }

    @Test("Can undo returns correct state")
    func canUndo() async throws {
        // Arrange
        let songs = TestFixtures.makeSongs(count: 3)
        
        // Assert - Initially can't undo
        #expect(playerService.canUndoQueue == false)
        
        // Act
        await playerService.playQueue(songs, startingAt: 0)
        
        // Assert - Can undo after state change
        #expect(playerService.canUndoQueue == true)
        
        // Act - Undo all history
        playerService.undoQueue()
        
        // Assert - Can't undo anymore
        #expect(playerService.canUndoQueue == false)
    }

    @Test("Can redo returns correct state")
    func canRedo() async throws {
        // Arrange
        let songs = TestFixtures.makeSongs(count: 3)
        await playerService.playQueue(songs, startingAt: 0)
        
        // Assert - Initially can't redo
        #expect(playerService.canRedoQueue == false)
        
        // Act
        playerService.clearQueue()
        playerService.undoQueue()
        
        // Assert - Can redo after undo
        #expect(playerService.canRedoQueue == true)
        
        // Act
        playerService.redoQueue()
        
        // Assert - Can't redo anymore
        #expect(playerService.canRedoQueue == false)
    }

    @Test("Multiple undo operations work correctly")
    func multipleUndoOperations() async throws {
        // Arrange - Create 3 different states
        let songs1 = TestFixtures.makeSongs(count: 3)
        let songs2 = TestFixtures.makeSongs(count: 2)
        let songs3 = TestFixtures.makeSongs(count: 4)
        
        await playerService.playQueue(songs1, startingAt: 0)
        await playerService.playQueue(songs2, startingAt: 0)
        await playerService.playQueue(songs3, startingAt: 0)
        
        #expect(playerService.queue.count == 4)
        
        // Act - Undo multiple times
        playerService.undoQueue()
        #expect(playerService.queue.count == 2)
        
        playerService.undoQueue()
        #expect(playerService.queue.count == 3)
    }

    @Test("Undo history limit is enforced (10 states)")
    func undoHistoryLimit() async throws {
        // Arrange - Create more than 10 states
        for i in 1...12 {
            let songs = TestFixtures.makeSongs(count: i)
            await playerService.playQueue(songs, startingAt: 0)
        }
        
        // Act - Undo 10 times (should work)
        for _ in 1...10 {
            playerService.undoQueue()
        }
        
        // The 11th undo should not change anything (oldest state dropped)
        let queueAfter10Undos = playerService.queue.count
        playerService.undoQueue()
        
        // Assert - Queue unchanged after 10 undos
        #expect(playerService.queue.count == queueAfter10Undos)
    }

    // MARK: - Queue Persistence Tests

    @Test("Save and restore queue persists data correctly")
    func queuePersistence() async throws {
        // Arrange
        let songs = TestFixtures.makeSongs(count: 3)
        await playerService.playQueue(songs, startingAt: 1)
        
        // Act
        playerService.saveQueueForPersistence()
        
        // Create new service instance and restore
        let newService = PlayerService()
        newService.setYTMusicClient(mockClient)
        let restored = newService.restoreQueueFromPersistence()
        
        // Assert
        #expect(restored == true)
        #expect(newService.queue.count == 3)
        #expect(newService.currentIndex == 1)
        #expect(newService.queue[0].title == "Song 0")
    }

    @Test("Clear saved queue removes persistence data")
    func clearSavedQueue() async throws {
        // Arrange
        let songs = TestFixtures.makeSongs(count: 3)
        await playerService.playQueue(songs, startingAt: 0)
        playerService.saveQueueForPersistence()
        
        // Act
        playerService.clearSavedQueue()
        
        // Create new service and try to restore
        let newService = PlayerService()
        newService.setYTMusicClient(mockClient)
        let restored = newService.restoreQueueFromPersistence()
        
        // Assert
        #expect(restored == false)
        #expect(newService.queue.isEmpty)
    }

    @Test("Restore queue with invalid data returns false")
    func restoreInvalidQueue() {
        // Arrange - Put invalid data in UserDefaults
        UserDefaults.standard.set("invalid data".data(using: .utf8), forKey: "kaset.saved.queue")
        UserDefaults.standard.set(0, forKey: "kaset.saved.queueIndex")
        
        // Act
        let restored = playerService.restoreQueueFromPersistence()
        
        // Assert
        #expect(restored == false)
    }

    // MARK: - Metadata Enrichment Tests

    @Test("Identify songs needing enrichment detects missing metadata")
    func identifySongsNeedingEnrichment() async throws {
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
        let needingEnrichment = playerService.identifySongsNeedingEnrichment()
        
        // Assert
        #expect(needingEnrichment.count == 1)
        #expect(needingEnrichment[0].videoId == "incomplete")
    }

    @Test("Enrich queue metadata fetches and updates incomplete songs")
    func enrichQueueMetadata() async throws {
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
        
        mockClient.songResponses["test-id"] = enrichedSong
        await playerService.playQueue([incompleteSong], startingAt: 0)
        
        // Act
        await playerService.enrichQueueMetadata()
        
        // Assert
        #expect(mockClient.getSongCalled == true)
        #expect(playerService.queue[0].title == "Enriched Title")
        #expect(playerService.queue[0].artists[0].name == "Enriched Artist")
    }

    @Test("Metadata enrichment updates queue during playback")
    func metadataEnrichmentDuringPlayback() async throws {
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
        
        mockClient.songResponses["playback-test"] = enrichedSong
        await playerService.playQueue([incompleteSong], startingAt: 0)
        
        // Act - Simulate playback which triggers fetchSongMetadata
        await playerService.play(song: incompleteSong)
        
        // Wait a bit for async operations
        try? await Task.sleep(for: .milliseconds(100))
        
        // Assert - Queue should be updated
        #expect(playerService.queue[0].title == "Enriched During Playback")
        #expect(playerService.queue[0].artists[0].name == "Playback Artist")
    }

    @Test("Enrichment does not overwrite good data with worse data")
    func enrichmentPreservesGoodData() async throws {
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
        
        mockClient.songResponses["complete-id"] = differentSong
        await playerService.playQueue([completeSong], startingAt: 0)
        
        // Act
        await playerService.play(song: completeSong)
        try? await Task.sleep(for: .milliseconds(100))
        
        // Assert - Original good data preserved
        #expect(playerService.queue[0].title == "Good Title")
        #expect(playerService.queue[0].artists[0].name == "Good Artist")
    }

    @Test("Metadata enrichment handles API errors gracefully")
    func enrichmentHandlesErrors() async throws {
        // Arrange
        let incompleteSong = Song(
            id: "error-test",
            title: "Loading...",
            artists: [],
            videoId: "error-test"
        )
        
        mockClient.shouldThrowError = NSError(domain: "Test", code: 500)
        await playerService.playQueue([incompleteSong], startingAt: 0)
        
        // Act - Should not throw
        await playerService.enrichQueueMetadata()
        
        // Assert - Queue unchanged but no crash
        #expect(playerService.queue[0].title == "Loading...")
        #expect(mockClient.getSongCalled == true)
    }

    // MARK: - Queue Display Mode Tests

    @Test("Toggle queue display mode switches between popup and side panel")
    func toggleQueueDisplayMode() {
        // Arrange
        let initialMode = playerService.queueDisplayMode
        
        // Act
        playerService.toggleQueueDisplayMode()
        
        // Assert
        #expect(playerService.queueDisplayMode != initialMode)
        
        // Act again
        playerService.toggleQueueDisplayMode()
        
        // Assert - Back to original
        #expect(playerService.queueDisplayMode == initialMode)
    }

    @Test("Queue display mode persists to UserDefaults")
    func queueDisplayModePersistence() {
        // Arrange
        playerService.queueDisplayMode = .popup
        
        // Act
        playerService.toggleQueueDisplayMode()
        
        // Assert
        let savedMode = UserDefaults.standard.string(forKey: "kaset.queue.displayMode")
        #expect(savedMode == QueueDisplayMode.sidepanel.rawValue)
    }
}
