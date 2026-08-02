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
}
