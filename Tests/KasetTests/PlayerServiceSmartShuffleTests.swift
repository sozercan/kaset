import Foundation
import Testing
@testable import Kaset

// MARK: - SmartShuffleFeatureGate

@MainActor
private final class SmartShuffleFeatureGate {
    var isEnabled: Bool

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }
}

// MARK: - PlayerServiceSmartShuffleTests

@Suite(.serialized, .tags(.service))
@MainActor
struct PlayerServiceSmartShuffleTests {
    var playerService: PlayerService
    var mockClient: MockYTMusicClient
    let persistenceNamespace: String

    init() {
        self.persistenceNamespace = "PlayerServiceSmartShuffleTests-\(UUID().uuidString)"
        self.mockClient = MockYTMusicClient()
        self.playerService = PlayerService()
        self.playerService.smartShuffleFeatureEnabled = { true }
        self.playerService.useQueuePersistenceNamespaceForTesting(self.persistenceNamespace)
        self.playerService.clearSavedQueue()
        self.playerService.setYTMusicClient(self.mockClient)
        self.playerService.confirmPlaybackStarted()
    }

    @Test("cycleShuffleMode goes off -> on -> smart -> off")
    func cycleOrder() async {
        let songs = TestFixtures.makeSongs(count: 5)
        await self.playerService.playQueue(songs, startingAt: 0)

        #expect(self.playerService.shuffleMode == .off)
        self.playerService.cycleShuffleMode()
        #expect(self.playerService.shuffleMode == .on)
        #expect(self.playerService.shuffleEnabled)
        self.playerService.cycleShuffleMode()
        #expect(self.playerService.shuffleMode == .smart)
        #expect(self.playerService.shuffleEnabled)
        self.playerService.cycleShuffleMode()
        #expect(self.playerService.shuffleMode == .off)
        #expect(!self.playerService.shuffleEnabled)
    }

    @Test("entering smart mode fills the window with deduped radio suggestions")
    func smartFillsWindowWithSuggestions() async {
        let songs = TestFixtures.makeSongs(count: 6) // video-0...video-5
        await self.playerService.playQueue(songs, startingAt: 0)

        // Radio for any seed returns two fresh songs plus one that duplicates an original.
        let fresh = [TestFixtures.makeSong(id: "rec-1"), TestFixtures.makeSong(id: "rec-2")]
        let withDup = fresh + [TestFixtures.makeSong(id: "video-3")]
        for index in 0 ..< 6 {
            self.mockClient.radioQueueSongs["video-\(index)"] = withDup
        }

        self.playerService.setShuffleMode(.smart)
        // Drive the fill deterministically instead of racing the fire-and-forget phase-2 Task;
        // its re-entrancy guard makes this explicit call the one that does the work.
        await self.playerService.fillSmartShuffleWindow()

        let videoIds = self.playerService.queue.map(\.videoId)
        #expect(self.playerService.queue.count > 6)
        #expect(videoIds.contains("rec-1"))
        #expect(videoIds.count(where: { $0 == "video-3" }) == 1) // duplicate not re-added
        #expect(self.playerService.queueEntries.contains { $0.source == .suggested })
    }

    @Test("leaving smart mode strips suggestions")
    func leavingSmartStrips() async {
        let songs = TestFixtures.makeSongs(count: 6)
        await self.playerService.playQueue(songs, startingAt: 0)
        for index in 0 ..< 6 {
            self.mockClient.radioQueueSongs["video-\(index)"] = [TestFixtures.makeSong(id: "rec-\(index)")]
        }
        self.playerService.setShuffleMode(.smart)
        await self.playerService.fillSmartShuffleWindow()
        #expect(self.playerService.queueEntries.contains { $0.source == .suggested })

        self.playerService.setShuffleMode(.off)
        #expect(!self.playerService.queueEntries.contains { $0.source == .suggested })
        #expect(self.playerService.queue.allSatisfy { $0.videoId.hasPrefix("video-") })
    }

    @Test("entering Smart Shuffle from plain shuffle preserves the original-order snapshot")
    func smartFromPlainShufflePreservesOriginalSnapshot() async {
        let songs = TestFixtures.makeSongs(count: 5)
        await self.playerService.playQueue(songs, startingAt: 0)
        let originalEntries = self.playerService.queueEntries
        let originalOrder = originalEntries.map(\.song.videoId)

        var plainShuffledEntries = originalEntries
        plainShuffledEntries.swapAt(1, 2)
        self.playerService.setQueue(entries: plainShuffledEntries)
        self.playerService.currentIndex = 0
        self.playerService.queueOrderBeforeShuffle = originalEntries
        self.playerService.shuffleMode = .on

        self.playerService.setShuffleMode(.smart)
        #expect(self.playerService.queueOrderBeforeShuffle?.map(\.song.videoId) == originalOrder)

        self.playerService.setShuffleMode(.off)
        #expect(self.playerService.queue.map(\.videoId) == originalOrder)
    }

