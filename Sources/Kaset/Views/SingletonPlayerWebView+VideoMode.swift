import SwiftUI
import WebKit

// MARK: - SingletonPlayerWebView Video Mode Extension

extension SingletonPlayerWebView {
    /// Updates WebView size based on display mode.
    func updateDisplayMode(_ mode: DisplayMode) {
        guard let webView, self.displayMode != mode else { return }
        DiagnosticsLogger.player.info("SingletonPlayerWebView.updateDisplayMode: \(String(describing: mode), privacy: .public)")
        self.displayMode = mode

        switch mode {
        case .hidden:
            // WebView stays in hierarchy but tiny
            webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            self.removeVideoModeCSS()
        case .miniPlayer:
            webView.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
            self.removeVideoModeCSS()
        case .video:
            // Immediately inject blackout CSS to hide web UI while we prepare video
            self.injectBlackoutCSS()
            // Full size - parent container determines size
            // Defer injection until container has valid bounds (SwiftUI layout)
            self.waitForValidBoundsAndInject()
        }
    }

    /// Injects a temporary blackout overlay to hide the web UI during video mode setup.
    func injectBlackoutCSS() {
        guard let webView else { return }

        let script = """
            (function() {
                // Create blackout overlay if it doesn't exist
                if (!document.getElementById('kaset-blackout')) {
                    const blackout = document.createElement('div');
                    blackout.id = 'kaset-blackout';
                    blackout.style.cssText = `
                        position: fixed !important;
                        top: 0 !important;
                        left: 0 !important;
                        width: 100vw !important;
                        height: 100vh !important;
                        background: #000 !important;
                        z-index: 2147483646 !important;
                    `;
                    document.body.appendChild(blackout);
                }
            })();
        """
        webView.evaluateJavaScript(script) { _, _ in }
    }

