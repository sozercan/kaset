import AppKit
import WebKit

// MARK: - KasetWebView

/// A WKWebView subclass that can suppress key-equivalent interception.
///
/// The singleton player WebView lives in the main window's view hierarchy even
/// during audio-only playback (hidden at 1×1, opacity 0). `NSWindow.performKeyEquivalent`
/// recursively searches the contentView's subviews, and a stock `WKWebView` returns
/// `true` for Space and ⌘←/⌘→ because the YouTube Music page has its own handlers.
/// The event is consumed before the SwiftUI command-menu shortcut fires, leaving
/// Space unable to toggle play/pause (issue #405).
///
/// When `shouldInterceptKeyEquivalents` is `false` (audio-only/hidden), the WebView
/// returns `false` from `performKeyEquivalent` so key equivalents fall through to
/// the menu system. In video mode the flag is `true` and the WebView behaves
/// normally.
final class KasetWebView: WKWebView {
    /// When `false`, key equivalents pass through to the menu system instead of
    /// being consumed by the web page. Set to `true` only in the visible video window.
    var shouldInterceptKeyEquivalents = false

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard self.shouldInterceptKeyEquivalents else { return false }
        return super.performKeyEquivalent(with: event)
    }
}
