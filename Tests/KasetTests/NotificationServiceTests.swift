import Foundation
import Testing
@testable import Kaset

/// Tests for NotificationService track-change observation.
@Suite("NotificationService", .serialized, .tags(.service))
@MainActor
struct NotificationServiceTests {
    var playerService: PlayerService
    var notificationService: NotificationService

    init() {
        self.playerService = PlayerService()
        self.notificationService = NotificationService(playerService: self.playerService)
    }

    private func waitForPollingCycle() async {
        // Wait for the 500ms polling interval plus a small margin.
        try? await Task.sleep(for: .milliseconds(700))
    }

    private func setPlaybackActive(_ isPlaying: Bool) {
        self.playerService.updatePlaybackState(
            isPlaying: isPlaying,
            progress: 0,
            duration: 240
        )
    }

    // MARK: - Observation Lifecycle

    @Test("observation task is active after init")
    func observationActiveAfterInit() {
        #expect(self.notificationService.isObserving)
    }

    @Test("stopObserving cancels observation task")
    func stopObservingCancelsTask() {
        self.notificationService.stopObserving()
        #expect(!self.notificationService.isObserving)
    }

    // MARK: - Track Change Detection

    @Test("detects track change and updates lastNotifiedTrackId when playback is active")
    func detectsTrackChange() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "First Song")
        self.setPlaybackActive(true)

        await self.waitForPollingCycle()

        #expect(self.notificationService.lastNotifiedTrackId == "song-1")
    }

    @Test("detects multiple track changes while playing")
    func detectsMultipleTrackChanges() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "First Song")
        self.setPlaybackActive(true)
        await self.waitForPollingCycle()
        #expect(self.notificationService.lastNotifiedTrackId == "song-1")

        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-2", title: "Second Song")
        await self.waitForPollingCycle()
        #expect(self.notificationService.lastNotifiedTrackId == "song-2")
    }

    @Test("does not notify for paused restored track")
    func doesNotNotifyForPausedTrack() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "Restored Song")
        self.setPlaybackActive(false)

        await self.waitForPollingCycle()

        #expect(self.notificationService.lastNotifiedTrackId == nil)
    }

    @Test("notifies when paused current track starts playing")
    func notifiesWhenPlaybackStartsForCurrentTrack() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "Restored Song")
        self.setPlaybackActive(false)

        await self.waitForPollingCycle()
        #expect(self.notificationService.lastNotifiedTrackId == nil)

        self.setPlaybackActive(true)

        await self.waitForPollingCycle()
        #expect(self.notificationService.lastNotifiedTrackId == "song-1")
    }

    @Test("does not notify for same track twice")
    func doesNotNotifyForSameTrackTwice() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "First Song")
        self.setPlaybackActive(true)
        await self.waitForPollingCycle()
        #expect(self.notificationService.lastNotifiedTrackId == "song-1")

        // Set a different track, then back to the same one
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-2", title: "Second Song")
        await self.waitForPollingCycle()

        // The lastNotifiedTrackId should now be song-2, meaning song-1 wasn't skipped
        #expect(self.notificationService.lastNotifiedTrackId == "song-2")
    }

    @Test("skips tracks with Loading... title")
    func skipsLoadingTracks() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "loading-track", title: "Loading...")
        self.setPlaybackActive(true)
        await self.waitForPollingCycle()

        #expect(self.notificationService.lastNotifiedTrackId == nil)
    }

    @Test("notifies when loading track resolves and playback starts")
    func notifiesAfterLoadingResolves() async {
        // First set loading placeholder
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "Loading...")
        self.setPlaybackActive(false)
        await self.waitForPollingCycle()
        #expect(self.notificationService.lastNotifiedTrackId == nil)

        // The resolved metadata should notify once playback actually starts.
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "Real Song")
        self.setPlaybackActive(true)
        await self.waitForPollingCycle()
        #expect(self.notificationService.lastNotifiedTrackId == "song-1")
    }

    @Test("no notification when track is nil")
    func noNotificationWhenTrackIsNil() async {
        self.playerService.currentTrack = nil
        await self.waitForPollingCycle()

        #expect(self.notificationService.lastNotifiedTrackId == nil)
    }

    // MARK: - Service Retention

    @Test("service remains active after multiple polling cycles")
    func serviceRemainsActiveAfterPolling() async {
        // Verify the observation task survives multiple cycles
        try? await Task.sleep(for: .seconds(2))
        #expect(self.notificationService.isObserving)

        // And still detects changes
        self.playerService.currentTrack = TestFixtures.makeSong(id: "late-song", title: "Late Song")
        self.setPlaybackActive(true)
        await self.waitForPollingCycle()
        #expect(self.notificationService.lastNotifiedTrackId == "late-song")
    }
}
