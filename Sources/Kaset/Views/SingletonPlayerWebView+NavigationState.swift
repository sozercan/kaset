import WebKit

@MainActor
extension SingletonPlayerWebView {
    @discardableResult
    func beginDocumentNavigation(_ navigation: WKNavigation?, in webView: WKWebView) -> Bool {
        guard webView === self.webView else { return false }
        self.activeDocumentNavigation = navigation
        self.activeDocumentNavigationID = self.pendingDocumentID
        self.isDocumentNavigationInProgress = true
        return true
    }

    @discardableResult
    func commitDocumentNavigation(_ navigation: WKNavigation?, in webView: WKWebView) -> Bool {
        guard webView === self.webView else { return false }
        switch (self.activeDocumentNavigation, navigation) {
        case let (active?, committed?) where active === committed:
            return true
        case (nil, nil):
            return true
        default:
            return false
        }
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
