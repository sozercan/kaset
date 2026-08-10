import WebKit

// MARK: - ScrollForwardingWebView

/// A WebView that hands scroll-wheel events to the view behind it.
///
/// The extracted watch document is `overflow: hidden`, so it has nothing to
/// scroll and simply swallows the event. Inside the watch page's `ScrollView`
/// that turns the whole video surface into a dead zone. Forwarding restores
/// scrolling over the video while leaving clicks (play/pause, the player
/// chrome) with the WebView — an overlay would intercept those too.
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

    /// Only the extracted watch document is unscrollable. A revealed
    /// interstitial (consent, CAPTCHA, sign-in) is an ordinary page that can
    /// be taller than the viewport, so it has to keep its own wheel handling
    /// or its controls become unreachable.
    private var forwardsScrollWheel: Bool {
        !WebPlaybackDocumentGeneration.isTrustedIntermediaryURL(self.url)
    }
}