    @Test("disabling Smart Shuffle while a fill is in flight prevents late insertions")
    func disablingSmartShuffleStopsInFlightFill() async {
        let featureGate = SmartShuffleFeatureGate(isEnabled: true)
        self.playerService.smartShuffleFeatureEnabled = { featureGate.isEnabled }

        let songs = TestFixtures.makeSongs(count: 6)
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.shuffleMode = .smart
        self.mockClient.getRadioQueueDelay = .milliseconds(100)
        self.mockClient.radioQueueSongs["video-0"] = [TestFixtures.makeSong(id: "rec-0")]

        let fill = Task { await self.playerService.fillSmartShuffleWindow() }
        try? await Task.sleep(for: .milliseconds(20))
        featureGate.isEnabled = false
        await fill.value

        #expect(!self.playerService.queueEntries.contains { $0.source == .suggested })
    }

    @Test("Redoing Smart Shuffle restarts the canceled recommendation fill")
    func redoSmartShuffleRestartsCanceledFill() async {
        let settings = SettingsManager.shared
        let savedAhead = settings.smartShuffleSuggestionsAhead
        let savedEveryN = settings.smartShuffleSuggestEveryN
        let savedBurst = settings.smartShuffleBurst
        settings.smartShuffleSuggestionsAhead = 1
        settings.smartShuffleSuggestEveryN = 1
        settings.smartShuffleBurst = 1
        defer {
            settings.smartShuffleSuggestionsAhead = savedAhead
            settings.smartShuffleSuggestEveryN = savedEveryN
            settings.smartShuffleBurst = savedBurst
        }

        let songs = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(songs, startingAt: 0)
        for song in songs {
            self.mockClient.radioQueueSongs[song.videoId] = [
                TestFixtures.makeSong(id: "redo-rec-\(song.videoId)"),
            ]
        }
        let releaseRequests = AsyncGate()
        self.mockClient.beforeRadioQueueReturn = { _ in
            await releaseRequests.wait()
        }

        self.playerService.setShuffleMode(.smart)
        for _ in 0 ..< 20 where self.mockClient.getRadioQueueVideoIds.count < 1 {
            await Task.yield()
        }
        #expect(self.mockClient.getRadioQueueVideoIds.count == 1)

        await self.playerService.undoQueue()
        #expect(self.playerService.shuffleMode == .off)
        await self.playerService.redoQueue()
        #expect(self.playerService.shuffleMode == .smart)
        for _ in 0 ..< 20 where self.mockClient.getRadioQueueVideoIds.count < 2 {
            await Task.yield()
        }

        let restoredFill = self.playerService.smartShuffleFillTask
        #expect(self.mockClient.getRadioQueueVideoIds.count == 2)
        await releaseRequests.open()
        await restoredFill?.value
        #expect(self.playerService.queueEntries.contains { $0.source == .suggested })
    }

    @Test("Stop cancels an in-flight Smart Shuffle fill")
    func stopCancelsInFlightSmartShuffleFill() async {
        let songs = TestFixtures.makeSongs(count: 6)
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.shuffleMode = .smart
        self.mockClient.radioQueueSongs["video-0"] = [TestFixtures.makeSong(id: "late-rec")]
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        self.mockClient.beforeRadioQueueReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }

        let entryIDs = self.playerService.queueEntryIDs
        let fill = Task { @MainActor in
            await self.playerService.fillSmartShuffleWindow()
        }
        await requestStarted.wait()
        await self.playerService.stop()
        await releaseRequest.open()
        await fill.value

