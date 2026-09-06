// swiftlint:disable file_length
import Foundation
import Testing
@testable import Kaset

// MARK: - MusicPlaybackBridgeGenerationTests

@Suite("YouTube Music playback bridge generation", .tags(.service))
@MainActor
struct MusicPlaybackBridgeGenerationTests {
    @Test("Current-document media keys pass the document ID gate during navigation", arguments: ["REMOTE_NEXT", "REMOTE_PREVIOUS"])
    func currentDocumentMediaKeysPassDocumentIDGateDuringNavigation(messageType: String) {
        var generation = WebPlaybackDocumentGeneration()
        let committed = generation.beginNavigation()
        let startedCommitted = generation.startNavigation(committed)
        let committedInitial = generation.commitNavigation(committed)
        #expect(startedCommitted)
        #expect(committedInitial)
        let pending = generation.beginNavigation()

        #expect(SingletonPlayerWebView.acceptsBridgeDocumentID(
            1,
            expectedDocumentID: 2,
            messageType: messageType
        ))
        #expect(generation.acceptsUserCommand(
            generation: committed,
            issuedAtMilliseconds: 101,
            navigationStartedAtMilliseconds: 100
        ))
        let startedPending = generation.startNavigation(pending)
        #expect(startedPending)
        #expect(!generation.acceptsUserCommand(
            generation: committed,
            issuedAtMilliseconds: 99,
            navigationStartedAtMilliseconds: 100
        ))
        #expect(!generation.acceptsUserCommand(
            generation: pending,
            issuedAtMilliseconds: 101,
            navigationStartedAtMilliseconds: 100
        ))
        let committedPending = generation.commitNavigation(pending)
        #expect(committedPending)
        #expect(!generation.acceptsUserCommand(
            generation: committed,
            issuedAtMilliseconds: 101,
            navigationStartedAtMilliseconds: nil
        ))
    }

    @Test("Playback observations retain the document ID gate", arguments: ["STATE_UPDATE", "TRACK_ENDED", "QUEUE_INJECTION_RESULT"])
    func playbackObservationsRetainDocumentIDGate(messageType: String) {
        #expect(!SingletonPlayerWebView.acceptsBridgeDocumentID(
            1,
            expectedDocumentID: 2,
            messageType: messageType
        ))
        #expect(SingletonPlayerWebView.acceptsBridgeDocumentID(
            2,
            expectedDocumentID: 2,
            messageType: messageType
        ))
    }

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

    @Test("Superseded pending-handoff content recovery retries under the current owner")
    func supersededPendingHandoffContentRecoveryRetries() throws {
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/KasetTests/MusicPlaybackBridgeGenerationTests.swift",
                with: "Sources/Kaset/Views/MiniPlayerWebView.swift"
            ),
            encoding: .utf8
        )
        let recoveryCall = try #require(source.range(
            of: ".recoverPendingNativeQueueAdvanceAfterContentProcessTermination(intent: intent)"
        ))
        let ownershipRetry = try #require(source.range(
            of: "guard !handled, webView === self.webView else { return }"
        ))
        let recursiveRecovery = try #require(source.range(
            of: "self.recoverFromContentProcessTermination(webView: webView)",
            range: ownershipRetry.lowerBound ..< source.endIndex
        ))

        #expect(recoveryCall.lowerBound < ownershipRetry.lowerBound)
        #expect(ownershipRetry.lowerBound < recursiveRecovery.lowerBound)
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

    @Test("A recovery clock without media identity does not inherit metadata identity")
    func recoveryClockWithoutMediaIdentityDoesNotInheritMetadataIdentity() {
        let playerService = PlayerService()
        playerService.currentTrack = TestFixtures.makeSong(id: "metadata-video")
        playerService.updateAdPlaybackState(
            isShowingAd: false,
            observedProgress: 42,
            observedVideoId: nil,
            isAuthoritativeContent: true
        )

        #expect(playerService.lastNonAdContentProgress(for: "metadata-video") == 0)
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

    @Test("Authoritative bridge clocks use physical media identity")
    func authoritativeBridgeClockUsesPhysicalMediaIdentity() throws {
        #expect(SingletonPlayerWebView.Coordinator.playbackVideoId(from: [
            "videoId": "leading-metadata",
            "mediaVideoId": "physical-media",
        ]) == "physical-media")
        #expect(SingletonPlayerWebView.Coordinator.playbackVideoId(from: [
            "videoId": "leading-metadata",
            "mediaVideoId": "",
        ]) == nil)
        #expect(SingletonPlayerWebView.Coordinator.playbackVideoId(from: [
            "videoId": "terminal-media",
        ]) == "terminal-media")

        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/KasetTests/MusicPlaybackBridgeGenerationTests.swift",
                with: "Sources/Kaset/Views/MiniPlayerWebView+Coordinator.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("let playbackVideoId = Self.playbackVideoId(from: body)"))
        #expect(source.contains("duration: Double(duration)"))
        #expect(source.contains("observedVideoId: playbackVideoId"))
        #expect(source.contains("videoId: Self.playbackVideoId(from: body)"))
        #expect(source.contains("videoId: playbackVideoId"))
    }
}

