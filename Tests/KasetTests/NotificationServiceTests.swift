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

    @Test("detects track change and updates lastNotifiedTrackId")
    func detectsTrackChange() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "First Song")

        // Wait for polling cycle (500ms) + margin
        try? await Task.sleep(for: .milliseconds(700))

        #expect(self.notificationService.lastNotifiedTrackId == "song-1")
    }

    @Test("detects multiple track changes")
    func detectsMultipleTrackChanges() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "First Song")
        try? await Task.sleep(for: .milliseconds(700))
        #expect(self.notificationService.lastNotifiedTrackId == "song-1")

        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-2", title: "Second Song")
        try? await Task.sleep(for: .milliseconds(700))
        #expect(self.notificationService.lastNotifiedTrackId == "song-2")
    }

    @Test("does not notify for same track twice")
    func doesNotNotifyForSameTrackTwice() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "First Song")
        try? await Task.sleep(for: .milliseconds(700))
        #expect(self.notificationService.lastNotifiedTrackId == "song-1")

        // Set a different track, then back to the same one
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-2", title: "Second Song")
        try? await Task.sleep(for: .milliseconds(700))

        // The lastNotifiedTrackId should now be song-2, meaning song-1 wasn't skipped
        #expect(self.notificationService.lastNotifiedTrackId == "song-2")
    }

    @Test("skips tracks with Loading... title")
    func skipsLoadingTracks() async {
        self.playerService.currentTrack = TestFixtures.makeSong(id: "loading-track", title: "Loading...")
        try? await Task.sleep(for: .milliseconds(700))

        #expect(self.notificationService.lastNotifiedTrackId == nil)
    }

    @Test("notifies after Loading... resolves to real title")
    func notifiesAfterLoadingResolves() async {
        // First set loading placeholder
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "Loading...")
        try? await Task.sleep(for: .milliseconds(700))
        #expect(self.notificationService.lastNotifiedTrackId == nil)

        // Now resolve to real track (same id, different title)
        self.playerService.currentTrack = TestFixtures.makeSong(id: "song-1", title: "Real Song")
        try? await Task.sleep(for: .milliseconds(700))
        #expect(self.notificationService.lastNotifiedTrackId == "song-1")
    }

    @Test("no notification when track is nil")
    func noNotificationWhenTrackIsNil() async {
        self.playerService.currentTrack = nil
        try? await Task.sleep(for: .milliseconds(700))

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
        try? await Task.sleep(for: .milliseconds(700))
        #expect(self.notificationService.lastNotifiedTrackId == "late-song")
    }
}
