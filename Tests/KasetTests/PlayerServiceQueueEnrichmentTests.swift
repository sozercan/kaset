import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct PlayerServiceQueueEnrichmentTests {
    init() {
        UserDefaults.standard.removeObject(forKey: "kaset.saved.queue")
        UserDefaults.standard.removeObject(forKey: "kaset.saved.queueIndex")
        UserDefaults.standard.removeObject(forKey: "kaset.saved.playbackSession")
        SingletonPlayerWebView.shared.currentVideoId = nil
    }

    @Test("Queue enrichment does not schedule without a YTMusic client")
    func noScheduleWithoutClient() {
        let playerService = PlayerService()
        playerService.queueEnrichmentInitialDelay = .milliseconds(5)

        playerService.setQueue([Self.incompleteSong(videoId: "needs-client")])

        #expect(playerService.enrichmentTask == nil)
    }

    @Test("Queue enrichment skips complete queues")
    func noScheduleForCompleteQueue() {
        let playerService = PlayerService()
        let mockClient = MockYTMusicClient()
        playerService.queueEnrichmentInitialDelay = .seconds(10)
        playerService.setYTMusicClient(mockClient)

        playerService.setQueue([TestFixtures.makeSong(id: "complete")])

        #expect(playerService.enrichmentTask == nil)
        #expect(mockClient.getSongVideoIds.isEmpty)
    }

    @Test("Queue enrichment schedules once when a client can enrich an incomplete queue")
    func schedulesOneShotAndStopsAfterEnriching() async {
        let playerService = PlayerService()
        let mockClient = MockYTMusicClient()
        playerService.queueEnrichmentInitialDelay = .milliseconds(5)
        mockClient.songResponses["needs-enrichment"] = TestFixtures.makeSong(
            id: "needs-enrichment",
            title: "Enriched Song",
            artistName: "Enriched Artist"
        )

        playerService.setYTMusicClient(mockClient)
        playerService.setQueue([Self.incompleteSong(videoId: "needs-enrichment")])

        #expect(playerService.enrichmentTask != nil)

        await Self.waitUntil {
            playerService.enrichmentTask == nil && playerService.queue.first?.title == "Enriched Song"
        }

        #expect(mockClient.getSongVideoIds == ["needs-enrichment"])
        #expect(playerService.identifySongsNeedingEnrichment().isEmpty)
    }

    @Test("Queue enrichment retries incomplete entries after a transient failure")
    func retriesAfterTransientFailure() async {
        let playerService = PlayerService()
        let mockClient = MockYTMusicClient()
        playerService.queueEnrichmentInitialDelay = .milliseconds(5)
        playerService.queueEnrichmentRetryDelay = .milliseconds(50)
        mockClient.getSongErrorsByCallCount[1] = NSError(domain: "Transient", code: 500)
        mockClient.songResponses["retry-me"] = TestFixtures.makeSong(
            id: "retry-me",
            title: "Recovered Song",
            artistName: "Recovered Artist"
        )

        playerService.setYTMusicClient(mockClient)
        playerService.setQueue([Self.incompleteSong(videoId: "retry-me")])

        await Self.waitUntil {
            playerService.enrichmentTask == nil && playerService.queue.first?.title == "Recovered Song"
        }

        #expect(mockClient.getSongVideoIds == ["retry-me", "retry-me"])
        #expect(playerService.identifySongsNeedingEnrichment().isEmpty)
    }

    @Test("Successful incomplete enrichment responses keep bounded retry identity")
    func successfulIncompleteResponsesKeepBoundedRetryIdentity() async {
        let playerService = PlayerService()
        let mockClient = MockYTMusicClient()
        let entryID = UUID()
        playerService.queueEnrichmentInitialDelay = .milliseconds(5)
        playerService.queueEnrichmentRetryDelay = .milliseconds(5)
        mockClient.songResponses["still-incomplete"] = Song(
            id: "still-incomplete",
            title: "Known Title",
            artists: [Artist(id: "known-artist", name: "Known Artist")],
            videoId: "still-incomplete"
        )

        playerService.setYTMusicClient(mockClient)
        playerService.setQueue(entries: [
            QueueEntry(id: entryID, song: Self.incompleteSong(videoId: "still-incomplete")),
        ])

        await Self.waitUntil(timeout: .seconds(2)) {
            playerService.enrichmentTask == nil &&
                mockClient.getSongVideoIds.count == PlayerService.maxQueueEnrichmentAttempts
        }
        try? await Task.sleep(for: .milliseconds(25))

        #expect(playerService.queueEntryIDs == [entryID])
        #expect(playerService.queueEnrichmentAttemptsByEntryID[entryID] == PlayerService.maxQueueEnrichmentAttempts)
        #expect(mockClient.getSongVideoIds.count == PlayerService.maxQueueEnrichmentAttempts)
        #expect(!playerService.identifySongsNeedingEnrichment().isEmpty)
    }

    @Test("Client replacement invalidates a running enrichment response")
    func clientReplacementInvalidatesRunningResponse() async {
        let playerService = PlayerService()
        let oldClient = MockYTMusicClient()
        let newClient = MockYTMusicClient()
        playerService.queueEnrichmentInitialDelay = .milliseconds(5)
        oldClient.getSongDelay = .milliseconds(100)
        oldClient.songResponses["shared-video"] = TestFixtures.makeSong(
            id: "shared-video",
            title: "Stale Metadata",
            artistName: "Old Account"
        )
        newClient.songResponses["shared-video"] = TestFixtures.makeSong(
            id: "shared-video",
            title: "Fresh Metadata",
            artistName: "New Account"
        )

        playerService.setYTMusicClient(oldClient)
        playerService.setQueue([Self.incompleteSong(videoId: "shared-video")])
        await Self.waitUntil {
            oldClient.getSongVideoIds == ["shared-video"] && playerService.isQueueEnrichmentRunning
        }

        playerService.setYTMusicClient(newClient)

        await Self.waitUntil(timeout: .seconds(2)) {
            playerService.enrichmentTask == nil && playerService.queue.first?.title == "Fresh Metadata"
        }
        try? await Task.sleep(for: .milliseconds(125))

        #expect(oldClient.getSongVideoIds == ["shared-video"])
        #expect(newClient.getSongVideoIds == ["shared-video"])
        #expect(playerService.queue.first?.title == "Fresh Metadata")
        #expect(playerService.queue.first?.artists.first?.name == "New Account")
    }

    @Test("Queue enrichment can reschedule after canceling a running pass")
    func reschedulesAfterRunningPassCancellation() async {
        let playerService = PlayerService()
        let mockClient = MockYTMusicClient()
        playerService.queueEnrichmentInitialDelay = .milliseconds(5)
        mockClient.getSongDelay = .milliseconds(100)
        mockClient.songResponses["slow-cancelled"] = TestFixtures.makeSong(
            id: "slow-cancelled",
            title: "Cancelled Song",
            artistName: "Cancelled Artist"
        )
        mockClient.songResponses["new-entry"] = TestFixtures.makeSong(
            id: "new-entry",
            title: "Newly Enriched Song",
            artistName: "New Artist"
        )

        playerService.setYTMusicClient(mockClient)
        playerService.setQueue([Self.incompleteSong(videoId: "slow-cancelled")])

        await Self.waitUntil {
            mockClient.getSongVideoIds == ["slow-cancelled"] && playerService.isQueueEnrichmentRunning
        }

        playerService.setQueue([TestFixtures.makeSong(id: "complete-cancels-running")])
        #expect(playerService.enrichmentTask == nil)
        #expect(!playerService.isQueueEnrichmentRunning)

        playerService.setQueue([Self.incompleteSong(videoId: "new-entry")])
        #expect(playerService.enrichmentTask != nil)

        await Self.waitUntil(timeout: .seconds(2)) {
            playerService.enrichmentTask == nil && playerService.queue.first?.title == "Newly Enriched Song"
        }

        #expect(mockClient.getSongVideoIds.contains("new-entry"))
        #expect(playerService.identifySongsNeedingEnrichment().isEmpty)
    }

    @Test("Queue enrichment external re-arm replaces sleeping retry backoff")
    func externalRearmReplacesSleepingRetryBackoff() async {
        let playerService = PlayerService()
        let mockClient = MockYTMusicClient()
        playerService.queueEnrichmentInitialDelay = .milliseconds(5)
        playerService.queueEnrichmentRetryDelay = .seconds(10)
        mockClient.shouldThrowError = NSError(domain: "Transient", code: 500)
        mockClient.songResponses["backoff-rearm"] = TestFixtures.makeSong(
            id: "backoff-rearm",
            title: "Backoff Rearmed Song",
            artistName: "Backoff Artist"
        )

        playerService.setYTMusicClient(mockClient)
        playerService.setQueue([Self.incompleteSong(videoId: "backoff-rearm")])

        await Self.waitUntil(timeout: .seconds(2)) {
            mockClient.getSongVideoIds == ["backoff-rearm"] &&
                playerService.enrichmentTask != nil &&
                !playerService.isQueueEnrichmentRunning
        }

        mockClient.shouldThrowError = nil
        playerService.setYTMusicClient(mockClient)

        await Self.waitUntil(timeout: .seconds(2)) {
            playerService.enrichmentTask == nil && playerService.queue.first?.title == "Backoff Rearmed Song"
        }

        #expect(mockClient.getSongVideoIds == ["backoff-rearm", "backoff-rearm"])
        #expect(playerService.identifySongsNeedingEnrichment().isEmpty)
    }

    @Test("Queue enrichment re-arms bounded attempts after client replacement")
    func reArmsAttemptsAfterClientReplacement() async {
        let playerService = PlayerService()
        let mockClient = MockYTMusicClient()
        playerService.queueEnrichmentInitialDelay = .milliseconds(5)
        playerService.queueEnrichmentRetryDelay = .milliseconds(5)
        mockClient.shouldThrowError = NSError(domain: "Transient", code: 500)
        mockClient.songResponses["rearm-me"] = TestFixtures.makeSong(
            id: "rearm-me",
            title: "Rearmed Song",
            artistName: "Rearmed Artist"
        )

        playerService.setYTMusicClient(mockClient)
        playerService.setQueue([Self.incompleteSong(videoId: "rearm-me")])

        await Self.waitUntil(timeout: .seconds(2)) {
            playerService.enrichmentTask == nil && mockClient.getSongVideoIds.count == PlayerService.maxQueueEnrichmentAttempts
        }
        #expect(playerService.queue.first?.title == "Loading...")

        mockClient.shouldThrowError = nil
        playerService.setYTMusicClient(mockClient)

        await Self.waitUntil(timeout: .seconds(2)) {
            playerService.enrichmentTask == nil && playerService.queue.first?.title == "Rearmed Song"
        }

        #expect(mockClient.getSongVideoIds.count == PlayerService.maxQueueEnrichmentAttempts + 1)
        #expect(playerService.identifySongsNeedingEnrichment().isEmpty)
    }

    @Test("Queue enrichment cancels a pending pass when the queue becomes complete")
    func cancelsPendingPassWhenQueueBecomesComplete() async {
        let playerService = PlayerService()
        let mockClient = MockYTMusicClient()
        playerService.queueEnrichmentInitialDelay = .seconds(10)
        playerService.setYTMusicClient(mockClient)

        playerService.setQueue([Self.incompleteSong(videoId: "was-incomplete")])
        #expect(playerService.enrichmentTask != nil)

        playerService.setQueue([TestFixtures.makeSong(id: "now-complete")])

        #expect(playerService.enrichmentTask == nil)
        try? await Task.sleep(for: .milliseconds(25))
        #expect(mockClient.getSongVideoIds.isEmpty)
    }

    private static func incompleteSong(videoId: String) -> Song {
        Song(
            id: videoId,
            title: "Loading...",
            artists: [],
            videoId: videoId
        )
    }

    private static func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
