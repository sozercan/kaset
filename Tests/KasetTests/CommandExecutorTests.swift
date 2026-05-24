import Foundation
import Testing
@testable import Kaset

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
}