extension MusicPlaybackBridgeGenerationTests {
    @Test("Router navigation confirms only after an accepted state observation")
    func routerNavigationConfirmationFollowsBridgeValidation() throws {
        let coordinatorSource = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/KasetTests/MusicPlaybackBridgeGenerationTests.swift",
                with: "Sources/Kaset/Views/MiniPlayerWebView+Coordinator.swift"
            ),
            encoding: .utf8
        )
        let multiplexerSource = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/KasetTests/MusicPlaybackBridgeGenerationTests.swift",
                with: "Sources/Kaset/Views/MiniPlayerWebView.swift"
            ),
            encoding: .utf8
        )

        let confirmation = try #require(coordinatorSource.range(
            of: "confirmRouterNavigationIfNeeded(videoId: playbackVideoId)"
        ))
        let acceptedStateGuard = try #require(coordinatorSource.range(
            of: "guard shouldApplyPlaybackState, mediaMatches, shouldAcceptMediaState else { return }"
        ))
        #expect(acceptedStateGuard.lowerBound < confirmation.lowerBound)
        #expect(!multiplexerSource.contains(
            "singleton.confirmRouterNavigationIfNeeded(videoId: mediaVideoID)"
        ))
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

// MARK: - PlaybackBridgeEventQueueTests

@Suite("Playback bridge event queue", .tags(.service))
@MainActor
struct PlaybackBridgeEventQueueTests {
    private final class LifetimeProbe {}

    private final class WeakLifetimeProbe {
        weak var value: LifetimeProbe?

        init(_ value: LifetimeProbe?) {
            self.value = value
        }
    }

    @Test("A new document generation cancels the prior playback bridge backlog")
    func newDocumentGenerationCancelsPlaybackBridgeBacklog() async {
        let eventQueue = PlaybackBridgeEventQueue()
        let activeEventStarted = AsyncGate()
        let releaseActiveEvent = AsyncGate()
        let activeEventFinished = AsyncGate()
        var handledEvents: [String] = []
        var queuedEventProbe: LifetimeProbe? = LifetimeProbe()
        let retainedQueuedEventProbe = WeakLifetimeProbe(queuedEventProbe)

        eventQueue.enqueue(documentGeneration: 1) {
            await activeEventStarted.open()
            await releaseActiveEvent.wait()
            if !Task.isCancelled {
                handledEvents.append("old-active")
            }
            await activeEventFinished.open()
        }
        await activeEventStarted.wait()
        eventQueue.enqueue(documentGeneration: 1) { [queuedEventProbe] in
            _ = queuedEventProbe
            handledEvents.append("old-backlog")
        }
        queuedEventProbe = nil
        #expect(retainedQueuedEventProbe.value != nil)
        eventQueue.enqueue(documentGeneration: 2) {
            handledEvents.append("new-document")
        }

        await eventQueue.waitUntilIdle()
        #expect(retainedQueuedEventProbe.value == nil)
        await releaseActiveEvent.open()
        await activeEventFinished.wait()

        #expect(handledEvents == ["new-document"])
    }

