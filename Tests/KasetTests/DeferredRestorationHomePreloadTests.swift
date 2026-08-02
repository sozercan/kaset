import Testing
@testable import Kaset

@Suite("Deferred restoration home preload", .serialized, .tags(.service))
@MainActor
struct DeferredRestorationHomePreloadTests {
    @Test("Home preload remains enabled for ordinary creation but can be suppressed for a rebuild")
    func homePreloadPolicyDistinguishesOrdinaryCreationFromDeferredRebuild() {
        #expect(MusicHomePreloadPolicy.shouldPreload(
            isRunningUnitTests: false,
            isSuppressedForDeferredRestore: false,
            hasStartedHomePreload: false,
            currentVideoId: nil
        ))
        #expect(!MusicHomePreloadPolicy.shouldPreload(
            isRunningUnitTests: false,
            isSuppressedForDeferredRestore: true,
            hasStartedHomePreload: false,
            currentVideoId: nil
        ))
        #expect(!MusicHomePreloadPolicy.shouldPreload(
            isRunningUnitTests: false,
            isSuppressedForDeferredRestore: false,
            hasStartedHomePreload: false,
            currentVideoId: "active-video"
        ))
    }

    @Test("Auth data-store rebuild leaves a deferred restored video unloaded")
    func authDataStoreRebuildLeavesDeferredRestoredVideoUnloaded() {
        let singleton = SingletonPlayerWebView.shared
        singleton.tearDown()
        singleton.currentVideoId = nil
        defer {
            singleton.tearDown()
            singleton.currentVideoId = nil
        }

        let playerService = PlayerService()
        playerService.setYTMusicClient(MockYTMusicClient())
        let webKitManager = WebKitManager.makeTestInstance()
        _ = singleton.getWebView(
            webKitManager: webKitManager,
            playerService: playerService,
            usesCookieFreeDataStore: true
        )

        let restoredVideoID = "restored-video"
        singleton.currentVideoId = restoredVideoID
        let restoredSong = Song(
            id: "restored-song",
            title: "Restored Song",
            artists: [],
            duration: 180,
            videoId: restoredVideoID
        )
        playerService.applyRestoredPlaybackSession(
            queue: [restoredSong],
            currentIndex: 0,
            progress: 42,
            duration: 180
        )

        playerService.reloadCurrentTrackForAuthDataStoreChange(usesCookieFreeDataStore: false)
        _ = singleton.getWebView(
            webKitManager: webKitManager,
            playerService: playerService,
            usesCookieFreeDataStore: false
        )

        #expect(playerService.isPendingRestoredLoadDeferred)
        #expect(playerService.pendingPlayVideoId == restoredVideoID)
        #expect(singleton.currentVideoId == nil)
        #expect(singleton.isHomePreloadSuppressedForDeferredRestore)
        #expect(playerService.shouldLoadPendingVideoBeforePlayback)
    }
}
