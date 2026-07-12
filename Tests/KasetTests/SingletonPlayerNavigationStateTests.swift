import Foundation
import Testing
import WebKit
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct SingletonPlayerNavigationStateTests {
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