        #expect(self.playerService.queueEntryIDs == entryIDs)
        #expect(!self.playerService.queueEntries.contains { $0.source == .suggested })
        #expect(!self.playerService.isApplyingSmartShuffle)
    }

    @Test("Stop invalidates a scheduled Smart Shuffle fill before it starts")
    func stopInvalidatesScheduledSmartShuffleFill() async {
        let songs = TestFixtures.makeSongs(count: 3)
        await self.playerService.playQueue(songs, startingAt: 0)
        self.mockClient.radioQueueSongs[songs[0].videoId] = [TestFixtures.makeSong(id: "late")]

        self.playerService.setShuffleMode(.smart)
        await self.playerService.stop()
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(!self.mockClient.getRadioQueueCalled)
        #expect(!self.playerService.queueEntries.contains { $0.source == .suggested })
    }

    @Test("Pausing initial playback keeps Smart Shuffle fill eligible")
    func pauseKeepsSmartShuffleFillEligible() async {
        self.playerService.shuffleMode = .smart
        let songs = (0 ..< SettingsManager.smartShuffleSuggestEveryNRange.upperBound).map {
            TestFixtures.makeSong(id: "seed-\($0)")
        }
        self.mockClient.songResponses[songs[0].videoId] = songs[0]
        for song in songs {
            self.mockClient.radioQueueSongs[song.videoId] = [
                TestFixtures.makeSong(id: "suggestion-\(song.videoId)"),
            ]
        }
        let metadataStarted = AsyncGate()
        let releaseMetadata = AsyncGate()
        self.mockClient.beforeGetSongReturn = { _ in
            await metadataStarted.open()
            await releaseMetadata.wait()
        }

        let playTask = Task { @MainActor in
            await self.playerService.playQueue(songs, startingAt: 0)
        }
        await metadataStarted.wait()
        await self.playerService.pause()
        await releaseMetadata.open()
        await playTask.value
        // Drive the single-flight fill explicitly so the assertion does not
        // depend on executor timing after the metadata gate is released.
        await self.playerService.fillSmartShuffleWindow()

        #expect(self.playerService.queueEntries.contains { $0.source == .suggested })
    }

    @Test("undo cancels an in-flight Smart Shuffle fill for the replaced queue")
    func undoCancelsInFlightSmartShuffleFill() async {
        let songs = TestFixtures.makeSongs(count: 4)
        await self.playerService.playQueue(songs, startingAt: 0)
        self.playerService.shuffleMode = .smart
        self.mockClient.getRadioQueueDelay = .milliseconds(100)
        self.mockClient.radioQueueSongs["video-0"] = [TestFixtures.makeSong(id: "rec-stale")]

        self.playerService.recordQueueStateForUndo()
        self.playerService.setQueue(entries: self.playerService.queueEntries + [
            QueueEntry(id: UUID(), song: TestFixtures.makeSong(id: "extra")),
        ])

        let fill = Task { await self.playerService.fillSmartShuffleWindow() }
        try? await Task.sleep(for: .milliseconds(20))
        await self.playerService.undoQueue()
        await fill.value

        #expect(!self.playerService.queueEntries.contains { $0.source == .suggested })
        #expect(self.playerService.queue.map(\.videoId) == ["video-0", "video-1", "video-2", "video-3"])
    }

    @Test("turning Smart Shuffle off while a suggestion is playing keeps the remaining playlist ahead")
    func turningSmartOffKeepsRemainingPlaylistAfterCurrentSuggestedEntry() {
        let originals = TestFixtures.makeSongs(count: 5).map { QueueEntry(id: UUID(), song: $0) }
        let suggestion = QueueEntry(
            id: UUID(),
            song: TestFixtures.makeSong(id: "rec-current"),
            source: .suggested
        )
        self.playerService.setQueue(entries: [
            originals[0],
            originals[2],
            suggestion,
            originals[3],
            originals[1],
            originals[4],
        ])
        self.playerService.currentIndex = 2
        self.playerService.currentTrack = suggestion.song
        self.playerService.activePlaybackQueueEntryID = suggestion.id
        self.playerService.queueOrderBeforeShuffle = originals
        self.playerService.shuffleMode = .smart

        self.playerService.setShuffleMode(.off)

        #expect(self.playerService.shuffleMode == .off)
        #expect(self.playerService.currentTrack?.videoId == "rec-current")
        #expect(self.playerService.currentIndex == 2)
        #expect(self.playerService.queue.map(\.videoId) == [
            "video-0",
            "video-2",
            "rec-current",
            "video-1",
            "video-3",
            "video-4",
        ])
    }

    @Test("advancing near the end of a smart queue tops up with fresh suggestions")
    func smartTopUp() async {
        // Force lazy top-up: a small look-ahead window (min 5) with one slot per original means
        // the engine cannot place every possible suggestion up front, so advancing past them must
        // trigger additional radio fetches.
        let settings = SettingsManager.shared
        let savedAhead = settings.smartShuffleSuggestionsAhead
        let savedEveryN = settings.smartShuffleSuggestEveryN
        settings.smartShuffleSuggestionsAhead = 5
        settings.smartShuffleSuggestEveryN = 1
        defer {
            settings.smartShuffleSuggestionsAhead = savedAhead
            settings.smartShuffleSuggestEveryN = savedEveryN
        }

        let songs = TestFixtures.makeSongs(count: 10) // video-0...video-9
        await self.playerService.playQueue(songs, startingAt: 0)
        // Distinct radio per seed so re-seeding yields new songs each top-up.
        for index in 0 ..< 10 {
            self.mockClient.radioQueueSongs["video-\(index)"] = [
                TestFixtures.makeSong(id: "rec-\(index)-a"),
                TestFixtures.makeSong(id: "rec-\(index)-b"),
            ]
        }
        self.playerService.setShuffleMode(.smart)
        await self.playerService.fillSmartShuffleWindow()
        let countAfterEnter = self.playerService.queue.count
        let radioCallsAfterEntry = self.mockClient.getRadioQueueVideoIds.count

        // Drain toward the end. Each next() awaits its own fill, so no sleep is needed.
        for _ in 0 ..< (self.playerService.queue.count - 1) {
            await self.playerService.next()
        }

        #expect(self.playerService.queue.count >= countAfterEnter)
        #expect(self.mockClient.getRadioQueueVideoIds.count > radioCallsAfterEntry)
    }

    @Test("current Smart Shuffle suggestion restores with its suggested source")
    func currentSmartShuffleSuggestionRestoresSuggestedSource() {
        let originalBefore = QueueEntry(id: UUID(), song: TestFixtures.makeSong(id: "video-before"))
        let currentSuggestion = QueueEntry(
            id: UUID(),
            song: TestFixtures.makeSong(id: "rec-current"),
            source: .suggested
        )
        let originalAfter = QueueEntry(id: UUID(), song: TestFixtures.makeSong(id: "video-after"))
        self.playerService.setQueue(entries: [originalBefore, currentSuggestion, originalAfter])
        self.playerService.currentIndex = 1
        self.playerService.currentTrack = currentSuggestion.song
        self.playerService.activePlaybackQueueEntryID = currentSuggestion.id
        self.playerService.saveQueueForPersistence()
        defer { self.playerService.clearSavedQueue() }

        let restored = PlayerService()
        restored.useQueuePersistenceNamespaceForTesting(self.persistenceNamespace)
        #expect(restored.restoreQueueFromPersistence())
        #expect(restored.queue.map(\.videoId) == ["video-before", "rec-current", "video-after"])
        #expect(restored.queueEntries.map(\.source) == [.queued, .suggested, .queued])
        #expect(restored.currentIndex == 1)
    }

    @Test("Detached playback does not preserve a queue-cursor suggestion when leaving Smart Shuffle")
    func detachedPlaybackDoesNotKeepSuggestedCursor() {
        let original = QueueEntry(id: UUID(), song: TestFixtures.makeSong(id: "detached-original"))
        let suggestion = QueueEntry(
            id: UUID(),
            song: TestFixtures.makeSong(id: "detached-suggestion"),
            source: .suggested
        )
        let trailing = QueueEntry(id: UUID(), song: TestFixtures.makeSong(id: "detached-trailing"))
        self.playerService.setQueue(entries: [original, suggestion, trailing])
        self.playerService.queueOrderBeforeShuffle = [original, trailing]
        self.playerService.currentIndex = 1
        self.playerService.currentTrack = TestFixtures.makeSong(id: "detached-track")
        self.playerService.activePlaybackQueueEntryID = nil
        self.playerService.shuffleMode = .smart

        self.playerService.setShuffleMode(.off)

        #expect(!self.playerService.queueEntries.contains(where: { $0.source == .suggested }))
        #expect(self.playerService.queueEntryIDs == [original.id, trailing.id])
    }

    @Test("A stopped queue cursor does not persist a Smart Shuffle suggestion")
    func stoppedQueueCursorDoesNotPersistSuggestion() {
        let original = QueueEntry(id: UUID(), song: TestFixtures.makeSong(id: "stopped-original"))
        let suggestion = QueueEntry(
            id: UUID(),
            song: TestFixtures.makeSong(id: "stopped-suggestion"),
            source: .suggested
        )
        self.playerService.setQueue(entries: [original, suggestion])
        self.playerService.currentIndex = 1
        self.playerService.currentTrack = nil
        self.playerService.activePlaybackQueueEntryID = nil
        self.playerService.saveQueueForPersistence()
        defer { self.playerService.clearSavedQueue() }

        let restored = PlayerService()
        restored.useQueuePersistenceNamespaceForTesting(self.persistenceNamespace)
        #expect(restored.restoreQueueFromPersistence())
        #expect(restored.queue.map(\.videoId) == [original.song.videoId])
    }

    @Test("Undoing shuffle restores both mode and authored order")
    func undoShuffleRestoresModeAndOrder() async {
        let songs = TestFixtures.makeSongs(count: 4)
        await self.playerService.playQueue(songs, startingAt: 1)
        let originalEntryIDs = self.playerService.queueEntryIDs

        self.playerService.setShuffleMode(.on)
        await self.playerService.undoQueue()

        #expect(self.playerService.shuffleMode == .off)
        #expect(self.playerService.queueEntryIDs == originalEntryIDs)
        #expect(self.playerService.queueOrderBeforeShuffle == nil)
    }

    @Test("Persisted shuffle can restore authored order after relaunch")
    func persistedShuffleRestoresAuthoredOrder() async {
        let songs = TestFixtures.makeSongs(count: 4)
        await self.playerService.playQueue(songs, startingAt: 2)
        self.playerService.setShuffleMode(.on)
        self.playerService.saveQueueForPersistence()
        defer { self.playerService.clearSavedQueue() }

        let restored = PlayerService()
        restored.useQueuePersistenceNamespaceForTesting(self.persistenceNamespace)
        #expect(restored.restoreQueueFromPersistence())
        #expect(restored.shuffleMode == .on)
        restored.setShuffleMode(.off)

        #expect(restored.queue.map(\.videoId) == songs.map(\.videoId))
    }

    @Test("Persisted shuffle preserves the active identical duplicate occurrence")
    func persistedShufflePreservesActiveDuplicate() async {
        let duplicate = TestFixtures.makeSong(id: "persisted-duplicate")
        let middle = TestFixtures.makeSong(id: "persisted-middle")
        await self.playerService.playQueue([duplicate, middle, duplicate], startingAt: 2)
        self.playerService.setShuffleMode(.on)
        self.playerService.saveQueueForPersistence()
        defer { self.playerService.clearSavedQueue() }

        let restored = PlayerService()
        restored.useQueuePersistenceNamespaceForTesting(self.persistenceNamespace)
        #expect(restored.restoreQueueFromPersistence())
        restored.setShuffleMode(.off)

        #expect(restored.queue.map(\.videoId) == [duplicate.videoId, middle.videoId, duplicate.videoId])
        #expect(restored.activePlaybackQueueIndex == 2)
    }

    @Test("Persisted pre-shuffle order preserves non-active duplicate payloads")
    func persistedPreShuffleOrderPreservesDuplicatePayloads() {
        let firstDuplicate = Song(
            id: "shared-duplicate",
            title: "First authored occurrence",
            artists: [],
            videoId: "shared-duplicate"
        )
        let secondDuplicate = Song(
            id: "shared-duplicate",
            title: "Second authored occurrence",
            artists: [],
            videoId: "shared-duplicate"
        )
        let active = TestFixtures.makeSong(id: "duplicate-active", title: "Active")
        let firstEntry = QueueEntry(id: UUID(), song: firstDuplicate)
        let secondEntry = QueueEntry(id: UUID(), song: secondDuplicate)
        let activeEntry = QueueEntry(id: UUID(), song: active)
        self.playerService.setQueue(entries: [activeEntry, secondEntry, firstEntry])
        self.playerService.currentIndex = 0
        self.playerService.activePlaybackQueueEntryID = activeEntry.id
        self.playerService.currentTrack = active
        self.playerService.pendingPlayVideoId = active.videoId
        self.playerService.queueOrderBeforeShuffle = [firstEntry, secondEntry, activeEntry]
        self.playerService.shuffleMode = .on
        self.playerService.saveQueueForPersistence()
        defer { self.playerService.clearSavedQueue() }

        let restored = PlayerService()
        restored.useQueuePersistenceNamespaceForTesting(self.persistenceNamespace)
        #expect(restored.restoreQueueFromPersistence())
        restored.setShuffleMode(.off)

        #expect(restored.queue.map(\.title) == [
            "First authored occurrence",
            "Second authored occurrence",
            "Active",
        ])
        #expect(restored.currentIndex == 2)
        #expect(restored.currentTrack?.videoId == active.videoId)
    }

    @Test("Queue history downgrades Smart Shuffle when the feature is disabled")
    func queueHistorySmartShuffleRespectsDisabledSetting() async {
        await self.playerService.playQueue(TestFixtures.makeSongs(count: 3), startingAt: 0)
        let originalEntries = self.playerService.queueEntries
        let suggestion = QueueEntry(
            id: UUID(),
            song: TestFixtures.makeSong(id: "disabled-history-suggestion"),
            source: .suggested
        )
        self.playerService.setQueue(entries: [originalEntries[0], suggestion] + Array(originalEntries.dropFirst()))
        self.playerService.currentIndex = 0
        self.playerService.activePlaybackQueueEntryID = originalEntries[0].id
        self.playerService.shuffleMode = .smart
        let smartState = self.playerService.makeQueueStateSnapshot()
        self.playerService.shuffleMode = .off
        self.playerService.clearQueueUndoRedoHistory()
        self.playerService.recordQueueStateForUndo(smartState)
        self.playerService.smartShuffleFeatureEnabled = { false }

        await self.playerService.undoQueue()
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(self.playerService.shuffleMode == .on)
        #expect(!self.playerService.queueEntries.contains { $0.source == .suggested })
        #expect(!self.mockClient.getRadioQueueCalled)
    }

    @Test("Persisted Smart Shuffle downgrades when the feature is disabled")
    func persistedSmartShuffleRespectsDisabledSetting() async {
        await self.playerService.playQueue(TestFixtures.makeSongs(count: 3), startingAt: 0)
        self.playerService.setShuffleMode(.smart)
        self.playerService.saveQueueForPersistence()
        defer { self.playerService.clearSavedQueue() }
        let restored = PlayerService()
        restored.useQueuePersistenceNamespaceForTesting(self.persistenceNamespace)
        restored.smartShuffleFeatureEnabled = { false }
        #expect(restored.restoreQueueFromPersistence())
        #expect(restored.shuffleMode == .on)
    }

    @Test("suggestions are ephemeral: not persisted across a save/restore")
    func suggestionsNotPersisted() async {
        let songs = TestFixtures.makeSongs(count: 4)
        await self.playerService.playQueue(songs, startingAt: 0)
        for index in 0 ..< 4 {
            self.mockClient.radioQueueSongs["video-\(index)"] = [TestFixtures.makeSong(id: "rec-\(index)")]
        }
        self.playerService.setShuffleMode(.smart)
        await self.playerService.fillSmartShuffleWindow()
        #expect(self.playerService.queueEntries.contains { $0.source == .suggested })
        let originalIds = Set(songs.map(\.videoId))

        self.playerService.saveQueueForPersistence()

        // A fresh service restoring from the same UserDefaults gets only the originals back — no
        // suggestions. They are regenerated from live playback context, never persisted. (No client
        // is attached and we assert synchronously, so no top-up can run before the checks.)
        let restored = PlayerService()
        restored.useQueuePersistenceNamespaceForTesting(self.persistenceNamespace)
        #expect(restored.restoreQueueFromPersistence())
        #expect(restored.queueEntries.allSatisfy { $0.source == .queued })
        #expect(Set(restored.queue.map(\.videoId)) == originalIds)
    }

    @Test("a persisted smart mode resolves to .on when Smart Shuffle is disabled")
    func disabledSmartDowngradesOnLaunch() {
        #expect(PlayerService.resolvedShuffleMode(.smart, smartShuffleEnabled: false) == .on)
    }

    @Test("clamped Smart Shuffle numeric settings persist the corrected values")
    func clampedSmartShuffleSettingsPersist() {
        let settings = SettingsManager.shared
        let defaults = UserDefaults.standard
        let savedEveryN = settings.smartShuffleSuggestEveryN
        let savedBurst = settings.smartShuffleBurst
        let savedAhead = settings.smartShuffleSuggestionsAhead
        let savedEveryNObject = defaults.object(forKey: SettingsManager.Keys.smartShuffleSuggestEveryN)
        let savedBurstObject = defaults.object(forKey: SettingsManager.Keys.smartShuffleBurst)
        let savedAheadObject = defaults.object(forKey: SettingsManager.Keys.smartShuffleSuggestionsAhead)

        func restore(_ value: Any?, forKey key: String) {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defer {
            settings.smartShuffleSuggestEveryN = savedEveryN
            settings.smartShuffleBurst = savedBurst
            settings.smartShuffleSuggestionsAhead = savedAhead
            restore(savedEveryNObject, forKey: SettingsManager.Keys.smartShuffleSuggestEveryN)
            restore(savedBurstObject, forKey: SettingsManager.Keys.smartShuffleBurst)
            restore(savedAheadObject, forKey: SettingsManager.Keys.smartShuffleSuggestionsAhead)
        }

        settings.smartShuffleSuggestEveryN = SettingsManager.smartShuffleSuggestEveryNRange.upperBound + 10
        settings.smartShuffleBurst = SettingsManager.smartShuffleBurstRange.lowerBound - 10
        settings.smartShuffleSuggestionsAhead = SettingsManager.smartShuffleSuggestionsAheadRange.upperBound + 10

        #expect(settings.smartShuffleSuggestEveryN == SettingsManager.smartShuffleSuggestEveryNRange.upperBound)
        #expect(settings.smartShuffleBurst == SettingsManager.smartShuffleBurstRange.lowerBound)
        #expect(settings.smartShuffleSuggestionsAhead == SettingsManager.smartShuffleSuggestionsAheadRange.upperBound)
        #expect(defaults.integer(forKey: SettingsManager.Keys.smartShuffleSuggestEveryN) == settings.smartShuffleSuggestEveryN)
        #expect(defaults.integer(forKey: SettingsManager.Keys.smartShuffleBurst) == settings.smartShuffleBurst)
        #expect(defaults.integer(forKey: SettingsManager.Keys.smartShuffleSuggestionsAhead) == settings.smartShuffleSuggestionsAhead)
    }

    @Test("playing while loading defers the fill; it dedups against late-loaded tracks (#1)")
    func deferredFillDedupsAgainstFullPlaylist() async {
        // Production order: smart mode is active first, THEN a large playlist starts playing while
        // still loading. The premature fill must be suppressed by the deferral, not run on the
        // initial batch (the bug the load-coordination subsystem exists to prevent).
        self.playerService.setShuffleMode(.smart)
        let initial = TestFixtures.makeSongs(count: 4) // video-0...video-3
        // Each seed's radio offers a fresh rec plus video-5, which loads later as an original.
        for index in 0 ..< 6 {
            self.mockClient.radioQueueSongs["video-\(index)"] = [
                TestFixtures.makeSong(id: "rec-\(index)"),
                TestFixtures.makeSong(id: "video-5"),
            ]
        }

        let loadGeneration = await self.playerService.playQueue(initial, startingAt: 0, deferringSmartShuffleFill: true)
        #expect(loadGeneration != nil)
        #expect(!self.playerService.queueEntries.contains { $0.source == .suggested })

        // The rest of the playlist pages in (including video-5).
        self.playerService.appendOriginalTracks([
            TestFixtures.makeSong(id: "video-4"),
            TestFixtures.makeSong(id: "video-5"),
        ])
        if let loadGeneration {
            await self.playerService.endQueueLoading(loadGeneration)
        }

        let videoIds = self.playerService.queue.map(\.videoId)
        let suggested = self.playerService.queueEntries.filter { $0.source == .suggested }.map(\.song.videoId)
        #expect(!suggested.isEmpty) // suggestions generated once fully loaded
        #expect(suggested.allSatisfy { $0.hasPrefix("rec-") })
        #expect(!suggested.contains("video-5")) // late-loaded original not duplicated as a suggestion
        #expect(videoIds.count(where: { $0 == "video-5" }) == 1)
    }

    @Test("deferred loading preserves duplicate original playlist entries")
    func deferredLoadingPreservesDuplicateOriginals() async {
        let initial = [
            TestFixtures.makeSong(id: "video-0"),
            TestFixtures.makeSong(id: "video-1"),
        ]
        let loadGeneration = await self.playerService.playQueue(initial, startingAt: 0, deferringSmartShuffleFill: true)

        self.playerService.appendOriginalTracks([
            TestFixtures.makeSong(id: "video-1"),
            TestFixtures.makeSong(id: "video-2"),
        ])
        if let loadGeneration {
            await self.playerService.endQueueLoading(loadGeneration)
        }

        #expect(self.playerService.queue.map(\.videoId) == ["video-0", "video-1", "video-1", "video-2"])
    }

    @Test("finishing a load re-shuffles the full queue and keeps off-restore order complete")
    func endQueueLoadingReshufflesFullSet() async {
        self.playerService.setShuffleMode(.on)
        let initial = TestFixtures.makeSongs(count: 4)
        let loadGeneration = await self.playerService.playQueue(initial, startingAt: 0, deferringSmartShuffleFill: true)

        let remaining = (4 ..< 24).map { TestFixtures.makeSong(id: "video-\($0)") }
        self.playerService.appendOriginalTracks(remaining)
        if let loadGeneration {
            await self.playerService.endQueueLoading(loadGeneration)
        }

        let originalOrder = (0 ..< 24).map { "video-\($0)" }
        #expect(Set(self.playerService.queue.map(\.videoId)) == Set(originalOrder))

        // Turning shuffle off restores the COMPLETE playlist order (snapshot grew with the queue).
        self.playerService.setShuffleMode(.off)
        #expect(self.playerService.queue.map(\.videoId) == originalOrder)
    }

    @Test("with shuffle off, a loading queue grows in playlist order without suggestions")
    func offModeKeepsOrderWhileLoading() async {
        let initial = TestFixtures.makeSongs(count: 4)
        let loadGeneration = await self.playerService.playQueue(initial, startingAt: 0, deferringSmartShuffleFill: true)
        self.playerService.appendOriginalTracks((4 ..< 8).map { TestFixtures.makeSong(id: "video-\($0)") })
        if let loadGeneration {
            await self.playerService.endQueueLoading(loadGeneration)
        }

        #expect(self.playerService.queue.map(\.videoId) == (0 ..< 8).map { "video-\($0)" })
        #expect(!self.playerService.queueEntries.contains { $0.source == .suggested })
    }

    @Test("a new playback supersedes an in-flight deferred load; user edits do not (#5, #8)")
    func loadSupersededByNewPlayback() async {
        let songs = TestFixtures.makeSongs(count: 6)
        let loadGeneration = await self.playerService.playQueue(songs, startingAt: 0, deferringSmartShuffleFill: true)
        #expect(loadGeneration != nil)
        guard let loadGeneration else { return }
        #expect(self.playerService.isCurrentQueueLoad(loadGeneration))

        // Shuffling reorders the same entries — the load stays current.
        self.playerService.setShuffleMode(.on)
        #expect(self.playerService.isCurrentQueueLoad(loadGeneration))

        // Removing a track is a user edit, not a new playback — the load stays current (#8).
        self.playerService.removeFromQueue(at: 5)
        #expect(self.playerService.isCurrentQueueLoad(loadGeneration))

        // Starting a different playback supersedes it (#5).
        await self.playerService.playQueue(TestFixtures.makeSongs(count: 3), startingAt: 0)
        #expect(!self.playerService.isCurrentQueueLoad(loadGeneration))
        // A stale finish is a no-op: it must not re-shuffle or touch the new playback's queue.
        await self.playerService.endQueueLoading(loadGeneration)
        #expect(self.playerService.queue.count == 3)
    }

    @Test("playing a standalone episode supersedes an in-flight deferred playlist load")
    func episodeSupersedesDeferredLoad() async {
        let songs = TestFixtures.makeSongs(count: 6)
        let loadGeneration = await self.playerService.playQueue(songs, startingAt: 0, deferringSmartShuffleFill: true)
        #expect(loadGeneration != nil)
        guard let loadGeneration else { return }
        #expect(self.playerService.isCurrentQueueLoad(loadGeneration))

        // A standalone episode replaces the queue and must supersede the deferred load.
        await self.playerService.playEpisode(ArtistEpisode(videoId: "live-1", title: "Live Stream", isLive: true))
        #expect(!self.playerService.isCurrentQueueLoad(loadGeneration))

        // A stale finish must not resurrect the playlist behind the episode.
        await self.playerService.endQueueLoading(loadGeneration)
        #expect(self.playerService.queue.isEmpty)
    }

    @Test("switching playlists in smart mode resets seen state so the new queue gets suggestions (#4)")
    func switchingPlaylistsResetsSmartState() async {
        let settings = SettingsManager.shared
        let savedEveryN = settings.smartShuffleSuggestEveryN
        settings.smartShuffleSuggestEveryN = 1
        defer { settings.smartShuffleSuggestEveryN = savedEveryN }

        // Playlist A: every seed's radio offers the same "shared-rec".
        let aSongs = (0 ..< 4).map { TestFixtures.makeSong(id: "a-\($0)") }
        for song in aSongs {
            self.mockClient.radioQueueSongs[song.videoId] = [TestFixtures.makeSong(id: "shared-rec")]
        }
        await self.playerService.playQueue(aSongs, startingAt: 0)
        self.playerService.setShuffleMode(.smart)
        await self.playerService.fillSmartShuffleWindow()
        #expect(self.playerService.queue.contains { $0.videoId == "shared-rec" })

        // Playlist B (still smart): same shared-rec available. Without the reset, A's seen set would
        // exclude "shared-rec" and B would get no suggestions.
        let bSongs = (0 ..< 4).map { TestFixtures.makeSong(id: "b-\($0)") }
        for song in bSongs {
            self.mockClient.radioQueueSongs[song.videoId] = [TestFixtures.makeSong(id: "shared-rec")]
        }
        await self.playerService.playQueue(bSongs, startingAt: 0)
        await self.playerService.fillSmartShuffleWindow()
        #expect(self.playerService.queue.contains { $0.videoId == "shared-rec" })
        #expect(self.playerService.queue.allSatisfy { $0.videoId.hasPrefix("b-") || $0.videoId == "shared-rec" })
    }

    @Test("a radio error on one seed does not abort the whole fill pass (#9)")
    func radioThrowOnOneSeedStillFillsOthers() async {
        let settings = SettingsManager.shared
        let savedEveryN = settings.smartShuffleSuggestEveryN
        settings.smartShuffleSuggestEveryN = 1
        defer { settings.smartShuffleSuggestEveryN = savedEveryN }

        let songs = TestFixtures.makeSongs(count: 6)
        await self.playerService.playQueue(songs, startingAt: 0)
        // The current track's seed (video-0, kept at the front) throws; the rest return a fresh rec.
        self.mockClient.radioQueueErrors["video-0"] = URLError(.timedOut)
        for index in 1 ..< 6 {
            self.mockClient.radioQueueSongs["video-\(index)"] = [TestFixtures.makeSong(id: "rec-\(index)")]
        }

        self.playerService.setShuffleMode(.smart)
        await self.playerService.fillSmartShuffleWindow()

        let suggested = self.playerService.queueEntries.filter { $0.source == .suggested }.map(\.song.videoId)
        #expect(!suggested.isEmpty) // later seeds still filled despite the nearest seed throwing
        #expect(suggested.allSatisfy { $0.hasPrefix("rec-") })
    }

    @Test("resetSmartShuffleState preserves the in-flight hint; cancel clears it (#6)")
    func resetVersusCancelOnApplyingHint() {
        self.playerService.isApplyingSmartShuffle = true
        self.playerService.resetSmartShuffleState()
        #expect(self.playerService.isApplyingSmartShuffle) // reset must NOT clear a running fill's hint
        self.playerService.cancelSmartShuffleFill()
        #expect(!self.playerService.isApplyingSmartShuffle) // cancel owns teardown of the hint
    }

    @Test("legacy playerShuffleEnabled migrates to .on on launch")
    func legacyMigration() {
        SettingsManager.shared.rememberPlaybackSettings = true
        UserDefaults.standard.removeObject(forKey: "playerShuffleMode")
        UserDefaults.standard.set(true, forKey: "playerShuffleEnabled")

        let service = PlayerService()
        #expect(service.shuffleMode == .on)

        // cleanup
        UserDefaults.standard.removeObject(forKey: "playerShuffleEnabled")
        SettingsManager.shared.rememberPlaybackSettings = false
    }
}
