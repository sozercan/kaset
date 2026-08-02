import Foundation
import Testing
import WebKit
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct SingletonPlayerNavigationStateTests {
    @Test("Finished playback navigation retries native Web queue synchronization")
    func navigationFinishResynchronizesWebQueue() throws {
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/KasetTests/SingletonPlayerNavigationStateTests.swift",
                with: "Sources/Kaset/Views/MiniPlayerWebView+Coordinator.swift"
            ),
            encoding: .utf8
        )
        let finishHandler = try #require(source.range(
            of: "func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!)"
        ))
        let nextHandler = try #require(source.range(
            of: "func webView(_ webView: WKWebView, didFail navigation: WKNavigation!",
            range: finishHandler.upperBound ..< source.endIndex
        ))
        let finishBody = finishHandler.lowerBound ..< nextHandler.lowerBound
        let acceptedFinish = try #require(source.range(
            of: "handleDocumentNavigationFinish(",
            range: finishBody
        ))
        let expectedPlaybackURL = try #require(source.range(
            of: "WebPlaybackDocumentGeneration.isExpectedPlaybackURL(",
            range: finishBody
        ))
        let syncCall = try #require(source.range(
            of: "self.playerService.syncWebQueue()",
            range: finishBody
        ))
        #expect(acceptedFinish.lowerBound < expectedPlaybackURL.lowerBound)
        #expect(expectedPlaybackURL.lowerBound < syncCall.lowerBound)
    }

    @Test("Only the active document navigation can commit or finish the gate")
    func staleCallbacksDoNotClearActiveNavigationGate() throws {
        let singleton = SingletonPlayerWebView.shared
        singleton.tearDown()
        let webView = singleton.getWebView(
            webKitManager: WebKitManager.makeTestInstance(),
            playerService: PlayerService()
        )
        webView.navigationDelegate = nil
        defer { singleton.tearDown() }

        let activeNavigation = try #require(webView.loadHTMLString("<html>active</html>", baseURL: nil))
        let staleNavigation = try #require(webView.loadHTMLString("<html>stale</html>", baseURL: nil))

        #expect(singleton.beginDocumentNavigation(activeNavigation, in: webView))
        #expect(singleton.isDocumentNavigationInProgress)
        #expect(singleton.activeDocumentNavigation === activeNavigation)

        #expect(!singleton.commitDocumentNavigation(staleNavigation, in: webView))
        #expect(singleton.isDocumentNavigationInProgress)
        #expect(singleton.activeDocumentNavigation === activeNavigation)

        #expect(!singleton.finishDocumentNavigation(staleNavigation, in: webView))
        #expect(singleton.isDocumentNavigationInProgress)
        #expect(singleton.activeDocumentNavigation === activeNavigation)

        #expect(singleton.commitDocumentNavigation(activeNavigation, in: webView))
        #expect(singleton.isDocumentNavigationInProgress)

        #expect(singleton.finishDocumentNavigation(activeNavigation, in: webView))
        #expect(!singleton.isDocumentNavigationInProgress)
        #expect(singleton.activeDocumentNavigation == nil)
        #expect(singleton.activeDocumentNavigationID == nil)
    }

    @Test("Navigation start acceptance rejects stale ownership")
    func navigationStartAcceptanceIsGenerationFenced() {
        #expect(!SingletonPlayerWebView.acceptsDocumentNavigationStart(
            isCancelled: true,
            trackedGeneration: 2,
            candidateGeneration: nil,
            inFlightGeneration: 2,
            hasPendingGeneration: false
        ))
        #expect(!SingletonPlayerWebView.acceptsDocumentNavigationStart(
            isCancelled: false,
            trackedGeneration: 1,
            candidateGeneration: nil,
            inFlightGeneration: 2,
            hasPendingGeneration: false
        ))
        #expect(!SingletonPlayerWebView.acceptsDocumentNavigationStart(
            isCancelled: false,
            trackedGeneration: 2,
            candidateGeneration: nil,
            inFlightGeneration: 2,
            hasPendingGeneration: true
        ))
        #expect(SingletonPlayerWebView.acceptsDocumentNavigationStart(
            isCancelled: false,
            trackedGeneration: 2,
            candidateGeneration: nil,
            inFlightGeneration: 2,
            hasPendingGeneration: false
        ))
        #expect(SingletonPlayerWebView.acceptsDocumentNavigationStart(
            isCancelled: false,
            trackedGeneration: nil,
            candidateGeneration: 2,
            inFlightGeneration: 2,
            hasPendingGeneration: false
        ))
    }

    @Test("Navigation start is validated before replacing the active gate")
    func navigationStartValidationPrecedesGateMutation() throws {
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/KasetTests/SingletonPlayerNavigationStateTests.swift",
                with: "Sources/Kaset/Views/MiniPlayerWebView.swift"
            ),
            encoding: .utf8
        )
        let handlerStart = try #require(source.range(
            of: "func handleDocumentNavigationStart(_ navigation: WKNavigation?, webView: WKWebView)"
        ))
        let nextHandler = try #require(source.range(
            of: "func handleDocumentNavigationRedirect(",
            range: handlerStart.upperBound ..< source.endIndex
        ))
        let handlerRange = handlerStart.lowerBound ..< nextHandler.lowerBound
        let validation = try #require(source.range(
            of: "guard self.trackDocumentNavigationStart(",
            range: handlerRange
        ))
        let gateMutation = try #require(source.range(
            of: "self.beginDocumentNavigation(",
            range: handlerRange
        ))

        #expect(validation.lowerBound < gateMutation.lowerBound)
    }
}
