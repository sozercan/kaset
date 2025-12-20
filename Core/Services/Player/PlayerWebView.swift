import Foundation
import WebKit

/// A hidden WKWebView for playback (not used directly - PlayerService manages its own WebView).
/// This file provides helper utilities for WebView-based playback.
@MainActor
final class PlayerWebView: NSObject {
    /// Creates a hidden WebView configuration for playback.
    static func createHiddenWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isHidden = true
        return webView
    }
}