    @Test("Bridge integer decoding rejects values outside the platform range")
    func bridgeIntegerDecodingRejectsOversizedValues() {
        let oversizedGeneration = NSNumber(value: UInt64(Int.max) + 1)

        #expect(SingletonPlayerWebView.playbackBridgeInt(from: NSNumber(value: 42)) == 42)
        #expect(SingletonPlayerWebView.playbackBridgeInt(from: oversizedGeneration) == nil)
    }
}

// MARK: - WebPlaybackTransitionFallbackPolicyTests

@Suite("Web playback transition fallback policy", .tags(.service))
struct WebPlaybackTransitionFallbackPolicyTests {
    @Test("Router fallback watchdog starts before command evaluation")
    func routerFallbackWatchdogStartsBeforeCommandEvaluation() throws {
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/KasetTests/MusicPlaybackBridgeGenerationTests.swift",
                with: "Sources/Kaset/Views/MiniPlayerWebView.swift"
            ),
            encoding: .utf8
        )
        let pendingInstallation = try #require(source.range(
            of: "self.pendingRouterNavigation = PendingRouterNavigation("
        ))
        let fallbackScheduling = try #require(source.range(
            of: "self.scheduleRouterNavigationFallback("
        ))
        let routerEvaluation = try #require(source.range(
            of: "webView.evaluateJavaScript(routerScript)"
        ))

        #expect(pendingInstallation.lowerBound < fallbackScheduling.lowerBound)
        #expect(fallbackScheduling.lowerBound < routerEvaluation.lowerBound)
        #expect(source.components(
            separatedBy: "self.pendingRouterNavigation = PendingRouterNavigation("
        ).count - 1 == 1)
    }

    @Test("Ordered content clears the ad boundary before pending-source rejection")
    @MainActor
    func orderedContentClearsAdBeforePendingSourceRejection() throws {
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/KasetTests/MusicPlaybackBridgeGenerationTests.swift",
                with: "Sources/Kaset/Views/MiniPlayerWebView+Coordinator.swift"
            ),
            encoding: .utf8
        )
        let clearBoundary = try #require(source.range(of: "self.playerService.clearAdPlaybackBoundary()"))
        let pendingReconciliation = try #require(source.range(
            of: ".reconcilePendingNativeQueueAdvanceObservation("
        ))

        #expect(clearBoundary.lowerBound < pendingReconciliation.lowerBound)

        let playerService = PlayerService()
        playerService.lastNonAdContentProgress = 42
        playerService.lastNonAdContentVideoId = "content"
        playerService.isShowingAd = true
        playerService.clearAdPlaybackBoundary()
        #expect(!playerService.isShowingAd)
        #expect(playerService.lastNonAdContentProgress == 42)
        #expect(playerService.lastNonAdContentVideoId == "content")
    }

    @Test("Advertisement state requires a newer occurrence for the pending source")
    func advertisementStateRequiresNewOccurrenceForPendingSource() {
        #expect(WebPlaybackIdentityTransition.shouldAcceptAdvertisementState(
            hasReadyMedia: true,
            isShowingAd: true,
            observedVideoId: "source",
            pendingSourceVideoId: "source",
            order: WebPlaybackIdentityTransition.ObservationOrder(
                observerEpoch: 10,
                lastAcceptedObserverEpoch: 10,
                mediaGeneration: 2,
                lastAcceptedMediaGeneration: 1
            )
        ))
        #expect(!WebPlaybackIdentityTransition.shouldAcceptAdvertisementState(
            hasReadyMedia: true,
            isShowingAd: true,
            observedVideoId: "source",
            pendingSourceVideoId: "source",
            order: WebPlaybackIdentityTransition.ObservationOrder(
                observerEpoch: 10,
                lastAcceptedObserverEpoch: 10,
                mediaGeneration: 1,
                lastAcceptedMediaGeneration: 1
            )
        ))
        #expect(WebPlaybackIdentityTransition.shouldAcceptAdvertisementState(
            hasReadyMedia: true,
            isShowingAd: true,
            observedVideoId: "source",
            pendingSourceVideoId: "source",
            order: WebPlaybackIdentityTransition.ObservationOrder(
                observerEpoch: 11,
                lastAcceptedObserverEpoch: 10,
                mediaGeneration: 0,
                lastAcceptedMediaGeneration: 4
            )
        ))
        #expect(!WebPlaybackIdentityTransition.shouldAcceptAdvertisementState(
            hasReadyMedia: true,
            isShowingAd: true,
            observedVideoId: "source",
            pendingSourceVideoId: "source",
            order: WebPlaybackIdentityTransition.ObservationOrder(
                observerEpoch: 10,
                lastAcceptedObserverEpoch: nil,
                mediaGeneration: 1,
                lastAcceptedMediaGeneration: nil
            )
        ))
        #expect(WebPlaybackIdentityTransition.shouldAcceptAdvertisementState(
            hasReadyMedia: true,
            isShowingAd: true,
            observedVideoId: "target",
            pendingSourceVideoId: "source",
            order: WebPlaybackIdentityTransition.ObservationOrder(
                observerEpoch: 10,
                lastAcceptedObserverEpoch: 10,
                mediaGeneration: 2,
                lastAcceptedMediaGeneration: 1
            )
        ))
        #expect(!WebPlaybackIdentityTransition.shouldAcceptAdvertisementState(
            hasReadyMedia: true,
            isShowingAd: true,
            observedVideoId: "target",
            pendingSourceVideoId: "source",
            order: WebPlaybackIdentityTransition.ObservationOrder(
                observerEpoch: 9,
                lastAcceptedObserverEpoch: 10,
                mediaGeneration: 3,
                lastAcceptedMediaGeneration: 2
            )
        ))
    }

    @Test("Identity deadline payload requires strict identityless provenance")
    func identityDeadlinePayloadValidation() {
        func isValid(
            disposition: String? = "deadlineFallback",
            uncertain: Bool? = true,
            videoId: String? = "",
            mediaVideoId: String? = "",
            observerEpoch: Double? = 10,
            timestamp: Double? = 100,
            documentGeneration: UInt64? = 7,
            nativeGeneration: UInt64? = 4,
            mediaGeneration: UInt64? = 2,
            isAd: Bool? = false
        ) -> Bool {
            WebPlaybackIdentityTransition.isValidTrackEndedIdentityDeadlinePayload(
                .init(
                    identityDisposition: disposition,
                    mediaIdentityUncertain: uncertain,
                    videoId: videoId,
                    mediaVideoId: mediaVideoId,
                    observerEpoch: observerEpoch,
                    eventIssuedAtMilliseconds: timestamp,
                    documentGeneration: documentGeneration,
                    nativePlaybackGeneration: nativeGeneration,
                    mediaGeneration: mediaGeneration,
                    isAd: isAd
                )
            )
        }

        #expect(isValid())
        #expect(!isValid(disposition: "resolved"))
        #expect(!isValid(uncertain: false))
        #expect(!isValid(videoId: "video"))
        #expect(!isValid(mediaVideoId: nil))
        #expect(!isValid(mediaVideoId: "video"))
        #expect(!isValid(observerEpoch: .infinity))
        #expect(!isValid(timestamp: .nan))
        #expect(!isValid(documentGeneration: nil))
        #expect(!isValid(nativeGeneration: nil))
        #expect(!isValid(mediaGeneration: 0))
        #expect(!isValid(isAd: true))
        #expect(!isValid(isAd: nil))
    }

    @Test("Paused same-video queue navigation forces a pause-preserving load")
    func pausedSameVideoQueueNavigationForcesFullLoad() {
        #expect(SingletonPlayerWebView.queueNavigationStrategy(
            currentVideoId: "video",
            targetVideoId: "video",
            startsPaused: true
        ) == .forceFullPageWhenSameVideoId)
        #expect(SingletonPlayerWebView.queueNavigationStrategy(
            currentVideoId: "video",
            targetVideoId: "video",
            startsPaused: false
        ) == .preferInPlaceWhenSameVideoId)
        #expect(SingletonPlayerWebView.queueNavigationStrategy(
            currentVideoId: "video",
            targetVideoId: "video",
            startsPaused: false,
            allowsInPlaceRestart: false
        ) == .forceFullPageWhenSameVideoId)
        #expect(SingletonPlayerWebView.queueNavigationStrategy(
            currentVideoId: "source",
            targetVideoId: "target",
            startsPaused: true
        ) == .standard)
    }

    @Test("Advertisement grace is bounded after the normal fallback delay")
    func advertisementGraceIsBoundedAfterNormalFallbackDelay() {
        let now = ContinuousClock.now
        let deadline = SingletonPlayerWebView.transitionFallbackDeadline(
            now: now,
            initialFallbackDelay: .seconds(3)
        )

        #expect(deadline == now.advanced(by: .seconds(18)))
        #expect(SingletonPlayerWebView.shouldDeferTransitionFallback(
            isShowingAd: true,
            now: now,
            deadline: deadline
        ))
        #expect(!SingletonPlayerWebView.shouldDeferTransitionFallback(
            isShowingAd: false,
            now: now,
            deadline: deadline
        ))
        let nearDeadline = deadline.advanced(by: .milliseconds(-250))
        #expect(SingletonPlayerWebView.transitionFallbackRetryDelay(
            isShowingAd: true,
            now: nearDeadline,
            deadline: deadline
        ) == .milliseconds(250))
        #expect(!SingletonPlayerWebView.shouldDeferTransitionFallback(
            isShowingAd: true,
            now: deadline,
            deadline: deadline
        ))
    }

    @Test("Advancing ad media can finish beyond the original eighteen-second deadline")
    @MainActor
    func advancingAdvertisementRefreshesWatchdog() {
        let player = PlayerService()
        let startedAt = ContinuousClock.now
        let deadline = SingletonPlayerWebView.transitionFallbackDeadline(
            now: startedAt,
            initialFallbackDelay: .seconds(3)
        )

        for second in 0 ... 30 {
            let now = startedAt.advanced(by: .seconds(second))
            player.updateAdPlaybackState(
                isShowingAd: true,
                observedProgress: Double(second),
                observedVideoId: "content-video",
                isAuthoritativeContent: false,
                now: now
            )
            #expect(SingletonPlayerWebView.transitionFallbackRetryDelay(
                isShowingAd: player.isShowingAd,
                now: now,
                deadline: deadline,
                lastAdvertisementProgressAt: player.lastAdPlaybackProgressAt
            ) != nil)
        }

        player.clearAdPlaybackBoundary()
        #expect(player.lastAdPlaybackProgressAt == nil)
        #expect(SingletonPlayerWebView.transitionFallbackRetryDelay(
            isShowingAd: player.isShowingAd,
            now: startedAt.advanced(by: .seconds(31)),
            deadline: deadline,
            lastAdvertisementProgressAt: player.lastAdPlaybackProgressAt
        ) == nil)
    }

    @Test("Repeated or invalid ad clocks cannot keep a stalled transition alive")
    @MainActor
    func stalledAdvertisementStillExpires() {
        let player = PlayerService()
        let startedAt = ContinuousClock.now
        for second in 0 ... 45 {
            player.updateAdPlaybackState(
                isShowingAd: true,
                observedProgress: Double(min(second, 30)),
                observedVideoId: "content-video",
                isAuthoritativeContent: false,
                now: startedAt.advanced(by: .seconds(second))
            )
        }
        for invalidProgress in [Double.nan, Double.infinity, -1] {
            player.updateAdPlaybackState(
                isShowingAd: true,
                observedProgress: invalidProgress,
                observedVideoId: "content-video",
                isAuthoritativeContent: false,
                now: startedAt.advanced(by: .seconds(45))
            )
        }

        #expect(player.lastAdPlaybackProgressAt == startedAt.advanced(by: .seconds(30)))
        #expect(SingletonPlayerWebView.transitionFallbackRetryDelay(
            isShowingAd: true,
            now: startedAt.advanced(by: .seconds(45)),
            deadline: startedAt.advanced(by: .seconds(18)),
            lastAdvertisementProgressAt: player.lastAdPlaybackProgressAt
        ) == nil)
        player.resetAdPlaybackState()
        #expect(player.lastAdPlaybackProgress == nil)
        #expect(player.lastAdPlaybackProgressAt == nil)
    }
}
