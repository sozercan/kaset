import Foundation
import Testing
@testable import Kaset

@Suite("Deferred restoration home preload", .serialized, .tags(.service))
@MainActor
struct DeferredRestorationHomePreloadTests {
    @Test("Authenticated deferred restoration mounts Home without loading the saved video")
    func authenticatedDeferredRestorationMountsHomeWithoutLoadingSavedVideo() {
        let playerService = PlayerService()
        defer { playerService.clearRestoredPlaybackSessionState() }
        let restoredSong = TestFixtures.makeSong(id: "restored-mount-video")
        playerService.applyRestoredPlaybackSession(
            queue: [restoredSong],
            currentIndex: 0,
            progress: 42,
            duration: 180
        )

        #expect(playerService.isAwaitingWebRestoredTrack)
        #expect(playerService.isPendingRestoredLoadDeferred)
        #expect(playerService.pendingPlayVideoId == restoredSong.videoId)
        #expect(!MainWindow.shouldMountPersistentPlayer(
            isLoggedIn: false,
            pendingVideoId: playerService.pendingPlayVideoId,
            isPendingRestoredLoadDeferred: playerService.isPendingRestoredLoadDeferred,
            showVideo: playerService.showVideo
        ))
        #expect(MainWindow.shouldMountPersistentPlayer(
            isLoggedIn: true,
            pendingVideoId: playerService.pendingPlayVideoId,
            isPendingRestoredLoadDeferred: playerService.isPendingRestoredLoadDeferred,
            showVideo: playerService.showVideo
        ))
        #expect(!playerService.shouldAutoloadPendingVideo)
        #expect(!playerService.shouldAutoplayPlaybackDocument)
    }

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

    @Test("Home preload URL binds an accepted document generation")
    func homePreloadURLBindsDocumentGeneration() throws {
        let generation: UInt64 = 7
        let url = try #require(SingletonPlayerWebView.homePreloadURL(
            documentGeneration: generation
        ))

        #expect(WebPlaybackDocumentGeneration.generation(from: url) == generation)
        #expect(SingletonPlayerWebView.isExpectedHomePreloadURL(url))
        #expect(url.fragment == "\(WebPlaybackDocumentGeneration.urlQueryKey)=\(generation)")
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
