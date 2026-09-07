import WebKit

@MainActor
extension SingletonPlayerWebView {
    nonisolated static func acceptsDocumentNavigationStart(
        isCancelled: Bool,
        trackedGeneration: UInt64?,
        candidateGeneration: UInt64?,
        inFlightGeneration: UInt64?,
        hasPendingGeneration: Bool
    ) -> Bool {
        guard !isCancelled,
              !hasPendingGeneration,
              let inFlightGeneration
        else { return false }
        return (trackedGeneration ?? candidateGeneration) == inFlightGeneration
    }

    @discardableResult
    func beginDocumentNavigation(_ navigation: WKNavigation?, in webView: WKWebView) -> Bool {
        guard webView === self.webView else { return false }
        self.activeDocumentNavigation = navigation
        self.activeDocumentNavigationID = self.pendingDocumentID
        self.isDocumentNavigationInProgress = true
        return true
    }

    func isActiveDocumentNavigation(_ navigation: WKNavigation?, in webView: WKWebView) -> Bool {
        guard webView === self.webView else { return false }
        switch (self.activeDocumentNavigation, navigation) {
        case let (active?, candidate?) where active === candidate:
            return true
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    @discardableResult
    func adoptPendingDocumentIDForActiveNavigation(
        _ navigation: WKNavigation?,
        in webView: WKWebView
    ) -> Bool {
        guard self.isActiveDocumentNavigation(navigation, in: webView),
              let pendingDocumentID = self.pendingDocumentID
        else { return false }
        self.activeDocumentNavigationID = pendingDocumentID
        return true
    }

    @discardableResult
    func commitDocumentNavigation(_ navigation: WKNavigation?, in webView: WKWebView) -> Bool {
        guard self.isActiveDocumentNavigation(navigation, in: webView) else { return false }
        self.coordinator?.playerService.updateAirPlayStatus(isConnected: false)
        return true
    }

    @discardableResult
    func finishDocumentNavigation(_ navigation: WKNavigation?, in webView: WKWebView) -> Bool {
        guard webView === self.webView else { return false }
        switch (self.activeDocumentNavigation, navigation) {
        case let (active?, finished?) where active === finished:
            break
        case (nil, nil):
            break
        default:
            return false
        }
        self.activeDocumentNavigation = nil
        self.activeDocumentNavigationID = nil
        self.isDocumentNavigationInProgress = false
        return true
    }
}
