import Foundation
import Testing
@testable import Kaset

/// Tests for PlayerService+Queue mix functionality.
@Suite("PlayerService+Mix", .serialized, .tags(.service))
@MainActor
struct PlayerServiceMixTests {
    var playerService: PlayerService
    var mockClient: MockYTMusicClient

    init() {
        self.mockClient = MockYTMusicClient()
        self.playerService = PlayerService()
        self.playerService.setYTMusicClient(self.mockClient)
        // Enable hasUserInteractedThisSession to avoid mini player popup
        self.playerService.confirmPlaybackStarted()
    }

    // MARK: - playWithMix Tests

    @Test("playWithMix does nothing without client")
    func playWithMixNoClient() async {
        let service = PlayerService()
        // No client set

        await service.playWithMix(playlistId: "RDEM123", startVideoId: nil)

        #expect(service.queue.isEmpty)
    }

    @Test("playWithMix handles empty mix queue")
    func playWithMixEmptyQueue() async {
        // MockYTMusicClient returns empty by default

        await self.playerService.playWithMix(playlistId: "RDEM123", startVideoId: nil)

        #expect(self.playerService.queue.isEmpty)
    }

    // MARK: - fetchMoreMixSongsIfNeeded Tests

    @Test("fetchMoreMixSongsIfNeeded does nothing without continuation token")
    func fetchMoreMixSongsNoToken() async {
        self.playerService.mixContinuationToken = nil
        let songs = TestFixtures.makeSongs(count: 5)
        await self.playerService.playQueue(songs, startingAt: 4)

        await self.playerService.fetchMoreMixSongsIfNeeded()

        #expect(self.playerService.queue.count == 5)
    }

    @Test("fetchMoreMixSongsIfNeeded does nothing when not near end")
    func fetchMoreMixSongsNotNearEnd() async {
        self.playerService.mixContinuationToken = "some-token"
        let songs = TestFixtures.makeSongs(count: 20)
        await self.playerService.playQueue(songs, startingAt: 0)

        await self.playerService.fetchMoreMixSongsIfNeeded()

        // No change expected since we're at the beginning
        #expect(self.playerService.queue.count == 20)
    }

    // MARK: - Queue Management Tests

    @Test("clearQueue clears mixContinuationToken")
    func clearQueueClearsContinuationToken() async {
        self.playerService.mixContinuationToken = "some-token"
        let songs = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(songs, startingAt: 1)

        self.playerService.clearQueue()

        #expect(self.playerService.mixContinuationToken == nil)
    }

    @Test("playQueue clears mixContinuationToken")
    func playQueueClearsContinuationToken() async {
        self.playerService.mixContinuationToken = "some-token"
        let songs = TestFixtures.makeSongs(count: 3)

        await self.playerService.playQueue(songs, startingAt: 0)

        #expect(self.playerService.mixContinuationToken == nil)
    }

    // MARK: - playWithRadio Tests

    @Test("playWithRadio clears mixContinuationToken")
    func playWithRadioClearsContinuationToken() async {
        self.playerService.mixContinuationToken = "some-token"
        let song = TestFixtures.makeSong(id: "radio-seed")

        await self.playerService.playWithRadio(song: song)

        #expect(self.playerService.mixContinuationToken == nil)
    }

    @Test("playWithRadio sets initial queue with seed song")
    func playWithRadioSetsInitialQueue() async {
        let song = TestFixtures.makeSong(id: "radio-seed", title: "Seed Song")

        await self.playerService.playWithRadio(song: song)

        #expect(self.playerService.queue.count >= 1)
        #expect(self.playerService.queue.first?.videoId == "radio-seed")
        #expect(self.playerService.currentIndex == 0)
    }

    // MARK: - insertNextInQueue Tests

    @Test("insertNextInQueue inserts songs after current track")
    func insertNextInQueue() async {
        let queue = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(queue, startingAt: 0)

        let newSongs = [
            TestFixtures.makeSong(id: "new-1", title: "New Song 1"),
            TestFixtures.makeSong(id: "new-2", title: "New Song 2"),
        ]

        self.playerService.insertNextInQueue(newSongs)

        #expect(self.playerService.queue.count == 5)
        #expect(self.playerService.queue[1].videoId == "new-1")
        #expect(self.playerService.queue[2].videoId == "new-2")
    }

