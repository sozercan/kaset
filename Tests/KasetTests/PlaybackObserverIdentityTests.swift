import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import Kaset

@Suite(.tags(.service))
@MainActor
struct PlaybackObserverIdentityTests {
    @Test("Playback snapshots retain outgoing identity until the physical media changes")
    func playbackSnapshotRejectsEarlyLogicalIdentity() throws {
        let context = try MusicPlaybackObserverTestContext.make()
        let initial = context.evaluateScript(SingletonPlayerWebView.playbackSnapshotScript)
        #expect(initial?.objectForKeyedSubscript("videoId")?.toString() == "v1")
        #expect(initial?.objectForKeyedSubscript("progress")?.toDouble() == 179)

        context.evaluateScript("currentDataVideoId = 'v2'; dispatch('timeupdate');")
        let transitioning = context.evaluateScript(SingletonPlayerWebView.playbackSnapshotScript)
        #expect(transitioning?.objectForKeyedSubscript("videoId")?.toString() == "v1")
        #expect(transitioning?.objectForKeyedSubscript("progress")?.toDouble() == 179)

        context.evaluateScript("""
        video.currentSrc = 'https://media.example/v2';
        video.currentTime = 1;
        video.duration = 200;
        dispatch('loadedmetadata');
        """)
        let bound = context.evaluateScript(SingletonPlayerWebView.playbackSnapshotScript)
        #expect(bound?.objectForKeyedSubscript("videoId")?.toString() == "v2")
        #expect(bound?.objectForKeyedSubscript("progress")?.toDouble() == 1)
        #expect(bound?.objectForKeyedSubscript("duration")?.toDouble() == 200)
        #expect(context.exception == nil)
    }

    @Test("Playback snapshots wait for identity when physical media changes first")
    func playbackSnapshotWaitsForMediaIdentityRefresh() throws {
        let context = try MusicPlaybackObserverTestContext.make()
        context.evaluateScript("""
        video.currentSrc = 'https://media.example/v2';
        video.currentTime = 1;
        """)
        let beforeBinding = context.evaluateScript(SingletonPlayerWebView.playbackSnapshotScript)
        #expect(beforeBinding?.isNull == true)

        context.evaluateScript("dispatch('loadedmetadata');")
        let refreshing = context.evaluateScript(SingletonPlayerWebView.playbackSnapshotScript)
        #expect(refreshing?.isNull == true)

        context.evaluateScript("currentDataVideoId = 'v2'; fakeNow = 1000; dispatch('timeupdate');")
        let bound = context.evaluateScript(SingletonPlayerWebView.playbackSnapshotScript)
        #expect(bound?.objectForKeyedSubscript("videoId")?.toString() == "v2")
        #expect(bound?.objectForKeyedSubscript("progress")?.toDouble() == 1)
        #expect(context.exception == nil)
    }

    @Test("Playback snapshots reject a replacement media element before observer binding")
    func playbackSnapshotRejectsUnboundReplacement() throws {
        let context = try MusicPlaybackObserverTestContext.make()
        context.evaluateScript("""
        video = Object.assign({}, video);
        delete video.__kasetBoundVideoId;
        delete video.__kasetMediaGeneration;
        """)

        let snapshot = context.evaluateScript(SingletonPlayerWebView.playbackSnapshotScript)
        #expect(snapshot?.isNull == true)
        #expect(context.exception == nil)
    }

    @Test("Playback snapshots stay available after a seek within the same media")
    func playbackSnapshotSurvivesSameMediaSeek() throws {
        let context = try MusicPlaybackObserverTestContext.make()
        context.evaluateScript("video.currentTime = 30; dispatch('canplay');")

        let snapshot = context.evaluateScript(SingletonPlayerWebView.playbackSnapshotScript)
        #expect(snapshot?.objectForKeyedSubscript("videoId")?.toString() == "v1")
        #expect(snapshot?.objectForKeyedSubscript("progress")?.toDouble() == 30)
        #expect(context.exception == nil)
    }

