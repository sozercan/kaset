import AppKit
import WebKit

// MARK: - KasetWebView

/// A WKWebView that suppresses key-equivalent interception when hidden.
///
/// The singleton player WebView lives in the main window's view hierarchy even
/// during audio-only playback (hidden at 1×1, opacity 0). `NSWindow.performKeyEquivalent`
/// recursively searches the contentView's subviews, and a stock `WKWebView` returns
/// `true` for Space and ⌘←/⌘→ because the YouTube Music page has its own handlers.
/// The event is consumed before the SwiftUI command-menu shortcut fires, leaving
/// Space unable to toggle play/pause (issue #405).
///
/// When the WebView is visible with non-trivial bounds (video mode), key
/// equivalents are forwarded to the page as normal. When hidden (audio-only),
/// `performKeyEquivalent` returns `false` so the event falls through to the
/// menu system. Deriving from live state avoids a manually-synced flag that can
/// desync after WebView recreation or reparenting; it mirrors the pattern in
/// `ScrollForwardingWebView`.
final class KasetWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard self.bounds.width > 1, self.bounds.height > 1 else { return false }
        return super.performKeyEquivalent(with: event)
    }
}
