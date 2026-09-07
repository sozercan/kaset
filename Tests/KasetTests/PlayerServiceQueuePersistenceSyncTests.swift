import Foundation
import Testing
@testable import Kaset

extension PlayerServiceQueueTests {
    @Test("Unavailable cookie restoration preserves playback ownership until startup cleanup", arguments: [true, false], [true, false])
    func unavailableCookieRestorePreservesPlaybackOwnership(wasGuestQueue: Bool, restoresSession: Bool) async throws {
        let previousAuth = AuthService(webKitManager: MockWebKitManager())
        if wasGuestQueue {
            await previousAuth.checkLoginStatus()
        } else {
            previousAuth.completeLogin(sapisid: "mock-personal-session")
        }
        self.playerService.setAuthService(previousAuth)
        let songs = TestFixtures.makeSongs(count: 2)
        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.saveQueueForPersistence()
        let savedSession = try #require(UserDefaults.standard.data(forKey: "kaset.saved.playbackSession"))
        defer { self.playerService.clearSavedQueue() }

        let restoredService = PlayerService()
        restoredService.setYTMusicClient(self.mockClient)
        #expect(restoredService.restoreQueueFromPersistence())
        let manager = MockWebKitManager()
        manager.waitForInitialCookieRestoreResult = .unavailable
        manager.sapisidValue = restoresSession ? "mock-personal-session" : nil
        let authService = AuthService(webKitManager: manager)
        restoredService.setAuthService(authService)
        await authService.checkLoginStatus()

        let mayFinishStartup = await authService.checkLoginStatusForStartup(expectedState: authService.state)
        if mayFinishStartup {
            restoredService.clearPlaybackForGuestStartup()
        }

        #expect(!mayFinishStartup)
        #expect(restoredService.queue.map(\.id) == songs.map(\.id))
        #expect(restoredService.currentTrack?.id == songs[1].id)
        restoredService.saveQueueForPersistence()
        #expect(UserDefaults.standard.data(forKey: "kaset.saved.playbackSession") == savedSession)

        let cookieReadEntered = AsyncGate()
        let releaseCookieRead = AsyncGate()
        manager.getSAPISIDGate = {
            await cookieReadEntered.open()
            await releaseCookieRead.wait()
        }
        manager.waitForInitialCookieRestoreResult = .ready
        let recovery = Task { @MainActor in
            await authService.checkLoginStatus()
        }
        await cookieReadEntered.wait()
        // Quitting can save the queue while the recovered cookie read is pending.
        restoredService.saveQueueForPersistence()
        #expect(UserDefaults.standard.data(forKey: "kaset.saved.playbackSession") == savedSession)
        await releaseCookieRead.open()
        await recovery.value
        #expect(await authService.checkLoginStatusForStartup(expectedState: authService.state))
        // Authentication can publish before the root task performs startup cleanup.
        restoredService.saveQueueForPersistence()
        #expect(UserDefaults.standard.data(forKey: "kaset.saved.playbackSession") == savedSession)
        restoredService.reloadCurrentTrackForAuthDataStoreChange(usesCookieFreeDataStore: !restoresSession)
        #expect(restoredService.restoredPlaybackSessionOwnerScope == (wasGuestQueue
                ? PlayerService.playbackSessionScopeGuest : PlayerService.playbackSessionScopeAuthenticated))
        if restoresSession {
            restoredService.clearGuestPlaybackForAuthenticatedStartup()
        } else {
            restoredService.clearPlaybackForGuestStartup()
        }
        if wasGuestQueue != restoresSession {
            #expect(restoredService.queue.map(\.id) == songs.map(\.id))
            #expect(restoredService.currentTrack?.id == songs[1].id)
            #expect(UserDefaults.standard.data(forKey: "kaset.saved.playbackSession") != nil)
            if wasGuestQueue {
                // After startup, a later explicit login can own the preserved guest queue.
                authService.completeLogin(sapisid: "mock-later-session")
                restoredService.saveQueueForPersistence()
                #expect(restoredService.restoredPlaybackSessionOwnerScope == PlayerService.playbackSessionScopeAuthenticated)
            }
        } else {
            #expect(restoredService.queue.isEmpty)
            #expect(restoredService.currentTrack == nil)
            #expect(UserDefaults.standard.data(forKey: "kaset.saved.playbackSession") == nil)
        }
    }

    @Test("Legacy restored queues stay private until startup cleanup", arguments: [true, false])
    func legacyQueueOwnershipWaitsForStartupCleanup(restoresSession: Bool) async {
        let songs = TestFixtures.makeSongs(count: 2)
        await self.playerService.playQueue(songs, startingAt: 1)
        self.playerService.saveQueueForPersistence()
        self.playerService.updateRestoredPlaybackSessionOwnerScope(nil)
        self.mockClient.shouldThrowError = URLError(.notConnectedToInternet)
        defer { self.playerService.clearSavedQueue() }

        let restoredService = PlayerService()
        restoredService.setYTMusicClient(self.mockClient)
        #expect(restoredService.restoreQueueFromPersistence())
        #expect(restoredService.restoredPlaybackSessionOwnerScope == nil)
        let manager = MockWebKitManager()
        manager.waitForInitialCookieRestoreResult = .unavailable
        manager.sapisidValue = restoresSession ? "mock-personal-session" : nil
        let authService = AuthService(webKitManager: manager)
        restoredService.setAuthService(authService)
        await authService.checkLoginStatus()
        manager.waitForInitialCookieRestoreResult = .ready
        await authService.checkLoginStatus()

        #expect(authService.state.isLoggedIn == restoresSession)
        #expect(restoredService.restoredPlaybackSessionOwnerScope == nil)
        restoredService.saveQueueForPersistence()
        #expect(restoredService.restoredPlaybackSessionOwnerScope != PlayerService.playbackSessionScopeGuest)
        if restoresSession {
            restoredService.clearGuestPlaybackForAuthenticatedStartup()
            #expect(restoredService.queue.map(\.id) == songs.map(\.id))
            #expect(UserDefaults.standard.data(forKey: "kaset.saved.playbackSession") != nil)
        } else {
            restoredService.clearPlaybackForGuestStartup()
            #expect(restoredService.queue.isEmpty)
            #expect(UserDefaults.standard.data(forKey: "kaset.saved.playbackSession") == nil)
        }
    }

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
