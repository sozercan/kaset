import Foundation
import WebKit

/// Audio fader service for smooth volume transitions in WKWebView playback.
@MainActor
final class AudioFader {
    static let shared = AudioFader()

    private init() {}

    /// Fade out volume to zero over specified duration
    func fadeOut(webView: WKWebView?, duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
        AudioFaderService.shared.fadeOut(webView: webView, duration: duration, curve: .logarithmic, completion: completion)
    }

    /// Fade in volume from zero to target over specified duration
    func fadeIn(webView: WKWebView?, targetVolume: Double = 1.0, duration: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        AudioFaderService.shared.fadeIn(webView: webView, targetVolume: targetVolume, duration: duration, curve: .logarithmic, completion: completion)
    }
}
