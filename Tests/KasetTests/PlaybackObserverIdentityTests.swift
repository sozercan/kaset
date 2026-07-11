import JavaScriptCore
import Testing
import WebKit
@testable import Kaset

@Suite(.tags(.service))
@MainActor
struct PlaybackObserverIdentityTests {
    @Test("Observer reports media-bound identity and generation with playback state")
    func observerReportsMediaIdentity() {
        let script = SingletonPlayerWebView.observerScript

        #expect(script.contains("bindMediaIdentity(video, true, false)"))
        #expect(script.contains("mediaVideoId: mediaVideoId"))
        #expect(script.contains("mediaGeneration: mediaGeneration"))
        #expect(script.contains("observerEpoch: observerEpoch"))
        #expect(script.contains("window.__kasetAdvanceMediaGeneration"))
        #expect(script.contains("const mediaTimeReset = mediaTime + 2 < lastMediaCurrentTime"))
        #expect(script.contains("if (video.readyState >= 1)"))
        #expect(script.contains("mediaIdentityTransitionFromVideoId"))
        #expect(script.contains("confirmMediaIdentityOnPlaying"))
        #expect(script.contains("identityCorrectionEvidence"))
        #expect(script.contains("initialEmptyIdentityResolved"))
        #expect(script.contains("mediaIdentityIsInitialBinding = !previousMediaVideoId && !videoId"))
        #expect(script.contains("observerEpoch: observerEpoch"))
    }

    @Test("Uncertain media identity rebinds only with explicit correction evidence")
    func uncertainMediaIdentityRequiresCorrectionEvidence() throws {
        let context = try #require(JSContext())
        context.evaluateScript(SingletonPlayerWebView.mediaIdentityBindingDecisionFunctionJS)

        #expect(context.evaluateScript(
            "__kasetShouldBindMediaIdentity(false, false, true)"
        )?.toBool() == true)
        #expect(context.evaluateScript(
            "__kasetShouldBindMediaIdentity(false, false, false)"
        )?.toBool() == false)
    }

    @Test("Playback timing stays bound to the media element with DOM fallback")
    func mediaTimingPrefersVideoElement() throws {
        let context = try #require(JSContext())
        context.evaluateScript(SingletonPlayerWebView.mediaTimingFunctionJS)
        context.evaluateScript(
            """
            const laggingProgressBar = {
                getAttribute: (name) => name === 'value' ? '179' : '180'
            };
            """
        )

        let mediaTiming = context.evaluateScript(
            "__kasetMediaTiming({ currentTime: 1.25, duration: 200 }, laggingProgressBar)"
        )
        #expect(mediaTiming?.objectForKeyedSubscript("progress")?.toDouble() == 1.25)
        #expect(mediaTiming?.objectForKeyedSubscript("duration")?.toDouble() == 200)

        let fallbackTiming = context.evaluateScript(
            "__kasetMediaTiming({ currentTime: NaN, duration: Infinity }, laggingProgressBar)"
        )
        #expect(fallbackTiming?.objectForKeyedSubscript("progress")?.toDouble() == 179)
        #expect(fallbackTiming?.objectForKeyedSubscript("duration")?.toDouble() == 180)
    }

    @Test("A same-element replay advances the consumed ended generation")
    func endedReplayGenerationGate() throws {
        let context = try #require(JSContext())
        context.evaluateScript(SingletonPlayerWebView.endedReplayGenerationFunctionJS)

        #expect(context.evaluateScript("__kasetShouldAdvanceEndedReplay(4, 4)")?.toBool() == true)
        #expect(context.evaluateScript("__kasetShouldAdvanceEndedReplay(4, 5)")?.toBool() == false)
        #expect(context.evaluateScript("__kasetShouldAdvanceEndedReplay(null, 4)")?.toBool() == false)

        let observerScript = SingletonPlayerWebView.observerScript
        #expect(observerScript.contains("function handlePlaybackStarted()"))
        #expect(observerScript.contains("video.addEventListener('play', handlePlaybackStarted)"))
        #expect(observerScript.contains("video.addEventListener('playing', handlePlaybackStarted)"))

        let occurrenceAdvance = SingletonPlayerWebView.mediaOccurrenceAdvanceFunctionJS
        #expect(occurrenceAdvance.contains("mediaGeneration += 1"))
        #expect(!occurrenceAdvance.contains("mediaVideoId"))
        #expect(!occurrenceAdvance.contains("sendUpdate"))
    }

    @Test("A stale WebView cannot start the current document navigation gate")
    func staleWebViewNavigationStartIsIgnored() {
        let staleWebView = WKWebView()
        let previousState = SingletonPlayerWebView.shared.isDocumentNavigationInProgress
        defer { SingletonPlayerWebView.shared.isDocumentNavigationInProgress = previousState }

        let accepted = SingletonPlayerWebView.shared.beginDocumentNavigation(nil, in: staleWebView)

        #expect(!accepted)
        #expect(SingletonPlayerWebView.shared.isDocumentNavigationInProgress == previousState)
    }

    @Test("Logical ID drift without a media transition does not rebind identity")
    func logicalIDDriftAloneDoesNotBindMediaIdentity() throws {
        let context = try #require(JSContext())
        context.evaluateScript(SingletonPlayerWebView.mediaIdentityBindingDecisionFunctionJS)

        #expect(context.evaluateScript(
            "__kasetShouldBindMediaIdentity(false, false, false)"
        )?.toBool() == false)
        #expect(context.evaluateScript(
            "__kasetShouldBindMediaIdentity(false, false, false)"
        )?.toBool() == false)
        #expect(!SingletonPlayerWebView.observerScript.contains("mediaTime < 5"))
    }
}
