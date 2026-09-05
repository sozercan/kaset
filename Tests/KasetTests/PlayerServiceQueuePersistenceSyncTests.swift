import Foundation
import Testing
@testable import Kaset

extension PlayerServiceQueueTests {
    @Test("Unchanged persistence still synchronizes an ephemeral next entry")
    func unchangedPersistenceStillSynchronizesEphemeralNextEntry() async {
        let songs = TestFixtures.makeSongs(count: 2)
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.state = .playing
        self.playerService.saveQueueForPersistence()
        let firstWriteCount = self.playerService.queuePersistenceWriteCountForTesting
        let originalEntries = self.playerService.queueEntries
        let suggestion = QueueEntry(
            id: UUID(),
            song: TestFixtures.makeSong(id: "suggested-next"),
            source: .suggested
        )
        self.playerService.injectedWebQueueVideoId = originalEntries[1].song.videoId

        self.playerService.setQueue(entries: [originalEntries[0], suggestion, originalEntries[1]])
        self.playerService.saveQueueForPersistence()

        #expect(self.playerService.queuePersistenceWriteCountForTesting == firstWriteCount)
        #expect(self.playerService.injectedWebQueueVideoId == nil)
        #expect(self.playerService.pendingWebQueueInjectionVideoId == nil)
    }
}
