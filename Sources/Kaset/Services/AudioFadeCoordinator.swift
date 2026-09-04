import Foundation
import WebKit

/// Central coordinator for player audio fading state, track crossfading, and background audio ducking.
@MainActor
final class AudioFadeCoordinator {
    static let shared = AudioFadeCoordinator()

    /// Current audio ducking state for background system events.
    private(set) var isDucked: Bool = false
    private var preDuckVolume: Double = 1.0

    private init() {}

    /// Performs a crossfade transition between currently playing track and next track.
    func crossfadeTrackTransition(
        webView: WKWebView?,
        duration: TimeInterval = 1.5,
        curve: AudioFaderService.FadeCurve = .logarithmic,
        onNextTrackReady: @escaping @MainActor () -> Void
    ) {
        guard let webView else {
            onNextTrackReady()
            return
        }

        // Step 1: Smoothly fade out current track
        AudioFaderService.shared.fadeOut(
            webView: webView,
            duration: duration / 2.0,
            curve: curve
        ) {
            // Step 2: Trigger track change callback once volume is silenced
            onNextTrackReady()

            // Step 3: Smoothly fade back in for new track
            AudioFaderService.shared.fadeIn(
                webView: webView,
                targetVolume: 1.0,
                duration: duration / 2.0,
                curve: curve
            )
        }
    }

    /// Smoothly ducks playback volume when system notifications or notifications play.
    func duckAudio(
        webView: WKWebView?,
        targetDuckedVolume _: Double = 0.25,
        duration: TimeInterval = 0.4
    ) {
        guard let webView, !self.isDucked else { return }

        self.isDucked = true
        self.preDuckVolume = 1.0

        let script = "if (document.querySelector('video')) { document.querySelector('video').volume; }"
        webView.evaluateJavaScript(script) { result, _ in
            if let currentVol = result as? Double {
                Task { @MainActor in
                    AudioFadeCoordinator.shared.preDuckVolume = currentVol
                    AudioFaderService.shared.fadeOut(
                        webView: webView,
                        duration: duration,
                        curve: .linear
                    )
                }
            }
        }
    }

    /// Restores pre-duck volume level after notification ends.
    func restoreAudio(
        webView: WKWebView?,
        duration: TimeInterval = 0.5
    ) {
        guard let webView, self.isDucked else { return }

        self.isDucked = false
        let restoredVolume = self.preDuckVolume

        AudioFaderService.shared.fadeIn(
            webView: webView,
            targetVolume: restoredVolume,
            duration: duration,
            curve: .logarithmic
        )
    }
}
