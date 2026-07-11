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