    /// Waits for the WebView's superview to have valid (non-zero) bounds, then injects CSS.
    func waitForValidBoundsAndInject(attempts: Int = 0) {
        guard let webView else { return }

        let maxAttempts = 20 // 2 seconds max (20 * 100ms)
        if let superview = webView.superview, superview.bounds.width > 0, superview.bounds.height > 0 {
            webView.frame = superview.bounds
            webView.autoresizingMask = [.width, .height]
            self.injectVideoModeCSS()
        } else if attempts < maxAttempts {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                self?.waitForValidBoundsAndInject(attempts: attempts + 1)
            }
        } else {
            // Fall back to current bounds anyway
            if let superview = webView.superview {
                webView.frame = superview.bounds
                webView.autoresizingMask = [.width, .height]
            }
            self.injectVideoModeCSS()
        }
    }

    /// Injects CSS to hide YouTube Music UI and show only the video.
    /// Called when entering video mode or when page reloads while in video mode.
    func injectVideoModeCSS() {
        guard let webView else { return }

        // First, let's debug what's in the DOM
        let debugScript = """
            (function() {
                const video = document.querySelector('video');
                const videoInfo = video ? {
                    src: video.src ? video.src.substring(0, 100) : 'none',
                    width: video.videoWidth,
                    height: video.videoHeight,
                    paused: video.paused,
                    display: getComputedStyle(video).display,
                    visibility: getComputedStyle(video).visibility
                } : 'no video element';

                const tabs = document.querySelectorAll('tp-yt-paper-tab');
                const tabTexts = Array.from(tabs).map(t => t.textContent.trim());

                const playerPage = document.querySelector('ytmusic-player-page');
                const moviePlayer = document.querySelector('#movie_player');
                const html5Player = document.querySelector('.html5-video-player');

                return {
                    videoInfo: videoInfo,
                    tabTexts: tabTexts,
                    hasPlayerPage: !!playerPage,
                    hasMoviePlayer: !!moviePlayer,
                    hasHtml5Player: !!html5Player,
                    url: window.location.href
                };
            })();
        """

        webView.evaluateJavaScript(debugScript) { [weak self] result, error in
            if let error {
                DiagnosticsLogger.player.error("Video debug script failed: \(error.localizedDescription, privacy: .public)")
            }
            if let dict = result as? [String: Any] {
                DiagnosticsLogger.player.info("Video mode debug result (Info): \(String(describing: dict), privacy: .public)")
            }
            // Now click the Video tab
            self?.clickVideoTabAndInjectCSS()
        }
    }

    /// Clicks the Video tab and then injects CSS.
    func clickVideoTabAndInjectCSS() {
        guard let webView else { return }

        // The Song/Video toggle is different from the tabs
        // It appears as a segmented control near the top of the player page
        let clickVideoTabScript = """
            (function() {
                // Method 1: Internal State Enforcement (Most robust)
                const playerPage = document.querySelector('ytmusic-player-page');
                if (playerPage && typeof playerPage.videoMode !== 'undefined') {
                    if (playerPage.videoMode !== true) {
                        playerPage.videoMode = true;
                        if (typeof playerPage.onVideoModeChanged === 'function') {
                            playerPage.onVideoModeChanged();
                        }
                        console.log('[Kaset] Forced videoMode = true via property');
                        return { clicked: true, method: 'propertySet' };
                    }
                    return { clicked: false, message: 'Already in video mode (property)' };
                }

                // Method 2: Click the AV Switcher (Native feel)
                const switcher = document.querySelector('ytmusic-av-switcher');
                if (switcher) {
                    const videoBtn = switcher.querySelector('#video-button');
                    if (videoBtn && !videoBtn.hasAttribute('active')) {
                        videoBtn.click();
                        console.log('[Kaset] Clicked Video toggle via switcher');
                        return { clicked: true, method: 'switcher' };
                    }
                }

                // Method 3: Fallback Button Search
                const allButtons = document.querySelectorAll('tp-yt-paper-button, button, [role="button"]');
                for (const btn of allButtons) {
                    const text = (btn.textContent || btn.innerText || '').trim().toLowerCase();
                    if (text === 'video') {
                        const isActive = btn.hasAttribute('active') || btn.classList.contains('active') || btn.getAttribute('aria-pressed') === 'true';
                        if (!isActive) {
                            btn.click();
                            console.log('[Kaset] Clicked Video button by text');
                            return { clicked: true, method: 'textMatch' };
                        }
                        return { clicked: false, message: 'Already in video mode (text)' };
                    }
                }

                return { clicked: false, message: 'Video toggle/property not found' };
            })();
        """

        webView.evaluateJavaScript(clickVideoTabScript) { [weak self] result, _ in
            // Log if Video tab wasn't found (YouTube UI may have changed)
            if let resultDict = result as? [String: Any],
               let clicked = resultDict["clicked"] as? Bool,
               !clicked
            {
                let msg = resultDict["message"] as? String ?? "unknown"
                self?.logger.warning("Video tab not found: \(msg, privacy: .public)")
                // Fallback: Remove blackout if we can't find the toggle, so user at least sees SOMETHING
                self?.removeBlackoutOnly()
            } else if result == nil {
                self?.logger.warning("Video tab script returned nil result - blackout may persist")
                self?.removeBlackoutOnly()
            }

            // Wait a moment for the video mode to activate, then inject CSS
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.injectVideoModeStyles()
            }
        }
    }

    /// Helper to remove blackout overlay on failures
    private func removeBlackoutOnly() {
        self.webView?.evaluateJavaScript("const b = document.getElementById('kaset-blackout'); if (b) b.remove();")
    }

    /// Actually injects the CSS styles for video mode.
    func injectVideoModeStyles() {
        guard let webView else { return }

        // Use superview frame since that's the actual container size
        _ = webView.superview?.frame ?? .zero

        let script = Self.videoContainerScriptInPlace()
        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error {
                DiagnosticsLogger.player.error("Failed to inject video mode styles: \(error.localizedDescription, privacy: .public)")
                self?.removeBlackoutOnly()
                return
            }
            DiagnosticsLogger.player.info("Video mode styles (In-place) successfully injected")
            self?.removeBlackoutOnly()
        }
    }

    // swiftlint:disable function_body_length
    /// Generates the JavaScript to hide UI and show only video in-place.
    private static func videoContainerScriptInPlace() -> String {
        """
        (function() {
            'use strict';

            // 1. Create a global style to hide EVERYTHING by default
            // Then specifically un-hide only the player tree.
            const styleId = 'kaset-video-mode-style-v2';
            let style = document.getElementById(styleId);
            if (!style) {
                style = document.createElement('style');
                style.id = styleId;
                document.head.appendChild(style);
            }

            style.textContent = `
                /* Hide everything by default */
                html, body, * {
                    visibility: hidden !important;
                }

                /* Show precisely the ancestor chain and its required layout */
                .kaset-visible {
                    visibility: visible !important;
                    display: block !important;
                    opacity: 1 !important;
                    padding: 0 !important;
                    margin: 0 !important;
                    background: #000 !important;
                    z-index: 2147483640 !important;
                }

                /* Ensure containers don't clip the video */
                .kaset-visible {
                    width: 100vw !important;
                    height: 100vh !important;
                    position: fixed !important;
                    top: 0 !important;
                    left: 0 !important;
                    overflow: visible !important;
                }

                /* The actual video element gets highest priority */
                video.kaset-visible, .video-stream.kaset-visible {
                    z-index: 2147483647 !important;
                    object-fit: contain !important;
                }

                body {
                    background: #000 !important;
                    overflow: hidden !important;
                    visibility: visible !important;
                }
                html {
                    visibility: visible !important;
                }
            `;

            // 2. Identify the video and mark its ancestors
            const markAncestors = () => {
                const video = document.querySelector('video');
                if (!video) return;

                // Clear old marks
                document.querySelectorAll('.kaset-visible').forEach(el => el.classList.remove('kaset-visible'));

                // Mark current video and all its parents
                let current = video;
                while (current && current !== document.documentElement) {
                    current.classList.add('kaset-visible');
                    current = current.parentElement;
                }
            };

            // 3. Continuous Enforcement Loop
            const enforceVisibility = () => {
                markAncestors();
                const video = document.querySelector('video');
                if (video && typeof window.__kasetVideoModeActive === 'boolean' && window.__kasetVideoModeActive) {
                    // Force Video Mode via Redux/Property if needed
                    const playerPage = document.querySelector('ytmusic-player-page');
                    if (playerPage && playerPage.videoMode !== true) {
                        playerPage.videoMode = true;
                        if (typeof playerPage.onVideoModeChanged === 'function') playerPage.onVideoModeChanged();
                    }
                }
                if (window.__kasetVideoModeActive) {
                    requestAnimationFrame(enforceVisibility);
                }
            };
            window.__kasetVideoModeActive = true;
            requestAnimationFrame(enforceVisibility);

            // Remove the extraction container if it exists from previous attempts
            const oldContainer = document.getElementById('kaset-video-container');
            if (oldContainer) {
                const video = oldContainer.querySelector('video');
                if (video && video.__kasetOriginalParent) {
                    video.__kasetOriginalParent.appendChild(video);
                    delete video.__kasetOriginalParent;
                }
                oldContainer.remove();
            }

            return { success: true };
        })();
        """
    }

    // swiftlint:enable function_body_length

    /// Removes the video container and restores the video to its original location.
    func removeVideoModeCSS() {
        guard let webView else { return }

        let script = """
            (function() {
                // Remove blackout overlay
                const blackout = document.getElementById('kaset-blackout');
                if (blackout) blackout.remove();

                // Remove the in-place style
                const style = document.getElementById('kaset-video-mode-style-v2');
                if (style) style.remove();

                // Stop the enforcement loop
                window.__kasetVideoModeActive = false;

                // Remove video styles manually too
                const videos = document.querySelectorAll('video');
                for (const video of videos) {
                    video.style.setProperty('width', '', '');
                    video.style.setProperty('height', '', '');
                    video.style.setProperty('position', '', '');
                    video.style.setProperty('display', '', '');
                    video.style.setProperty('visibility', '', '');
                }

                // Restore body
                document.body.style.overflow = '';
                document.body.style.background = '';
            })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Re-injects video mode after resize or other layout changes.
    /// Ensures the video container fills the entire viewport.
    func refreshVideoModeCSS() {
        guard self.displayMode == .video, let webView else { return }

        // Use superview frame since that's the actual container size
        let superviewFrame = webView.superview?.frame ?? webView.frame
        let width = Int(superviewFrame.width)
        let height = Int(superviewFrame.height)

        guard width > 0, height > 0 else { return }

        // Update the video UI to ensure everything stays hidden and centered
        let refreshScript = """
            (function() {
                const style = document.getElementById('kaset-video-mode-style-v2');
                if (!style) return { success: false, error: 'no video-mode-style' };

                // Re-apply videoMode property if it drifted
                const playerPage = document.querySelector('ytmusic-player-page');
                if (playerPage && typeof playerPage.videoMode !== 'undefined' && playerPage.videoMode !== true) {
                    playerPage.videoMode = true;
                    if (typeof playerPage.onVideoModeChanged === 'function') {
                        playerPage.onVideoModeChanged();
                    }
                }

                return { success: true };
            })();
        """
        webView.evaluateJavaScript(refreshScript) { result, _ in
            if let dict = result as? [String: Any],
               let success = dict["success"] as? Bool,
               !success
            {
                DiagnosticsLogger.player.debug("Video refresh skipped: no style yet")
            }
        }
    }
}
