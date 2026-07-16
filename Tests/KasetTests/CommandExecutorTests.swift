import Foundation
import Testing
@testable import Kaset

@available(macOS 26.0, *)

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct CommandExecutorTests {
    private func makeSong(title: String, artist: String, videoId: String) -> Song {
        Song(
            id: videoId,
            title: title,
            artists: [Artist(id: "artist-\(videoId)", name: artist)],
            videoId: videoId
        )
    }

    @Test("Local queue description calls out the end of a multi-item queue")
    func localQueueDescriptionAtEndOfMultiItemQueue() {
        let playerService = MockPlayerService()
        playerService.queue = [
            self.makeSong(title: "Dreams", artist: "Fleetwood Mac", videoId: "song-1"),
            self.makeSong(title: "Pink + White", artist: "Frank Ocean", videoId: "song-2"),
            self.makeSong(title: "Night Drive", artist: "Chromatics", videoId: "song-3"),
        ]
        playerService.currentIndex = 2
        playerService.state = .playing

        let executor = CommandExecutor(
            client: MockYTMusicClient(),
            playerService: playerService
        )
        let outcome = executor.describeQueueLocally()

        #expect(
            outcome.resultMessage ==
                "Now playing \"Night Drive\" by Chromatics. That's the end of your queue."
        )
        #expect(outcome.errorMessage == nil)
        #expect(outcome.shouldDismiss == false)
        #expect(outcome.searchQueryToOpen == nil)
    }

    @Test("removeFromQueue removes songs matching the subject")
    func removeFromQueueMatchesSubject() async {
        let playerService = MockPlayerService()
        playerService.queue = [
            self.makeSong(title: "One More Time", artist: "Daft Punk", videoId: "dp-1"),
            self.makeSong(title: "Dreams", artist: "Fleetwood Mac", videoId: "fm-1"),
            self.makeSong(title: "Around the World", artist: "Daft Punk", videoId: "dp-2"),
        ]
        playerService.currentIndex = 1
        let executor = CommandExecutor(client: MockYTMusicClient(), playerService: playerService)

        let outcome = await executor.execute(.removeFromQueue(query: "daft punk"))

        #expect(playerService.queue.map(\.videoId) == ["fm-1"])
        #expect(outcome.resultMessage?.contains("Removed 2") == true)
        #expect(outcome.errorMessage == nil)
    }

    @Test("removeFromQueue with an empty subject is a safe no-op and never clears the queue")
    func removeFromQueueEmptySubjectIsNoOp() async {
        let playerService = MockPlayerService()
        playerService.queue = [self.makeSong(title: "Dreams", artist: "Fleetwood Mac", videoId: "fm-1")]
        let executor = CommandExecutor(client: MockYTMusicClient(), playerService: playerService)

        let outcome = await executor.execute(.removeFromQueue(query: "   "))

        #expect(outcome.errorMessage != nil)
        #expect(playerService.queue.count == 1)
        #expect(playerService.removeFromQueueCallCount == 0)
    }

    @Test("removeFromQueue with no match reports an error and leaves the queue intact")
    func removeFromQueueNoMatch() async {
        let playerService = MockPlayerService()
        playerService.queue = [self.makeSong(title: "Dreams", artist: "Fleetwood Mac", videoId: "fm-1")]
        let executor = CommandExecutor(client: MockYTMusicClient(), playerService: playerService)

        let outcome = await executor.execute(.removeFromQueue(query: "taylor swift"))

        #expect(outcome.errorMessage != nil)
        #expect(playerService.queue.count == 1)
        #expect(playerService.removeFromQueueCallCount == 0)
    }

    @Test("removeDuplicates drops later duplicate videoIds and reports the count")
    func removeDuplicatesReportsCount() async {
        let playerService = MockPlayerService()
        playerService.queue = [
            self.makeSong(title: "Dreams", artist: "Fleetwood Mac", videoId: "fm-1"),
            self.makeSong(title: "Around the World", artist: "Daft Punk", videoId: "dp-1"),
            self.makeSong(title: "Dreams", artist: "Fleetwood Mac", videoId: "fm-1"),
        ]
        let executor = CommandExecutor(client: MockYTMusicClient(), playerService: playerService)

        let outcome = await executor.execute(.removeDuplicates)

        #expect(playerService.queue.map(\.videoId) == ["fm-1", "dp-1"])
        #expect(outcome.resultMessage?.contains("Removed 1") == true)
    }

    @Test("removeDuplicates reports an error when there is nothing to remove")
    func removeDuplicatesNoDuplicates() async {
        let playerService = MockPlayerService()
        playerService.queue = [
            self.makeSong(title: "Dreams", artist: "Fleetwood Mac", videoId: "fm-1"),
            self.makeSong(title: "Around the World", artist: "Daft Punk", videoId: "dp-1"),
        ]
        let executor = CommandExecutor(client: MockYTMusicClient(), playerService: playerService)

        let outcome = await executor.execute(.removeDuplicates)

        #expect(outcome.errorMessage != nil)
        #expect(playerService.queue.count == 2)
    }
}
