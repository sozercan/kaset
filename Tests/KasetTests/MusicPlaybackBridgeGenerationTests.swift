import Foundation
import Testing
@testable import Kaset

@Suite("YouTube Music playback bridge generation", .tags(.service))
@MainActor
struct MusicPlaybackBridgeGenerationTests {
    @Test("Bridge acceptance requires current WebView identity and active generation")
    func bridgeAcceptanceRequiresIdentityAndGeneration() {
        let currentWebView = NSObject()
        let replacedWebView = NSObject()
        var documentGeneration = WebPlaybackDocumentGeneration()
        let activeGeneration = documentGeneration.beginNavigation()
        let didStart = documentGeneration.startNavigation(activeGeneration)
        let didCommit = documentGeneration.commitNavigation(activeGeneration)
        #expect(didStart)
        #expect(didCommit)

        #expect(SingletonPlayerWebView.acceptsBridgeMessage(
            sourceWebView: currentWebView,
            currentWebView: currentWebView,
            documentGeneration: documentGeneration,
            rawDocumentGeneration: activeGeneration
        ))
        #expect(!SingletonPlayerWebView.acceptsBridgeMessage(
            sourceWebView: replacedWebView,
            currentWebView: currentWebView,
            documentGeneration: documentGeneration,
            rawDocumentGeneration: activeGeneration
        ))
        #expect(!SingletonPlayerWebView.acceptsBridgeMessage(
            sourceWebView: currentWebView,
            currentWebView: currentWebView,
            documentGeneration: documentGeneration,
            rawDocumentGeneration: activeGeneration + 1
        ))
        #expect(!SingletonPlayerWebView.acceptsBridgeSource(
            isMainFrame: false,
            sourceScheme: "https",
            sourceHost: "music.youtube.com"
        ))
        #expect(!SingletonPlayerWebView.acceptsBridgeSource(
            isMainFrame: true,
            sourceScheme: "https",
            sourceHost: "www.youtube.com"
        ))
    }

    @Test("Pending navigation suppresses the outgoing generation until commit")
    func pendingNavigationSuppressesOutgoingGeneration() {
        let currentWebView = NSObject()
        var documentGeneration = WebPlaybackDocumentGeneration()
        let committedGeneration = documentGeneration.beginNavigation()
        let didStartCommittedGeneration = documentGeneration.startNavigation(committedGeneration)
        let didCommitCommittedGeneration = documentGeneration.commitNavigation(committedGeneration)
        #expect(didStartCommittedGeneration)
        #expect(didCommitCommittedGeneration)

        let pendingGeneration = documentGeneration.beginNavigation()
        #expect(!SingletonPlayerWebView.acceptsBridgeMessage(
            sourceWebView: currentWebView,
            currentWebView: currentWebView,
            documentGeneration: documentGeneration,
            rawDocumentGeneration: committedGeneration
        ))
        #expect(!SingletonPlayerWebView.acceptsBridgeMessage(
            sourceWebView: currentWebView,
            currentWebView: currentWebView,
            documentGeneration: documentGeneration,
            rawDocumentGeneration: pendingGeneration
        ))

        let didStartPendingGeneration = documentGeneration.startNavigation(pendingGeneration)
        #expect(didStartPendingGeneration)
        #expect(!SingletonPlayerWebView.acceptsBridgeMessage(
            sourceWebView: currentWebView,
            currentWebView: currentWebView,
            documentGeneration: documentGeneration,
            rawDocumentGeneration: pendingGeneration
        ))
        let didCommitPendingGeneration = documentGeneration.commitNavigation(pendingGeneration)
        #expect(didCommitPendingGeneration)
        #expect(SingletonPlayerWebView.acceptsBridgeMessage(
            sourceWebView: currentWebView,
            currentWebView: currentWebView,
            documentGeneration: documentGeneration,
            rawDocumentGeneration: pendingGeneration
        ))
        #expect(!SingletonPlayerWebView.acceptsBridgeMessage(
            sourceWebView: currentWebView,
            currentWebView: currentWebView,
            documentGeneration: documentGeneration,
            rawDocumentGeneration: committedGeneration
        ))
    }

    @Test("User scripts select a pending generation before the active generation")
    func userScriptsSelectPendingBeforeActiveGeneration() {
        var documentGeneration = WebPlaybackDocumentGeneration()

        #expect(SingletonPlayerWebView.userScriptDocumentGeneration(from: documentGeneration) == 0)

        let pendingGeneration = documentGeneration.beginNavigation()
        #expect(
            SingletonPlayerWebView.userScriptDocumentGeneration(from: documentGeneration)
                == pendingGeneration
        )

        let bootstrap = SingletonPlayerWebView.pageBootstrapScript(
            isRestoringPlaybackSession: false,
            targetVolume: 0.5,
            documentGeneration: SingletonPlayerWebView.userScriptDocumentGeneration(from: documentGeneration)
        )
        #expect(bootstrap.contains("window.__kasetDocumentGeneration = -1;"))

        let didStart = documentGeneration.startNavigation(pendingGeneration)
        let didCommit = documentGeneration.commitNavigation(pendingGeneration)
        #expect(didStart)
        #expect(didCommit)
        #expect(
            SingletonPlayerWebView.userScriptDocumentGeneration(from: documentGeneration)
                == documentGeneration.currentGeneration
        )
    }

    @Test("Playback URL binds its document generation to the navigation")
    func playbackURLBindsDocumentGeneration() throws {
        let url = try #require(SingletonPlayerWebView.playbackURL(
            videoId: "video",
            documentGeneration: 42
        ))

        #expect(WebPlaybackDocumentGeneration.generation(from: url) == 42)
    }

    @Test("Standard same-video requests do not advance playback occurrence")
    func standardSameVideoRequestIsDeduplicated() {
        #expect(!SingletonPlayerWebView.acceptsPlaybackRequest(
            videoId: "abc",
            currentVideoId: "abc",
            hasWebView: true,
            strategy: .standard
        ))
        #expect(SingletonPlayerWebView.acceptsPlaybackRequest(
            videoId: "abc",
            currentVideoId: "abc",
            hasWebView: true,
            strategy: .preferInPlaceWhenSameVideoId
        ))
        #expect(SingletonPlayerWebView.acceptsPlaybackRequest(
            videoId: "abc",
            currentVideoId: nil,
            hasWebView: false,
            strategy: .standard
        ))
    }

    @Test("Canceled navigation commit suppression targets only the canceled document")
    func canceledNavigationCommitSuppressionIsScoped() {
        let canceledURL = URL(string: "https://music.youtube.com/watch?v=a&kasetDocumentGeneration=1")
        let replacementURL = URL(string: "https://music.youtube.com/watch?v=b&kasetDocumentGeneration=2")

        #expect(WebPlaybackDocumentGeneration.shouldSuppressCancelledNavigationCommit(
            cancelledGeneration: 1,
            committedURL: canceledURL,
            pendingGeneration: nil,
            inFlightGeneration: 2,
            currentGeneration: 1
        ))
        #expect(!WebPlaybackDocumentGeneration.shouldSuppressCancelledNavigationCommit(
            cancelledGeneration: 1,
            committedURL: replacementURL,
            pendingGeneration: nil,
            inFlightGeneration: 2,
            currentGeneration: 1
        ))
        #expect(WebPlaybackDocumentGeneration.shouldSuppressCancelledNavigationCommit(
            cancelledGeneration: 1,
            committedURL: nil,
            pendingGeneration: nil,
            inFlightGeneration: nil,
            currentGeneration: 1
        ))
        #expect(WebPlaybackDocumentGeneration.shouldSuppressCancelledNavigationCommit(
            cancelledGeneration: 1,
            committedURL: nil,
            pendingGeneration: nil,
            inFlightGeneration: 2,
            currentGeneration: 1
        ))
        #expect(!WebPlaybackDocumentGeneration.shouldSuppressCancelledNavigationCommit(
            cancelledGeneration: 1,
            committedURL: replacementURL,
            pendingGeneration: nil,
            inFlightGeneration: nil,
            currentGeneration: 2
        ))
    }

    @Test("Music main-frame response requires expected successful watch document")
    func mainFrameResponseRequiresExpectedSuccessfulWatchDocument() throws {
        var documentGeneration = WebPlaybackDocumentGeneration()
        let generation = documentGeneration.beginNavigation()
        let didStart = documentGeneration.startNavigation(generation)
        #expect(didStart)
        let expectedURL = try #require(SingletonPlayerWebView.playbackURL(
            videoId: "video",
            documentGeneration: generation
        ))
        let success = try #require(HTTPURLResponse(
            url: expectedURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let failure = try #require(HTTPURLResponse(
            url: expectedURL,
            statusCode: 500,
            httpVersion: nil,
            headerFields: nil
        ))

        #expect(SingletonPlayerWebView.acceptsMainFrameResponse(
            success,
            expectedVideoID: "video",
            documentGeneration: documentGeneration
        ))
        #expect(!SingletonPlayerWebView.acceptsMainFrameResponse(
            failure,
            expectedVideoID: "video",
            documentGeneration: documentGeneration
        ))
        #expect(!SingletonPlayerWebView.acceptsMainFrameResponse(
            success,
            expectedVideoID: "other",
            documentGeneration: documentGeneration
        ))
    }

    @Test("Content-process recovery preserves seek and playing intent")
    func contentProcessRecoveryPreservesPlayingIntent() {
        let plan = SingletonPlayerWebView.contentProcessRecoveryPlan(
            state: .playing,
            progress: 42,
            isShowingAd: false,
            lastNonAdContentProgress: 0
        )

        #expect(plan.pendingSeek == 42)
        #expect(plan.shouldReload)
        #expect(plan.shouldAutoResume)
    }

    @Test("Content-process recovery keeps paused and ended playback from auto-resuming")
    func contentProcessRecoveryPreservesPausedIntent() {
        let pausedPlan = SingletonPlayerWebView.contentProcessRecoveryPlan(
            state: .paused,
            progress: 42,
            isShowingAd: false,
            lastNonAdContentProgress: 0
        )
        let endedPlan = SingletonPlayerWebView.contentProcessRecoveryPlan(
            state: .ended,
            progress: 100,
            isShowingAd: false,
            lastNonAdContentProgress: 0
        )

        #expect(pausedPlan.pendingSeek == 42)
        #expect(pausedPlan.shouldReload)
        #expect(!pausedPlan.shouldAutoResume)
        #expect(endedPlan.pendingSeek == nil)
        #expect(!endedPlan.shouldReload)
        #expect(!endedPlan.shouldAutoResume)
    }

    @Test("Content-process recovery does not resurrect terminal playback states")
    func contentProcessRecoverySkipsTerminalStates() {
        for state in [PlayerService.PlaybackState.idle, .ended, .error("test")] {
            let plan = SingletonPlayerWebView.contentProcessRecoveryPlan(
                state: state,
                progress: 42,
                isShowingAd: false,
                lastNonAdContentProgress: 42
            )

            #expect(!plan.shouldReload)
            #expect(plan.pendingSeek == nil)
            #expect(!plan.shouldAutoResume)
        }
    }

    @Test("Deferred restored load remains gated after WebContent termination")
    func deferredRestoredLoadRemainsExplicitResumeOnly() {
        let plan = SingletonPlayerWebView.contentProcessRecoveryPlan(
            state: .paused,
            progress: 42,
            isShowingAd: false,
            lastNonAdContentProgress: 42,
            isPendingRestoredLoadDeferred: true
        )

        #expect(!plan.shouldReload)
        #expect(plan.pendingSeek == nil)
        #expect(!plan.shouldAutoResume)
    }

    @Test("Fresh loading recovery never seeks to a stale prior-track clock")
    func freshLoadingRecoveryDoesNotReuseProgress() {
        let plan = SingletonPlayerWebView.contentProcessRecoveryPlan(
            state: .loading,
            progress: 99,
            isShowingAd: false,
            lastNonAdContentProgress: 0
        )

        #expect(plan.shouldReload)
        #expect(plan.shouldAutoResume)
        #expect(plan.pendingSeek == nil)
    }

    @Test("Content-process recovery never uses ad elapsed time as the music seek")
    func contentProcessRecoveryUsesLastContentProgressDuringAds() {
        let knownContentPlan = SingletonPlayerWebView.contentProcessRecoveryPlan(
            state: .playing,
            progress: 12,
            isShowingAd: true,
            lastNonAdContentProgress: 42
        )
        let prerollPlan = SingletonPlayerWebView.contentProcessRecoveryPlan(
            state: .playing,
            progress: 12,
            isShowingAd: true,
            lastNonAdContentProgress: 0
        )

        #expect(knownContentPlan.pendingSeek == 42)
        #expect(prerollPlan.pendingSeek == nil)
    }

    @Test("Non-ad recovery clocks are scoped to their content video")
    func nonAdRecoveryClockIsVideoScoped() {
        let playerService = PlayerService()
        playerService.updateAdPlaybackState(
            isShowingAd: false,
            observedProgress: 42,
            observedVideoId: "video-a",
            isAuthoritativeContent: true
        )

        #expect(playerService.lastNonAdContentProgress(for: "video-a") == 42)
        #expect(playerService.lastNonAdContentProgress(for: "video-b") == 0)

        playerService.updateAdPlaybackState(
            isShowingAd: true,
            observedProgress: 3,
            observedVideoId: "video-b",
            isAuthoritativeContent: false
        )
        #expect(playerService.lastNonAdContentProgress(for: "video-b") == 0)
    }

    @Test("Ready ad transport updates do not overwrite the content clock")
    func adTransportPreservesContentClock() {
        let playerService = PlayerService()
        playerService.progress = 42
        playerService.duration = 180
        playerService.state = .loading
        playerService.shouldResumeAfterInterruption = true

        playerService.updatePlaybackTransportState(isPlaying: true)

        #expect(playerService.state == .playing)
        #expect(playerService.progress == 42)
        #expect(playerService.duration == 180)

        playerService.state = .loading
        playerService.updatePlaybackTransportState(isPlaying: false)
        #expect(playerService.state == .paused)
        #expect(playerService.shouldResumeAfterInterruption)

        playerService.state = .ended
        playerService.updatePlaybackTransportState(isPlaying: true)
        #expect(playerService.state == .ended)
    }

    @Test("Ready preroll ads resume only for auto-resuming restoration")
    func readyAdRestorationIntent() {
        let playerService = PlayerService()
        playerService.pendingRestoredSeek = 42
        playerService.beginRestoredPlaybackLoad(autoResumeAfterSeek: true)
        #expect(playerService.shouldResumeReadyAdDuringRestoration)

        playerService.shouldAutoResumeAfterRestoredLoad = false
        #expect(!playerService.shouldResumeReadyAdDuringRestoration)
        #expect(playerService.pendingRestoredSeek == 42)
    }

    @Test("Only ready non-ad media can mutate the canonical content clock")
    func authoritativePlaybackSampleRequiresReadyContentMedia() {
        #expect(SingletonPlayerWebView.isAuthoritativePlaybackSample(
            hasReadyMedia: true,
            isShowingAd: false
        ))
        #expect(!SingletonPlayerWebView.isAuthoritativePlaybackSample(
            hasReadyMedia: false,
            isShowingAd: false
        ))
        #expect(!SingletonPlayerWebView.isAuthoritativePlaybackSample(
            hasReadyMedia: true,
            isShowingAd: true
        ))
    }

    @Test("Navigation failure defers restoration without losing its seek")
    func navigationFailurePreservesRestoredSeek() async {
        let playerService = PlayerService()
        playerService.pendingPlayVideoId = "retry-video"
        playerService.pendingRestoredSeek = 42
        playerService.beginRestoredPlaybackLoad(autoResumeAfterSeek: true)

        playerService.deferRestoredPlaybackAfterNavigationFailure()

        #expect(playerService.pendingRestoredSeek == 42)
        #expect(playerService.isPendingRestoredLoadDeferred)
        #expect(playerService.shouldForcePendingRestoredLoad)
        #expect(!playerService.isRestoringPlaybackSession)
        #expect(playerService.state == .paused)
        #expect(playerService.pendingRestoredSeekForWebRecovery(videoId: "retry-video") == 42)
        #expect(playerService.pendingRestoredSeekForWebRecovery(videoId: "other-video") == nil)

        playerService.currentWebPlaybackVideoId = { nil }
        await playerService.resume()

        #expect(playerService.pendingRestoredSeek == 42)
        #expect(playerService.isRestoringPlaybackSession)
        #expect(playerService.state == .loading)
    }

    @Test("Committed navigation failure captures the active non-ad content clock")
    func committedNavigationFailureCapturesActiveProgress() {
        let playerService = PlayerService()
        playerService.pendingPlayVideoId = "retry-video"
        playerService.state = .playing
        playerService.progress = 42

        playerService.deferRestoredPlaybackAfterNavigationFailure()

        #expect(playerService.pendingRestoredSeek == 42)
        #expect(playerService.isPendingRestoredLoadDeferred)
        #expect(playerService.shouldForcePendingRestoredLoad)
    }

    @Test("Navigation failure ignores an ad fallback clock owned by another track")
    func navigationFailureScopesAdFallbackClock() {
        let playerService = PlayerService()
        playerService.pendingPlayVideoId = "video-b"
        playerService.state = .playing
        playerService.progress = 3
        playerService.isShowingAd = true
        playerService.lastNonAdContentProgress = 42
        playerService.lastNonAdContentVideoId = "video-a"

        playerService.deferRestoredPlaybackAfterNavigationFailure()

        #expect(playerService.pendingRestoredSeek == nil)
    }

    @Test("Play/pause resumes deferred restoration without clearing its seek")
    func playPausePreservesDeferredRestoredSeek() async {
        let playerService = PlayerService()
        playerService.pendingPlayVideoId = "retry-video"
        playerService.pendingRestoredSeek = 42
        playerService.beginRestoredPlaybackLoad(autoResumeAfterSeek: true)
        playerService.deferRestoredPlaybackAfterNavigationFailure()
        playerService.currentWebPlaybackVideoId = { nil }

        await playerService.playPause()

        #expect(playerService.pendingRestoredSeek == 42)
        #expect(playerService.isRestoringPlaybackSession)
        #expect(playerService.state == .loading)
    }

    @Test("Play/pause cancels an active restored auto-resume")
    func playPauseCancelsActiveRestoredAutoResume() async {
        let playerService = PlayerService()
        playerService.pendingPlayVideoId = "restore-video"
        playerService.pendingRestoredSeek = 42
        playerService.beginRestoredPlaybackLoad(autoResumeAfterSeek: true)

        await playerService.playPause()

        #expect(playerService.state == .paused)
        #expect(playerService.isPendingRestoredLoadDeferred)
        #expect(!playerService.shouldAutoResumeAfterRestoredLoad)
        #expect(playerService.pendingRestoredSeek == 42)
    }

    @Test("Repeated resume during restoration preserves the seek")
    func repeatedResumeDuringRestorationPreservesSeek() async {
        let playerService = PlayerService()
        playerService.pendingPlayVideoId = "restore-video"
        playerService.pendingRestoredSeek = 42
        playerService.beginRestoredPlaybackLoad(autoResumeAfterSeek: true)
        playerService.currentWebPlaybackVideoId = { "restore-video" }

        await playerService.resume()

        #expect(playerService.pendingRestoredSeek == 42)
        #expect(playerService.isRestoringPlaybackSession)
        #expect(playerService.shouldAutoResumeAfterRestoredLoad)
    }

    @Test("Repeated process recovery preserves paused restored intent")
    func repeatedRecoveryPreservesPausedIntent() {
        let playerService = PlayerService()
        playerService.pendingPlayVideoId = "restore-video"
        playerService.pendingRestoredSeek = 42
        playerService.beginRestoredPlaybackLoad(autoResumeAfterSeek: false)
        playerService.state = .loading

        let plan = SingletonPlayerWebView.contentProcessRecoveryPlan(
            state: playerService.state,
            progress: playerService.progress,
            isShowingAd: false,
            lastNonAdContentProgress: 0
        )
        let shouldAutoResume = playerService.isRestoringPlaybackSession
            ? playerService.shouldAutoResumeAfterRestoredLoad
            : plan.shouldAutoResume

        #expect(!shouldAutoResume)
    }

    @Test("Music document autoplay follows native intent outside restoration")
    func playbackDocumentAutoplayFollowsNativeIntent() {
        let playerService = PlayerService()

        playerService.state = .loading
        playerService.shouldResumeAfterInterruption = true
        #expect(playerService.shouldAutoplayPlaybackDocument)

        playerService.pendingRestoredSeek = 42
        playerService.beginRestoredPlaybackLoad(autoResumeAfterSeek: true)
        #expect(!playerService.shouldAutoplayPlaybackDocument)

        playerService.clearRestoredPlaybackSessionState()
        playerService.state = .paused
        playerService.shouldResumeAfterInterruption = false
        #expect(!playerService.shouldAutoplayPlaybackDocument)
    }

    @Test("A new play intent clears an in-progress stop fence")
    func newPlayClearsStopFence() async {
        let playerService = PlayerService()
        playerService.isStoppingPlayback = true

        await playerService.play(videoId: "new-video")

        #expect(!playerService.isStoppingPlayback)
    }

    @Test("Clearing WebView identity leaves the pending music video retryable on resume")
    func clearedWebViewIdentityRetriesPendingVideo() async {
        let playerService = PlayerService()
        playerService.pendingPlayVideoId = "retry-video"
        playerService.state = .paused
        playerService.currentWebPlaybackVideoId = { nil }

        await playerService.resume()

        #expect(playerService.pendingPlayVideoId == "retry-video")
        #expect(playerService.state == .loading)
        #expect(playerService.shouldLoadPendingVideoBeforePlayback)
    }

    @Test("Every singletonPlayer observer payload carries document generation")
    func everyObserverPayloadCarriesDocumentGeneration() {
        let script = SingletonPlayerWebView.observerScript
        let payloads = self.objectPayloads(
            in: script,
            marker: "bridge.postMessage({",
            terminator: "});"
        )

        #expect(self.occurrenceCount(of: "postMessage(", in: script) == 6)
        #expect(payloads.count == 5)
        for payload in payloads {
            #expect(payload.contains("documentGeneration: window.__kasetDocumentGeneration"))
            if payload.contains("type: 'STATE_UPDATE'") {
                #expect(payload.contains(
                    "nativePlaybackGeneration: window.__kasetNativePlaybackGeneration || 0"
                ))
            }
        }

        for messageType in ["STATE_UPDATE", "LYRICS_LINE", "AIRPLAY_STATUS"] {
            #expect(payloads.contains { $0.contains("type: '\(messageType)'") })
        }
        #expect(script.contains("function trackEndedPayload(video)"))
        #expect(script.contains("type: 'TRACK_ENDED'"))
        #expect(script.contains("isAd: isAdShowing()"))
        #expect(script.contains("bridge.postMessage(payload)"))
        let lyricsPayload = payloads.first { $0.contains("type: 'LYRICS_LINE'") }
        #expect(lyricsPayload?.contains("isAd: isAdShowing()") == true)
        let statePayload = payloads.first { $0.contains("type: 'STATE_UPDATE'") }
        #expect(statePayload?.contains("isAd: isAd") == true)
        #expect(statePayload?.contains("hasReadyMedia: hasReadyMedia") == true)
        #expect(script.contains("video.__kasetBoundVideoId = videoId"))
        #expect(!script.contains("const videoId = currentVideoId() || lastVideoId"))
        #expect(script.contains("video.__kasetBoundVideoId || lastVideoId || currentVideoId()"))
    }

    @Test("Every media-control payload carries document generation")
    func everyMediaControlPayloadCarriesDocumentGeneration() {
        let script = SingletonPlayerWebView.mediaControlOverrideScript
        let payloads = self.objectPayloads(
            in: script,
            marker: ".postMessage({",
            terminator: "});"
        )

        #expect(self.occurrenceCount(of: "postMessage(", in: script) == 2)
        #expect(payloads.count == 2)
        for payload in payloads {
            #expect(payload.contains("documentGeneration: window.__kasetDocumentGeneration"))
        }
        #expect(payloads.contains { $0.contains("type: 'REMOTE_NEXT'") })
        #expect(payloads.contains { $0.contains("type: 'REMOTE_PREVIOUS'") })
        #expect(script.contains("function __kasetEventTimestampMilliseconds()"))
        #expect(script.contains("Number(performance.timeOrigin) + Number(performance.now())"))
        for payload in payloads where payload.contains("type: 'REMOTE_") {
            #expect(payload.contains(
                "commandIssuedAtMilliseconds: __kasetEventTimestampMilliseconds()"
            ))
        }
    }

    @Test("Playback audio-quality stats payload carries document generation")
    func playbackAudioQualityStatsCarriesDocumentGeneration() {
        let script = SingletonPlayerWebView.playbackAudioQualityOverrideScript
        let snapshots = self.objectPayloads(
            in: script,
            marker: "var snapshot = {",
            terminator: "};"
        )

        #expect(self.occurrenceCount(of: "postMessage(", in: script) == 1)
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.contains("type: 'PLAYBACK_AUDIO_QUALITY_STATS'") == true)
        #expect(
            snapshots.first?.contains("documentGeneration: window.__kasetDocumentGeneration") == true
        )
        #expect(script.contains("handler.postMessage(snapshot);"))
    }

    @Test("Ended reporting rejects replaced media elements and duplicate end events")
    func endedReportingRejectsStaleOrDuplicateMediaElements() {
        let script = SingletonPlayerWebView.observerScript

        #expect(script.contains("video !== document.querySelector('video')"))
        #expect(script.contains("video.__kasetEndedReported"))
        #expect(script.contains("video.__kasetEndedReported = false"))
        #expect(script.contains("sendTrackEnded(endedPayload)"))
    }

    @Test("Navigation failure pause clears autoplay retry intent")
    func navigationFailurePauseClearsAutoplayRetryIntent() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/KasetTests/MusicPlaybackBridgeGenerationTests.swift",
            with: "Sources/Kaset/Views/MiniPlayerWebView.swift"
        ))

        #expect(source.contains("window.__kasetAutoplayPending = false;"))
        #expect(source.contains("window.__kasetAutoplayAttempts = 0;"))
        #expect(source.contains("window.__kasetAutoplayRetryScheduled = false;"))
    }

    @Test("Authoritative bridge clocks retain the observed video identity")
    func authoritativeBridgeClockUsesObservedVideoIdentity() throws {
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/KasetTests/MusicPlaybackBridgeGenerationTests.swift",
                with: "Sources/Kaset/Views/MiniPlayerWebView+Coordinator.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("duration: Double(duration),\n                    observedVideoId: observedVideoId"))
    }

    private func objectPayloads(in script: String, marker: String, terminator: String) -> [String] {
        script.components(separatedBy: marker).dropFirst().compactMap { suffix in
            suffix.components(separatedBy: terminator).first
        }
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
