import Foundation
import Testing
@testable import Kaset

@Suite("Music queue entry identity", .serialized, .tags(.service))
@MainActor
struct MusicQueueEntryIdentityTests {
    @Test("Stale metadata cannot overwrite a newer same-video queue entry")
    func staleMetadataCannotOverwriteNewerEntry() async throws {
        let (playerService, mockClient) = self.makePlayerService()
        defer { SingletonPlayerWebView.shared.tearDown() }
        let metadataStarted = AsyncGate()
        let releaseMetadata = AsyncGate()
        let first = self.song(id: "first", title: "First", videoId: "shared")
        let second = self.song(id: "second", title: "Second", videoId: "shared")
        let firstID = UUID()
        let secondID = UUID()
        playerService.setQueue(entries: [
            QueueEntry(id: firstID, song: first),
            QueueEntry(id: secondID, song: second),
        ])
        mockClient.songResponses["shared"] = self.song(
            id: "stale",
            title: "Stale metadata",
            videoId: "shared"
        )
        mockClient.beforeGetSongReturn = { _ in
            await metadataStarted.open()
            await releaseMetadata.wait()
        }

        await playerService.playFromQueue(at: 0)
        let metadataTask = Task { @MainActor in
            await playerService.fetchSongMetadata(videoId: "shared")
        }
        await metadataStarted.wait()

        mockClient.beforeGetSongReturn = nil
        await playerService.playFromQueue(at: 1)
        let secondOccurrence = try #require(playerService.currentMusicPlaybackOccurrence)
        await releaseMetadata.open()
        await metadataTask.value

        #expect(playerService.currentQueueEntryID == secondID)
        #expect(playerService.activePlaybackQueueEntryID == secondID)
        #expect(playerService.currentTrack?.id == second.id)
        #expect(playerService.currentTrack?.title == second.title)
        #expect(playerService.currentMusicPlaybackOccurrence == secondOccurrence)
        #expect(playerService.queueEntries[1].song.title == second.title)
    }

    @Test("Metadata enrichment updates the active duplicate entry, not the first match")
    func metadataUpdatesExactActiveEntry() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { SingletonPlayerWebView.shared.tearDown() }
        let first = self.song(id: "first", title: "First complete", videoId: "shared")
        let second = Song(
            id: "second",
            title: "Loading...",
            artists: [],
            duration: 180,
            videoId: "shared"
        )
        let firstID = UUID()
        let secondID = UUID()
        playerService.setQueue(entries: [
            QueueEntry(id: firstID, song: first),
            QueueEntry(id: secondID, song: second),
        ])
        mockClient.songResponses["shared"] = Song(
            id: "api",
            title: "Enriched second",
            artists: [Artist(id: "artist", name: "Artist")],
            duration: 180,
            videoId: "shared",
            feedbackTokens: .init(add: nil, remove: nil)
        )

        await playerService.playFromQueue(at: 1)

