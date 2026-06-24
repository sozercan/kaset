import AppKit
import WebKit

// MARK: - WebPlayerScripts

/// Origin-neutral building blocks shared by the two playback WebViews
/// (`SingletonPlayerWebView` for YouTube Music and `YouTubeWatchWebView` for
/// regular YouTube).
///
/// Per ADR-0020 the two stacks are deliberately parallel — separate observers,
/// commands, models, and clients — because their DOM and InnerTube origins
/// genuinely differ. The few primitives that operate on a generic HTML
/// `<video>` element (and the WebView hosting it) are *not* origin-specific,
/// so they live here as one source of truth. See ADR-0024.
nonisolated enum WebPlayerScripts {
    /// Clamps a desired playback volume into the valid `0...1` range, mapping
    /// non-finite input (NaN/∞) to full volume. Both playback paths share this
    /// so the `<video>.volume` target is computed identically.
    static func clampVolume(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 1.0
    }

    /// The document-start snippet that hands the Kaset-managed volume target to
    /// a freshly loaded watch page. Both observer scripts read
    /// `window.__kasetTargetVolume` to keep the page from reverting volume.
    static func targetVolumeBootstrap(_ value: Double) -> String {
        "window.__kasetTargetVolume = \(self.clampVolume(value));"
    }

    // MARK: - Generic <video> Commands

    /// A JavaScript expression that evaluates to the page's playback `<video>`
    /// element. Differs per origin only in where the element lives in the DOM.
    enum VideoElement {
        /// `document.querySelector('video')` — the lone YouTube Music player video.
        case ytMusic
        /// `#movie_player video` preferred, falling back to any `video` — the
        /// regular YouTube watch page (which can host stray `<video>` elements).
        case youTube

        var accessorJS: String {
            switch self {
            case .ytMusic:
                "document.querySelector('video')"
            case .youTube:
                "document.querySelector('#movie_player video') || document.querySelector('video')"
            }
        }
    }

    /// Resumes the `<video>` element if it is paused. Result is intentionally
    /// unobserved by callers (`completionHandler: nil`).
    static func play(_ element: VideoElement) -> String {
        """
        (function() {
            const video = \(element.accessorJS);
            if (video && video.paused) { video.play(); }
        })();
        """
    }

    /// Pauses the `<video>` element if it is playing.
    static func pause(_ element: VideoElement) -> String {
        """
        (function() {
            const video = \(element.accessorJS);
            if (video && !video.paused) { video.pause(); }
        })();
        """
    }

    /// Seeks the `<video>` element to `time` seconds. Callers are responsible
    /// for validating `time` before calling (the music and YouTube paths apply
    /// different guards).
    static func seek(to time: Double, element: VideoElement) -> String {
        """
        (function() {
            const video = \(element.accessorJS);
            if (video) { video.currentTime = \(time); }
        })();
        """
    }
}

// MARK: - WKWebView Reparenting

@MainActor
extension WKWebView {
    /// Moves this web view into `container`, making it fill the container via
    /// autoresizing. No-op when it is already the container's subview.
    ///
    /// Shared by both playback singletons: each hosts a single long-lived
    /// `WKWebView` that is reparented between native containers (hidden anchor,
    /// inline surface, floating window) without tearing down playback.
    func reparent(into container: NSView) {
        guard self.superview !== container else { return }
        self.removeFromSuperview()
        container.addSubview(self)
        self.translatesAutoresizingMaskIntoConstraints = true
        self.frame = container.bounds
        self.autoresizingMask = [.width, .height]
    }
}

// MARK: - Content Process Recovery

@MainActor
extension WebPlayerScripts {
    /// Recovers a playback WebView after its content process terminates: reload
    /// immediately, then (if a video was playing) clear the tracked id and
    /// re-load it after a beat so the player re-initialises cleanly.
    ///
    /// Both `SingletonPlayerWebView.Coordinator` and
    /// `YouTubeWatchWebView.Coordinator` share this recovery shape; they differ
    /// only in which singleton they read/write, supplied via the closures.
    static func recoverFromContentProcessTermination(
        webView: WKWebView,
        lastVideoId: String?,
        clearTrackedVideoId: @MainActor @escaping () -> Void,
        reloadVideo: @MainActor @escaping (String) -> Void
    ) {
        webView.reload()

        guard let lastVideoId else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            clearTrackedVideoId()
            reloadVideo(lastVideoId)
        }
    }
}
