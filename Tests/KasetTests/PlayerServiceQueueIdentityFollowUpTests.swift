import Foundation
import Testing
@testable import Kaset

extension PlayerServiceQueueTests {
    @Test("Reorder allows inserting an entry immediately above the current track")
    func reorderQueueAllowsDestinationAtCurrentIndex() async {
        let songs = TestFixtures.makeSongs(count: 4)
        await self.playerService.playQueue(songs, startingAt: 2)
        let currentEntryID = self.playerService.currentQueueEntryID

        self.playerService.reorderQueue(from: IndexSet(integer: 3), to: 2)

        #expect(self.playerService.queue.map(\.videoId) == ["video-0", "video-1", "video-3", "video-2"])
        #expect(self.playerService.currentQueueEntryID == currentEntryID)
        #expect(self.playerService.currentIndex == 3)
    }

    @Test("Entry-ID reorder follows the intended rows after an insertion")
    func reorderQueueByEntryIDSurvivesSnapshotDrift() async {
        let songs = TestFixtures.makeSongs(count: 4)
        await self.playerService.playQueue(songs, startingAt: 0)
        let movedEntryID = self.playerService.queueEntryIDs[3]
        let beforeEntryID = self.playerService.queueEntryIDs[2]
        let inserted = QueueEntry(id: UUID(), song: TestFixtures.makeSong(id: "inserted"))
        self.playerService.setQueue(entries: [
            self.playerService.queueEntries[0],
            inserted,
            self.playerService.queueEntries[1],
            self.playerService.queueEntries[2],
            self.playerService.queueEntries[3],
        ])

        self.playerService.reorderQueue(entryID: movedEntryID, before: beforeEntryID)

        #expect(self.playerService.queue.map(\.videoId) == [
            "video-0",
            "inserted",
            "video-1",
            "video-3",
            "video-2",
        ])
    }

    @Test("Entry-ID reorder ignores a disappeared destination")
    func reorderQueueByEntryIDIgnoresMissingTarget() async {
        let songs = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(songs, startingAt: 1)
        let sourceID = self.playerService.queueEntryIDs[0]
        let targetID = self.playerService.queueEntryIDs[2]
        self.playerService.removeFromQueue(entryIDs: [targetID])
        let before = self.playerService.queueEntryIDs

        self.playerService.reorderQueue(entryID: sourceID, before: targetID)

        #expect(self.playerService.queueEntryIDs == before)
    }

    @Test("Detached playback allows reordering the leftover queue cursor row")
    func detachedPlaybackAllowsCursorRowReorder() async {
        let songs = TestFixtures.makeSongs(count: 2)
        await self.playerService.playQueue(songs, startingAt: 1)
        let secondEntryID = self.playerService.queueEntryIDs[1]
        let firstEntryID = self.playerService.queueEntryIDs[0]
        await self.playerService.play(song: TestFixtures.makeSong(id: "detached-reorder"))

        self.playerService.reorderQueue(entryID: secondEntryID, before: firstEntryID)

        #expect(self.playerService.queue.map(\.videoId) == [songs[1].videoId, songs[0].videoId])
    }

    @Test("Partial video-ID reorder clamps a removed current cursor")
    func partialVideoIDReorderClampsCurrentIndex() async {
        let songs = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(songs, startingAt: 2)

        self.playerService.reorderQueue(videoIds: [songs[0].videoId])

        #expect(self.playerService.queue == [songs[0]])
        #expect(self.playerService.currentIndex == 0)
        #expect(self.playerService.currentQueueEntryID == self.playerService.queueEntryIDs.first)
    }
}