    @Test("Playback snapshots resume after a same-track source correction settles")
    func playbackSnapshotResumesAfterSourceCorrection() throws {
        let context = try MusicPlaybackObserverTestContext.make()
        context.evaluateScript("""
        video.currentSrc = 'https://media.example/v1-new-quality';
        dispatch('loadedmetadata');
        """)
        let correcting = context.evaluateScript(SingletonPlayerWebView.playbackSnapshotScript)
        #expect(correcting?.isNull == true)

        context.evaluateScript("fakeNow = 6000; dispatch('timeupdate');")
        let snapshot = context.evaluateScript(SingletonPlayerWebView.playbackSnapshotScript)
        #expect(snapshot?.objectForKeyedSubscript("videoId")?.toString() == "v1")
        #expect(snapshot?.objectForKeyedSubscript("progress")?.toDouble() == 179)
        #expect(context.exception == nil)
    }

    @Test("Observer reports media-bound identity and generation with playback state")
    func observerReportsMediaIdentity() {
        let script = SingletonPlayerWebView.observerScript

        #expect(script.contains("bindMediaIdentity(video, true, false)"))
        #expect(script.contains("mediaVideoId: mediaVideoId"))
        #expect(script.contains("mediaGeneration: mediaGeneration"))
        #expect(script.contains("observerEpoch: observerEpoch"))
        #expect(script.contains("mediaIdentityCorrectionDeadline"))
        #expect(script.contains("window.__kasetAdvanceMediaGeneration"))
        #expect(script.contains("const mediaTimeReset = mediaTime + 2 < lastMediaCurrentTime"))
        #expect(script.range(
            of: #"sourceChanged,\s*mediaTimeReset,\s*identityCorrectionEvidence"#,
            options: .regularExpression
        ) != nil)
        #expect(script.contains("if (video.readyState >= 1)"))
        #expect(script.contains("mediaIdentityTransitionFromVideoId"))
        #expect(script.contains("confirmMediaIdentityOnPlaying"))
        #expect(script.contains("identityCorrectionEvidence"))
        #expect(script.contains("lateIdentityRefreshResolved"))
        #expect(script.contains("initialEmptyIdentityResolved"))
        #expect(script.contains("mediaIdentityIsInitialBinding = !previousMediaVideoId && !videoId"))
        #expect(script.contains("observerEpoch: observerEpoch"))
    }

    @Test("Same-video metadata transitions keep a bounded correction window")
    func sameVideoMetadataTransitionKeepsCorrectionWindow() throws {
        let context = try #require(JSContext())
        context.evaluateScript(SingletonPlayerWebView.mediaIdentityCorrectionWindowFunctionJS)

        #expect(context.evaluateScript(
            "__kasetShouldOpenMediaIdentityCorrectionWindow('v1', 'v1', true, false)"
        )?.toBool() == true)
        #expect(context.evaluateScript(
            "__kasetShouldOpenMediaIdentityCorrectionWindow('v1', 'v1', false, false)"
        )?.toBool() == false)
        #expect(context.evaluateScript(
            "__kasetShouldOpenMediaIdentityCorrectionWindow('v2', 'v1', true, true)"
        )?.toBool() == false)
        #expect(context.evaluateScript(
            "__kasetIsMediaIdentityCorrectionWindowActive(6000, 5000)"
        )?.toBool() == true)
        #expect(context.evaluateScript(
            "__kasetIsMediaIdentityCorrectionWindowActive(5000, 6000)"
        )?.toBool() == false)
        #expect(context.evaluateScript(
            "__kasetShouldCommitMediaIdentityCorrection(5000, 6000)"
        )?.toBool() == true)
        #expect(context.evaluateScript(
            "__kasetShouldCommitMediaIdentityCorrection(6000, 5000)"
        )?.toBool() == false)
        #expect(context.evaluateScript(
            "__kasetShouldResolveLateMediaIdentityRefresh(true, 'v2', 'v1')"
        )?.toBool() == true)
        #expect(context.evaluateScript(
            "__kasetShouldResolveLateMediaIdentityRefresh(false, 'v2', 'v1')"
        )?.toBool() == false)
        #expect(context.evaluateScript(
            "__kasetShouldResolveLateMediaIdentityRefresh(true, 'v1', 'v1')"
        )?.toBool() == false)
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

    @Test("YouTube Music watch URLs encode video IDs as query values")
    func youtubeMusicWatchURLPercentEncodesVideoId() throws {
        let videoId = "video&id=unexpected value"
        let url = try #require(SingletonPlayerWebView.youtubeMusicWatchURL(videoId: videoId))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.scheme == "https")
        #expect(components.host == "music.youtube.com")
        #expect(components.path == "/watch")
        #expect(components.queryItems == [URLQueryItem(name: "v", value: videoId)])
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
