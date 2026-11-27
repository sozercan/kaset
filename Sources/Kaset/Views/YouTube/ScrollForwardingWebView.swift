import WebKit

final class ScrollForwardingWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        guard self.forwardsScrollWheel else {
            super.scrollWheel(with: event)
            return
        }
        if let scrollView = self.enclosingScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            self.nextResponder?.scrollWheel(with: event)
        }
    }

    private var forwardsScrollWheel: Bool {
        !WebPlaybackDocumentGeneration.isTrustedIntermediaryURL(self.url)
    }
}
