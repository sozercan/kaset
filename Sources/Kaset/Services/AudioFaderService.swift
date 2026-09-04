import Foundation
import WebKit

/// Advanced audio fading service providing logarithmic volume ramps and smooth playback crossfades.
@MainActor
final class AudioFaderService {
    static let shared = AudioFaderService()

    /// Volume attenuation curve type for audio ramping.
    enum FadeCurve: String, CaseIterable, Identifiable {
        case linear
        case logarithmic

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .linear: "Linear"
            case .logarithmic: "Logarithmic (Natural)"
            }
        }
    }

    private init() {}

    /// Fades volume from current level to zero over specified duration with optional completion handler.
    func fadeOut(
        webView: WKWebView?,
        duration: TimeInterval = 1.0,
        curve: FadeCurve = .logarithmic,
        completion: (@MainActor () -> Void)? = nil
    ) {
        guard let webView else {
            completion?()
            return
        }

        let durationMs = max(1, Int(duration * 1000))
        let isLogarithmic = curve == .logarithmic
        let script = """
            (function() {
                const video = document.querySelector('video');
                const startVol = (video && video.volume > 0)
                    ? video.volume
                    : (typeof window.__kasetTargetVolume === 'number' ? window.__kasetTargetVolume : 1.0);
                if (window.__kasetAudio) {
                    window.__kasetAudio.fadeRamp(startVol, 0.0, \(durationMs), \(isLogarithmic), null);
                } else if (video) {
                    video.volume = 0.0;
                }
            })();
        """
        webView.evaluateJavaScript(script) { _, _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                completion?()
            }
        }
    }

    /// Fades volume in from zero to target volume level over specified duration.
    func fadeIn(
        webView: WKWebView?,
        targetVolume: Double = 1.0,
        duration: TimeInterval = 1.0,
        curve: FadeCurve = .logarithmic,
        completion: (@MainActor () -> Void)? = nil
    ) {
        guard let webView else {
            completion?()
            return
        }

        let durationMs = max(1, Int(duration * 1000))
        let isLogarithmic = curve == .logarithmic
        let target = max(0.0, min(1.0, targetVolume))
        let script = """
            (function() {
                if (window.__kasetAudio) {
                    window.__kasetAudio.fadeRamp(0.0, \(target), \(durationMs), \(isLogarithmic), null);
                } else {
                    const video = document.querySelector('video');
                    if (video) video.volume = \(target);
                }
            })();
        """
        webView.evaluateJavaScript(script) { _, _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                completion?()
            }
        }
    }

    /// Cancels any active volume fade timer immediately.
    func cancelActiveFade(webView: WKWebView? = nil) {
        let script = "if (window.__kasetAudio) { window.__kasetAudio.cancelFade(); }"
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    static func calculateFactor(progress: Double, curve: FadeCurve) -> Double {
        let clamped = max(0.0, min(1.0, progress))
        switch curve {
        case .linear:
            return clamped
        case .logarithmic:
            return pow(clamped, 2.2)
        }
    }
}
