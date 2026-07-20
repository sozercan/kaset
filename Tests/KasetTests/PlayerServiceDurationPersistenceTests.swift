import Foundation
import Testing
@testable import Kaset

// MARK: - PlayerServiceDurationPersistenceTests

@Suite(.serialized, .tags(.service))
@MainActor
struct PlayerServiceDurationPersistenceTests {
    init() {
        UserDefaults.standard.removeObject(forKey: "kaset.saved.queue")
        UserDefaults.standard.removeObject(forKey: "kaset.saved.queueIndex")
        UserDefaults.standard.removeObject(forKey: "kaset.saved.playbackSession")
    }

    @Test("Playback persistence falls back to the exact owning queue entry duration")
    func usesExactQueueOwnerDurationFallback() throws {
        let player = PlayerService()
        let longDuplicate = TestFixtures.makeSong(id: "duplicate", duration: 3600)
        let shortDuplicate = TestFixtures.makeSong(id: "duplicate", duration: 240)
        player.setQueue([longDuplicate, shortDuplicate])
        player.currentIndex = 1
        player.activePlaybackQueueEntryID = player.queueEntryIDs[1]
        player.currentTrack = TestFixtures.makeSong(id: "duplicate", duration: nil)
        player.progress = 300
        player.duration = 0
        player.recordPlaybackStateObservation(videoId: "duplicate", duration: 0)

        player.saveQueueForPersistence()

        let clock = try self.persistedClock()
        #expect(player.observedDuration(for: "duplicate") == nil)
        #expect(player.queueEntryIDOwningCurrentPlayback == player.queueEntryIDs[1])
        #expect(clock.duration == 240)
        #expect(clock.progress == 240)
    }

    @Test("Detached playback does not borrow duration from a same-video queue entry")
    func detachedPlaybackDoesNotBorrowQueueDuration() throws {
        let player = PlayerService()
        let queuedSong = TestFixtures.makeSong(id: "same-video", duration: 240)
        player.setQueue([queuedSong])
        player.activePlaybackQueueEntryID = nil
        player.currentTrack = TestFixtures.makeSong(id: "same-video", duration: nil)
        player.progress = 300
        player.duration = 0

        player.saveQueueForPersistence()

        let clock = try self.persistedClock()
        #expect(player.queueEntryIDOwningCurrentPlayback == nil)
        #expect(clock.duration == 0)
        #expect(clock.progress == 300)
    }

    private func persistedClock() throws -> PersistedPlaybackClock {
        let data = try #require(UserDefaults.standard.data(forKey: "kaset.saved.playbackSession"))
        return try JSONDecoder().decode(PersistedPlaybackClock.self, from: data)
    }
}

// MARK: - PersistedPlaybackClock

private struct PersistedPlaybackClock: Decodable {
    let progress: TimeInterval
    let duration: TimeInterval
}
