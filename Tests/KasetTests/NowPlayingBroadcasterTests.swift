import Testing
@testable import Kaset

// MARK: - NowPlayingBroadcasterTests

@MainActor
struct NowPlayingBroadcasterTests {
    /// `notificationName` is a published cross-process contract: external now-playing
    /// surfaces (e.g. the boring.notch "Kaset" media source) listen for this exact
    /// string. Pin it so an accidental rename fails CI here instead of silently
    /// breaking those integrations.
    @Test("Broadcaster notification name matches the published contract")
    func notificationNameIsStableContract() {
        #expect(NowPlayingBroadcaster.notificationName == "com.sertacozercan.Kaset.playerInfo")
    }

    @Test("Broadcaster posts on tracked playback changes but not on progress or volume")
    func postsOnTrackedChangesOnly() async {
        let posts = PostCounter()
        let playerService = PlayerService()
        let broadcaster = NowPlayingBroadcaster(postNotification: { posts.count += 1 })
        broadcaster.configure(playerService: playerService)

        playerService.state = .playing
        #expect(await self.waitUntil { posts.count == 1 })

        // High-frequency values are deliberately not triggers.
        playerService.progress = 42
        playerService.volume = 0.5
        try? await Task.sleep(for: .milliseconds(100))
        #expect(posts.count == 1)

        // Observation re-arms after each post, so later tracked changes keep posting.
        playerService.state = .paused
        #expect(await self.waitUntil { posts.count == 2 })
    }

    private func waitUntil(timeout: Duration = .seconds(1), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else { return condition() }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

// MARK: - PostCounter

@MainActor
private final class PostCounter {
    var count = 0
}