    @Test("insertNextInQueue with empty array does nothing")
    func insertNextInQueueEmpty() async {
        let queue = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(queue, startingAt: 0)

        self.playerService.insertNextInQueue([])

        #expect(self.playerService.queue.count == 3)
    }

    // MARK: - appendToQueue Tests

    @Test("appendToQueue adds songs to end")
    func appendToQueue() async {
        let queue = TestFixtures.makeSongs(count: 2)
        await self.playerService.playQueue(queue, startingAt: 0)

        let newSongs = [
            TestFixtures.makeSong(id: "appended-1"),
            TestFixtures.makeSong(id: "appended-2"),
        ]

        self.playerService.appendToQueue(newSongs)

        #expect(self.playerService.queue.count == 4)
        #expect(self.playerService.queue.last?.videoId == "appended-2")
    }

    @Test("appendToQueue with empty array does nothing")
    func appendToQueueEmpty() async {
        let queue = TestFixtures.makeSongs(count: 2)
        await self.playerService.playQueue(queue, startingAt: 0)

        self.playerService.appendToQueue([])

        #expect(self.playerService.queue.count == 2)
    }

    // MARK: - removeFromQueue Tests

    @Test("removeFromQueue removes songs by video ID")
    func removeFromQueue() async {
        let queue = TestFixtures.makeSongs(count: 5)
        await self.playerService.playQueue(queue, startingAt: 2)

        self.playerService.removeFromQueue(videoIds: Set(["video-0", "video-4"]))

        #expect(self.playerService.queue.count == 3)
        #expect(!self.playerService.queue.contains { $0.videoId == "video-0" })
        #expect(!self.playerService.queue.contains { $0.videoId == "video-4" })
    }

    @Test("removeFromQueue adjusts currentIndex when needed")
    func removeFromQueueAdjustsIndex() async {
        let queue = TestFixtures.makeSongs(count: 5)
        await self.playerService.playQueue(queue, startingAt: 2)

        // Remove songs before current index
        self.playerService.removeFromQueue(videoIds: Set(["video-0", "video-1"]))

        // Current track should now be at index 0
        #expect(self.playerService.queue.count == 3)
        #expect(self.playerService.currentTrack?.videoId == "video-2")
        #expect(self.playerService.currentIndex == 0)
    }

    // MARK: - reorderQueue Tests

    @Test("reorderQueue changes order based on video IDs")
    func reorderQueue() async {
        let queue = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(queue, startingAt: 0)

        self.playerService.reorderQueue(videoIds: ["video-2", "video-0", "video-1"])

        #expect(self.playerService.queue.count == 3)
        #expect(self.playerService.queue[0].videoId == "video-2")
        #expect(self.playerService.queue[1].videoId == "video-0")
        #expect(self.playerService.queue[2].videoId == "video-1")
    }

    @Test("reorderQueue updates currentIndex to match current track")
    func reorderQueueUpdatesIndex() async {
        let queue = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(queue, startingAt: 0)

        // Current track is video-0 at index 0
        self.playerService.reorderQueue(videoIds: ["video-2", "video-1", "video-0"])

        // Current track should now be at index 2
        #expect(self.playerService.currentTrack?.videoId == "video-0")
        #expect(self.playerService.currentIndex == 2)
    }

    // MARK: - shuffleQueue Tests

    @Test("shuffleQueue keeps current track at front")
    func shuffleQueueKeepsCurrentAtFront() async {
        let queue = TestFixtures.makeSongs(count: 10)
        await self.playerService.playQueue(queue, startingAt: 5)

        self.playerService.shuffleQueue()

        #expect(self.playerService.queue.count == 10)
        #expect(self.playerService.queue[0].videoId == "video-5")
        #expect(self.playerService.currentIndex == 0)
    }

    @Test("shuffleQueue does nothing with single song")
    func shuffleQueueSingleSong() async {
        let queue = [TestFixtures.makeSong(id: "only-one")]
        await self.playerService.playQueue(queue, startingAt: 0)

        self.playerService.shuffleQueue()

        #expect(self.playerService.queue.count == 1)
        #expect(self.playerService.queue[0].videoId == "only-one")
    }
}