        #expect(playerService.queueEntries[0].id == firstID)
        #expect(playerService.queueEntries[0].song.title == first.title)
        #expect(playerService.queueEntries[1].id == secondID)
        #expect(playerService.queueEntries[1].song.title == "Enriched second")
        #expect(playerService.activePlaybackQueueEntryID == secondID)
    }

    @Test("Detached current playback still accepts its in-flight metadata")
    func detachedCurrentPlaybackAcceptsMetadata() async {
        let (playerService, mockClient) = self.makePlayerService()
        let metadataStarted = AsyncGate()
        let releaseMetadata = AsyncGate()
        let entryID = UUID()
        let current = self.song(id: "detached", title: "Loading...", videoId: "detached")
        let status = FeedbackTokens(add: nil, remove: "remove-token")
        let fetched = Song(
            id: current.id,
            title: "Fetched detached",
            artists: current.artists,
            duration: current.duration,
            videoId: current.videoId,
            likeStatus: .like,
            isInLibrary: true,
            feedbackTokens: status
        )
        playerService.setQueue(entries: [QueueEntry(id: entryID, song: current)])
        playerService.currentTrack = current
        playerService.activePlaybackQueueEntryID = entryID
        mockClient.songResponses[current.videoId] = fetched
        mockClient.beforeGetSongReturn = { _ in
            await metadataStarted.open()
            await releaseMetadata.wait()
        }

        let metadataTask = Task { @MainActor in
            await playerService.fetchSongMetadata(
                videoId: current.videoId,
                queueOwner: .entry(entryID)
            )
        }
        await metadataStarted.wait()

        playerService.setQueue(entries: [])
        #expect(playerService.activePlaybackQueueEntryID == nil)
        await releaseMetadata.open()
        await metadataTask.value

        #expect(playerService.currentTrack?.title == fetched.title)
        #expect(playerService.currentTrackLikeStatus == .like)
        #expect(playerService.currentTrackInLibrary)
        #expect(playerService.currentTrackFeedbackTokens == fetched.feedbackTokens)
        #expect(playerService.queueEntries.isEmpty)
    }

    @Test("Background queue enrichment follows the entry ID across reorder")
    func queueEnrichmentFollowsEntryAcrossReorder() async throws {
        let (playerService, mockClient) = self.makePlayerService()
        let enrichmentStarted = AsyncGate()
        let releaseEnrichment = AsyncGate()
        let targetID = UUID()
        let currentID = UUID()
        let target = Song(
            id: "target",
            title: "Loading...",
            artists: [],
            videoId: "target"
        )
        let current = self.song(id: "current", title: "Current", videoId: "current")
        playerService.setQueue(entries: [
            QueueEntry(id: targetID, song: target),
            QueueEntry(id: currentID, song: current),
        ])
        playerService.currentIndex = 1
        mockClient.songResponses["target"] = self.song(
            id: "target",
            title: "Enriched target",
            videoId: "target"
        )
        mockClient.beforeGetSongReturn = { _ in
            await enrichmentStarted.open()
            await releaseEnrichment.wait()
        }

        let enrichmentTask = Task { @MainActor in
            await playerService.enrichQueueMetadata()
        }
        await enrichmentStarted.wait()
        playerService.reorderQueue(from: IndexSet(integer: 0), to: 2)
        await releaseEnrichment.open()
        await enrichmentTask.value

        let targetEntry = try #require(playerService.queueEntries.first(where: { $0.id == targetID }))
        #expect(targetEntry.song.title == "Enriched target")
        #expect(playerService.currentQueueEntryID == currentID)
    }

    @Test("Clearing a detached playback queue gives the standalone song a fresh entry ID")
    func clearQueueDoesNotReassignUnrelatedEntryID() async throws {
        let (playerService, _) = self.makePlayerService()
        defer { SingletonPlayerWebView.shared.tearDown() }
        let first = self.song(id: "first", title: "First", videoId: "first")
        let second = self.song(id: "second", title: "Second", videoId: "second")
        let standalone = self.song(id: "standalone", title: "Standalone", videoId: "standalone")
        await playerService.playQueue([first, second], startingAt: 0)
        let oldEntryID = try #require(playerService.currentQueueEntryID)

        await playerService.play(song: standalone)
        playerService.clearQueue()

        #expect(playerService.queue == [standalone])
        #expect(playerService.queueEntryIDs.count == 1)
        #expect(playerService.queueEntryIDs[0] != oldEntryID)
        #expect(playerService.activePlaybackQueueEntryID == nil)
    }

    @Test("Detached playback persists its own song and clock")
    func detachedPlaybackPersistsOwnIdentity() async {
        let (playerService, _) = self.makePlayerService()
        defer {
            playerService.clearSavedQueue()
            SingletonPlayerWebView.shared.tearDown()
        }
        playerService.clearSavedQueue()
        let queued = self.song(id: "queued", title: "Queued", videoId: "queued")
        let standalone = self.song(
            id: "standalone",
            title: "Standalone",
            videoId: "standalone"
        )
        await playerService.playQueue([queued], startingAt: 0)
        await playerService.play(song: standalone)
        playerService.progress = 42
        playerService.duration = 180
        playerService.saveQueueForPersistence()

        let restored = PlayerService()
        #expect(restored.restoreQueueFromPersistence())

        #expect(restored.queue == [standalone])
        #expect(restored.currentTrack?.videoId == standalone.videoId)
        #expect(restored.progress == 42)
        #expect(restored.duration == 180)
    }

    @Test("Deferred queue selection follows the captured entry ID after insertion")
    func deferredSelectionFollowsEntryID() async {
        let (playerService, _) = self.makePlayerService()
        defer { SingletonPlayerWebView.shared.tearDown() }
        let first = self.song(id: "first", title: "First", videoId: "first")
        let selected = self.song(id: "selected", title: "Selected", videoId: "selected")
        let inserted = self.song(id: "inserted", title: "Inserted", videoId: "inserted")
        let firstID = UUID()
        let selectedID = UUID()
        playerService.setQueue(entries: [
            QueueEntry(id: firstID, song: first),
            QueueEntry(id: selectedID, song: selected),
        ])
        let intent = playerService.beginMusicPlaybackIntent()

        playerService.setQueue(entries: [
            QueueEntry(id: UUID(), song: inserted),
            QueueEntry(id: firstID, song: first),
            QueueEntry(id: selectedID, song: selected),
        ])
        await playerService.playFromQueue(entryID: selectedID, intent: intent)

        #expect(playerService.currentQueueEntryID == selectedID)
        #expect(playerService.activePlaybackQueueEntryID == selectedID)
        #expect(playerService.currentTrack == selected)
        #expect(playerService.currentIndex == 2)
    }

    @Test("Direct video metadata has no queue-entry owner")
    func directVideoMetadataDoesNotEnrichPreviousQueueEntry() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { SingletonPlayerWebView.shared.tearDown() }
        let queued = Song(
            id: "queued",
            title: "Loading...",
            artists: [],
            videoId: "queued"
        )
        await playerService.playQueue([queued], startingAt: 0)
        let queuedEntryID = playerService.queueEntryIDs[0]
        mockClient.songResponses["standalone"] = self.song(
            id: "standalone",
            title: "Standalone metadata",
            videoId: "standalone"
        )

        await playerService.play(videoId: "standalone")

        #expect(playerService.currentTrack?.videoId == "standalone")
        #expect(playerService.queueEntryIDs == [queuedEntryID])
        #expect(playerService.queue[0].videoId == queued.videoId)
        #expect(playerService.queue[0].title != "Standalone metadata")
    }

    @Test("Direct video playback matching a queued song remains detached")
    func directVideoPlaybackDoesNotAdoptMatchingQueueEntry() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { SingletonPlayerWebView.shared.tearDown() }
        let queued = self.song(id: "queued-logical", title: "Queued", videoId: "shared-video")
        let other = self.song(id: "other", title: "Other", videoId: "other-video")
        mockClient.songResponses[queued.videoId] = self.song(
            id: "api-identity",
            title: "Direct metadata",
            videoId: queued.videoId
        )
        await playerService.playQueue([queued, other], startingAt: 0)
        await playerService.play(song: self.song(id: "detached", title: "Detached", videoId: "detached"))

        await playerService.play(videoId: queued.videoId)

        #expect(playerService.currentTrack?.videoId == queued.videoId)
        #expect(playerService.activePlaybackQueueEntryID == nil)
        #expect(playerService.queueEntryIDOwningCurrentPlayback == nil)
    }

    @Test("Metadata identity changes preserve exact queue ownership and persistence")
    func metadataIdentityChangeKeepsQueueOwner() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer {
            playerService.clearSavedQueue()
            SingletonPlayerWebView.shared.tearDown()
        }
        playerService.clearSavedQueue()
        let incomplete = Song(
            id: "logical-id",
            title: "Loading...",
            artists: [],
            duration: 180,
            videoId: "shared-video"
        )
        let second = self.song(id: "second", title: "Second", videoId: "second-video")
        mockClient.songResponses[incomplete.videoId] = self.song(
            id: "api-id",
            title: "Enriched",
            videoId: incomplete.videoId
        )

        await playerService.playQueue([incomplete, second], startingAt: 0)
        let activeEntryID = playerService.queueEntryIDs[0]
        playerService.saveQueueForPersistence()

        #expect(playerService.activePlaybackQueueEntryID == activeEntryID)
        #expect(playerService.queueEntryIDOwningCurrentPlayback == activeEntryID)
        let restored = PlayerService()
        #expect(restored.restoreQueueFromPersistence())
        #expect(restored.queue.count == 2)
        #expect(restored.currentIndex == 0)
        #expect(restored.queue[0].videoId == incomplete.videoId)
    }

    @Test("Background enrichment cannot overwrite newer complete entry metadata")
    func backgroundEnrichmentPreservesNewerEntryMetadata() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { SingletonPlayerWebView.shared.tearDown() }
        let entryID = UUID()
        let incomplete = Song(
            id: "enrichment-logical",
            title: "Loading...",
            artists: [],
            videoId: "enrichment-video",
            isPlayable: false
        )
        playerService.setQueue(entries: [QueueEntry(id: entryID, song: incomplete)])
        mockClient.songResponses[incomplete.videoId] = self.song(
            id: "stale-api",
            title: "Stale",
            videoId: incomplete.videoId
        )
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        mockClient.beforeGetSongReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let enrichmentTask = Task { @MainActor in
            await playerService.enrichQueueMetadata()
        }
        await requestStarted.wait()
        let fresh = Song(
            id: incomplete.id,
            title: "Fresh",
            artists: [Artist(id: "fresh-artist", name: "Fresh Artist")],
            thumbnailURL: URL(string: "https://example.com/fresh.jpg"),
            videoId: incomplete.videoId,
            isPlayable: false
        )
        playerService.setQueue(entries: [QueueEntry(id: entryID, song: fresh)])
        await releaseRequest.open()
        await enrichmentTask.value

        #expect(playerService.queueEntries[0].id == entryID)
        #expect(playerService.queue[0].title == "Fresh")
        #expect(playerService.queue[0].artists.first?.name == "Fresh Artist")
        #expect(!playerService.queue[0].isPlayable)
    }

    @Test("Pausing does not discard metadata for the same active entry")
    func pausePreservesActiveEntryMetadataRequest() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { SingletonPlayerWebView.shared.tearDown() }
        let song = Song(
            id: "metadata",
            title: "Loading...",
            artists: [],
            videoId: "metadata"
        )
        mockClient.songResponses[song.videoId] = self.song(
            id: song.id,
            title: "Enriched",
            videoId: song.videoId
        )
        let metadataStarted = AsyncGate()
        let releaseMetadata = AsyncGate()
        mockClient.beforeGetSongReturn = { _ in
            await metadataStarted.open()
            await releaseMetadata.wait()
        }

        let playTask = Task { @MainActor in
            await playerService.playQueue([song], startingAt: 0)
        }
        await metadataStarted.wait()
        await playerService.pause()
        await releaseMetadata.open()
        await playTask.value

        #expect(playerService.currentTrack?.title == "Enriched")
        #expect(playerService.queue[0].title == "Enriched")
        #expect(playerService.state == .paused)
    }

    @Test("Duplicate removal retains the active entry owning in-flight metadata")
    func duplicateRemovalRetainsActiveMetadataOwner() async {
        let (playerService, mockClient) = self.makePlayerService()
        defer { SingletonPlayerWebView.shared.tearDown() }
        let first = self.song(id: "first", title: "First complete", videoId: "shared")
        let active = Song(
            id: "active",
            title: "Loading...",
            artists: [],
            duration: 180,
            videoId: "shared"
        )
        let firstID = UUID()
        let activeID = UUID()
        playerService.setQueue(entries: [
            QueueEntry(id: firstID, song: first),
            QueueEntry(id: activeID, song: active),
        ])
        playerService.currentIndex = 1
        playerService.currentTrack = active
        playerService.pendingPlayVideoId = active.videoId
        playerService.activePlaybackQueueEntryID = activeID
        mockClient.songResponses[active.videoId] = self.song(
            id: active.id,
            title: "Enriched active",
            videoId: active.videoId
        )
        let metadataStarted = AsyncGate()
        let releaseMetadata = AsyncGate()
        mockClient.beforeGetSongReturn = { _ in
            await metadataStarted.open()
            await releaseMetadata.wait()
        }
        let metadataTask = Task { @MainActor in
            await playerService.fetchSongMetadata(
                videoId: active.videoId,
                queueOwner: .entry(activeID)
            )
        }
        await metadataStarted.wait()

        playerService.removeDuplicateQueueEntries()

        #expect(playerService.queueEntryIDs == [activeID])
        #expect(playerService.currentQueueEntryID == activeID)
        #expect(playerService.activePlaybackQueueEntryID == activeID)
        await releaseMetadata.open()
        await metadataTask.value

        #expect(playerService.currentTrack?.title == "Enriched active")
        #expect(playerService.queueEntries[0].id == activeID)
        #expect(playerService.queue[0].title == "Enriched active")
    }

    private func makePlayerService() -> (PlayerService, MockYTMusicClient) {
        SingletonPlayerWebView.shared.tearDown()
        SingletonPlayerWebView.shared.currentVideoId = nil
        let mockClient = MockYTMusicClient()
        let playerService = PlayerService()
        playerService.setSongLikeStatusManager(SongLikeStatusManager())
        playerService.setYTMusicClient(mockClient)
        return (playerService, mockClient)
    }

    private func song(id: String, title: String, videoId: String) -> Song {
        Song(
            id: id,
            title: title,
            artists: [Artist(id: "artist", name: "Artist")],
            duration: 180,
            videoId: videoId,
            feedbackTokens: .init(add: nil, remove: nil)
        )
    }
}
