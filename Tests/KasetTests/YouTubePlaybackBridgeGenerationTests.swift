import Foundation
import Testing
@testable import Kaset

@Suite("YouTube playback bridge generation", .tags(.service))
@MainActor
struct YouTubePlaybackBridgeGenerationTests {
    @Test("Bridge acceptance requires current WebView identity and active generation")
    func bridgeAcceptanceRequiresIdentityAndGeneration() {
        let currentWebView = NSObject()
        let replacedWebView = NSObject()
        var documentGeneration = WebPlaybackDocumentGeneration()
        let activeGeneration = documentGeneration.beginNavigation()
        let didStartGeneration = documentGeneration.startNavigation(activeGeneration)
        let didCommitGeneration = documentGeneration.commitNavigation(activeGeneration)
        #expect(didStartGeneration)
        #expect(didCommitGeneration)

        #expect(YouTubeWatchWebView.acceptsBridgeMessage(
            sourceWebView: currentWebView,
            currentWebView: currentWebView,
            documentGeneration: documentGeneration,
            rawDocumentGeneration: activeGeneration
        ))
        #expect(!YouTubeWatchWebView.acceptsBridgeMessage(
            sourceWebView: replacedWebView,
            currentWebView: currentWebView,
            documentGeneration: documentGeneration,
            rawDocumentGeneration: activeGeneration
        ))
        #expect(!YouTubeWatchWebView.acceptsBridgeMessage(
            sourceWebView: currentWebView,
            currentWebView: currentWebView,
            documentGeneration: documentGeneration,
            rawDocumentGeneration: activeGeneration + 1
        ))
        #expect(!YouTubeWatchWebView.acceptsBridgeSource(
            isMainFrame: false,
            sourceScheme: "https",
            sourceHost: "www.youtube.com"
        ))
        #expect(!YouTubeWatchWebView.acceptsBridgeSource(
            isMainFrame: true,
            sourceScheme: "https",
            sourceHost: "music.youtube.com"
        ))
    }

    @Test("Pending navigation suppresses bridge acceptance until cancel or activation")
    func pendingNavigationSuppressesBridgeAcceptance() {
        let currentWebView = NSObject()
        var documentGeneration = WebPlaybackDocumentGeneration()
        let committedGeneration = documentGeneration.beginNavigation()
        let didStartCommittedGeneration = documentGeneration.startNavigation(committedGeneration)
        let didCommitCommittedGeneration = documentGeneration.commitNavigation(committedGeneration)
        #expect(didStartCommittedGeneration)
        #expect(didCommitCommittedGeneration)

        let pendingGeneration = documentGeneration.beginNavigation()
        #expect(!YouTubeWatchWebView.acceptsBridgeMessage(
            sourceWebView: currentWebView,
            currentWebView: currentWebView,
            documentGeneration: documentGeneration,
            rawDocumentGeneration: committedGeneration
        ))

        documentGeneration.cancelPendingNavigation()
        #expect(YouTubeWatchWebView.acceptsBridgeMessage(
            sourceWebView: currentWebView,
            currentWebView: currentWebView,
            documentGeneration: documentGeneration,
            rawDocumentGeneration: committedGeneration
        ))

        let replacementGeneration = documentGeneration.beginNavigation()
        #expect(replacementGeneration > pendingGeneration)
        let didStartReplacementGeneration = documentGeneration.startNavigation(replacementGeneration)
        let didCommitReplacementGeneration = documentGeneration.commitNavigation(replacementGeneration)
        #expect(didStartReplacementGeneration)
        #expect(didCommitReplacementGeneration)
        documentGeneration.cancelPendingNavigation()
        #expect(YouTubeWatchWebView.acceptsBridgeMessage(
            sourceWebView: currentWebView,
            currentWebView: currentWebView,
            documentGeneration: documentGeneration,
            rawDocumentGeneration: replacementGeneration
        ))
        #expect(!documentGeneration.accepts(rawGeneration: committedGeneration))
    }

    @Test("User-script bootstrap selects pending generation, otherwise active generation")
    func userScriptBootstrapSelectsPendingOrActiveGeneration() {
        var documentGeneration = WebPlaybackDocumentGeneration()

        #expect(YouTubeWatchWebView.userScriptDocumentGeneration(from: documentGeneration) == 0)

        let pendingGeneration = documentGeneration.beginNavigation()
        #expect(
            YouTubeWatchWebView.userScriptDocumentGeneration(from: documentGeneration)
                == pendingGeneration
        )
        let pendingBootstrap = YouTubeWatchWebView.pageBootstrapScript(
            targetVolume: 0.5,
            documentGeneration: YouTubeWatchWebView.userScriptDocumentGeneration(from: documentGeneration)
        )
        #expect(pendingBootstrap.contains("window.__kasetDocumentGeneration = -1;"))

        documentGeneration.cancelPendingNavigation()
        #expect(
            YouTubeWatchWebView.userScriptDocumentGeneration(from: documentGeneration)
                == documentGeneration.currentGeneration
        )
    }

    @Test("Watch URL binds its document generation to the navigation")
    func watchURLBindsDocumentGeneration() throws {
        let url = try #require(YouTubeWatchWebView.watchURL(
            videoId: "video",
            documentGeneration: 42
        ))

        #expect(WebPlaybackDocumentGeneration.generation(from: url) == 42)
    }

    @Test("YouTube main-frame response rejects non-2xx and mismatched watch documents")
    func mainFrameResponseRequiresExpectedSuccessfulWatchDocument() throws {
        var documentGeneration = WebPlaybackDocumentGeneration()
        let generation = documentGeneration.beginNavigation()
        let didStart = documentGeneration.startNavigation(generation)
        #expect(didStart)
        let expectedURL = try #require(YouTubeWatchWebView.watchURL(
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
            statusCode: 404,
            httpVersion: nil,
            headerFields: nil
        ))

        #expect(WebPlaybackDocumentGeneration.acceptsMainFrameResponse(
            success,
            expectedHost: "www.youtube.com",
            expectedVideoID: "video",
            allowsInternalBlank: documentGeneration.ownsBlankNavigation(success.url)
        ))
        #expect(!WebPlaybackDocumentGeneration.acceptsMainFrameResponse(
            failure,
            expectedHost: "www.youtube.com",
            expectedVideoID: "video",
            allowsInternalBlank: documentGeneration.ownsBlankNavigation(failure.url)
        ))
        #expect(!WebPlaybackDocumentGeneration.acceptsMainFrameResponse(
            success,
            expectedHost: "www.youtube.com",
            expectedVideoID: "other",
            allowsInternalBlank: documentGeneration.ownsBlankNavigation(success.url)
        ))
    }
}
