import Foundation
import Testing
@testable import Kaset

/// Tests for NotificationService track-change observation.
@Suite(.serialized, .tags(.service))
@MainActor
struct NotificationServiceTests {
    var playerService: PlayerService
    var notificationService: NotificationService

    init() {
        self.playerService = PlayerService()
        self.notificationService = NotificationService(playerService: self.playerService)
    }

    private func waitForObservationDelivery() async {
        // Event-driven observation should deliver on the next main-actor turns,
        // without waiting for the old 500ms polling interval.
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// Polls until `condition` holds, bounded by a deadline that tolerates slow CI
    /// runners — a fixed wait races with Observation delivery and the service's
    /// loading-resolution poll loop.
    private func waitForObservationDelivery(until condition: @autoclosure @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition(), clock.now < deadline {
            for _ in 0 ..< 5 {
                await Task.yield()
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Observation Lifecycle

    @Test("observation is active after init")
    func observationActiveAfterInit() {
        #expect(self.notificationService.isObserving)
    }

    @Test("stopObserving disables observation")
    func stopObservingDisablesObservation() {
        self.notificationService.stopObserving()
        #expect(!self.notificationService.isObserving)
    }

    // MARK: - Track Change Detection

    @Test("detects track change without polling delay when playback is active")
    func detectsTrackChangeWithoutPollingDelay() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "First Song")
        self.playerService.state = .playing

        await self.waitForObservationDelivery(until: self.notificationService.lastNotifiedTrackId == "song-1")

        #expect(self.notificationService.lastNotifiedTrackId == "song-1")
    }

    @Test("notifies already playing track on initial observation")
    func notifiesAlreadyPlayingTrackOnInitialObservation() async {
        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "initial-song", title: "Initial Song")
        playerService.state = .playing

        let notificationService = NotificationService(playerService: playerService)
        await self.waitForObservationDelivery(until: notificationService.lastNotifiedTrackId == "initial-song")

        #expect(notificationService.lastNotifiedTrackId == "initial-song")
        notificationService.stopObserving()
    }

    @Test("detects multiple track changes while playing")
    func detectsMultipleTrackChanges() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "First Song")
        self.playerService.state = .playing
        await self.waitForObservationDelivery(until: self.notificationService.lastNotifiedTrackId == "song-1")
        #expect(self.notificationService.lastNotifiedTrackId == "song-1")

        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-2", title: "Second Song")
        await self.waitForObservationDelivery(until: self.notificationService.lastNotifiedTrackId == "song-2")
        #expect(self.notificationService.lastNotifiedTrackId == "song-2")
    }

    @Test("does not notify for paused restored track")
    func doesNotNotifyForPausedTrack() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "Restored Song")
        self.playerService.state = .paused

        await self.waitForObservationDelivery()

        #expect(self.notificationService.lastNotifiedTrackId == nil)
    }

    @Test("notifies when paused current track starts playing")
    func notifiesWhenPlaybackStartsForCurrentTrack() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "Restored Song")
        self.playerService.state = .paused

        await self.waitForObservationDelivery()
        #expect(self.notificationService.lastNotifiedTrackId == nil)

        self.playerService.state = .playing

        await self.waitForObservationDelivery(until: self.notificationService.lastNotifiedTrackId == "song-1")
        #expect(self.notificationService.lastNotifiedTrackId == "song-1")
    }

    @Test("does not notify for same track twice")
    func doesNotNotifyForSameTrackTwice() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "First Song")
        self.playerService.state = .playing
        await self.waitForObservationDelivery(until: self.notificationService.lastNotifiedTrackId == "song-1")
        #expect(self.notificationService.lastNotifiedTrackId == "song-1")

        // Set a different track, then back to the same one
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-2", title: "Second Song")
        await self.waitForObservationDelivery(until: self.notificationService.lastNotifiedTrackId == "song-2")

        // The lastNotifiedTrackId should now be song-2, meaning song-1 wasn't skipped
        #expect(self.notificationService.lastNotifiedTrackId == "song-2")
    }

    @Test("skips tracks with Loading... title")
    func skipsLoadingTracks() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "loading-track", title: "Loading...")
        self.playerService.state = .playing
        await self.waitForObservationDelivery()

        #expect(self.notificationService.lastNotifiedTrackId == nil)
    }

    @Test("notifies when loading track resolves and playback starts")
    func notifiesAfterLoadingResolves() async {
        // First set loading placeholder
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "Loading...")
        self.playerService.state = .loading
        await self.waitForObservationDelivery()
        #expect(self.notificationService.lastNotifiedTrackId == nil)

        // The resolved metadata should notify once playback actually starts.
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "Real Song")
        self.playerService.state = .playing

        await self.waitForObservationDelivery(until: self.notificationService.lastNotifiedTrackId == "song-1")
        #expect(self.notificationService.lastNotifiedTrackId == "song-1")
    }

    @Test("notifies when loading track resolves while already playing")
    func notifiesWhenLoadingTrackResolvesWhilePlaying() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "Loading...")
        self.playerService.state = .playing
        await self.waitForObservationDelivery()
        #expect(self.notificationService.lastNotifiedTrackId == nil)

        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "Real Song")

        await self.waitForObservationDelivery(until: self.notificationService.lastNotifiedTrackId == "song-1")
        #expect(self.notificationService.lastNotifiedTrackId == "song-1")
    }

    @Test("no notification when track is nil")
    func noNotificationWhenTrackIsNil() async {
        self.playerService.currentTrack = nil
        await self.waitForObservationDelivery()

        #expect(self.notificationService.lastNotifiedTrackId == nil)
    }

    @Test("stopObserving prevents future notifications")
    func stopObservingPreventsFutureNotifications() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "First Song")
        self.playerService.state = .playing
        await self.waitForObservationDelivery(until: self.notificationService.lastNotifiedTrackId == "song-1")
        #expect(self.notificationService.lastNotifiedTrackId == "song-1")

        self.notificationService.stopObserving()
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-2", title: "Second Song")
        await self.waitForObservationDelivery()

        #expect(self.notificationService.lastNotifiedTrackId == "song-1")
    }

    // MARK: - Service Retention

    @Test("service remains active between event-driven notifications")
    func serviceRemainsActiveBetweenEvents() async {
        #expect(self.notificationService.isObserving)

        // And still detects changes without a polling delay.
        self.playerService.currentTrack = TestFixtures.makeSong(id: "late-song", title: "Late Song")
        self.playerService.state = .playing
        await self.waitForObservationDelivery(until: self.notificationService.lastNotifiedTrackId == "late-song")
        #expect(self.notificationService.lastNotifiedTrackId == "late-song")
    }
}
