import Foundation
import WebKit

@MainActor
extension SingletonPlayerWebView {
    /// Injects a song into YouTube Music's "Up Next" queue by intercepting JSON.stringify
    /// and simulating clicks on the player bar menu. This allows YouTube Music to seamlessly
    /// transition to the target song natively, achieving gapless playback.
    func injectNextSong(videoId: String) {
        guard let webView = self.webView else { return }

        let escapedVideoId = videoId
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        // This script:
        // 1. Intercepts `JSON.stringify` to swap the video ID payload when "Play next" is clicked
        // 2. Clicks the player bar 3-dot menu to open the context menu
        // 3. Finds and clicks the "Play next" button (by SVG path data or text fallback)
        // 4. Dismisses the menu by clicking document.body
        let injectionScript = """
        (function(targetVideoId) {
            // Step 1: Arm the payload interceptor (once per page)
            if (!window.__stringifyIntercepted) {
                const originalStringify = JSON.stringify;
                JSON.stringify = function(value, replacer, space) {
                    if (value && typeof value === 'object' && value.videoIds && Array.isArray(value.videoIds)) {
                        if (window.__targetVideoIdToInject) {
                            console.log('[INJECTOR] Swapping ' + value.videoIds[0] + ' -> ' + window.__targetVideoIdToInject);
                            value.videoIds = [window.__targetVideoIdToInject];
                            window.__targetVideoIdToInject = null;
                        }
                    }
                    return originalStringify(value, replacer, space);
                };
                window.__stringifyIntercepted = true;
            }

            window.__targetVideoIdToInject = targetVideoId;

            // Step 2: Find "Play next" by its SVG icon path
            function fireQueueClick(menuItems) {
                const playNextPathData = "M6 2.86V5H3a1 1 0 00-1 1v12a1 1 0 102 0V7h2v2.137a.5.5 0 00.748.434L13 5.998 6.748 2.426A.5.5 0 006 2.86ZM21 5h-5a1 1 0 100 2h5a1 1 0 100-2Zm0 6H9a1 1 0 000 2h12a1 1 0 000-2Zm0 6H9a1 1 0 000 2h12a1 1 0 000-2Z";
                let targetBtn = null;
                const iconPaths = document.querySelectorAll('path[d="' + playNextPathData + '"]');
                if (iconPaths.length > 0) {
                    targetBtn = iconPaths[0].closest('ytmusic-menu-service-item-renderer');
                }
                if (!targetBtn) {
                    targetBtn = Array.from(menuItems).find(el => el.textContent.toLowerCase().includes('next')) || menuItems[0];
                }
                if (targetBtn) {
                    targetBtn.click();
                }
            }

            // Step 3: Open the player bar 3-dot menu and wait for items to render
            const playerBarMenuBtn = document.querySelector('.middle-controls-buttons.ytmusic-player-bar ytmusic-menu-renderer button');
            if (playerBarMenuBtn) {
                const observer = new MutationObserver((mutations, obs) => {
                    const newMenuItems = document.querySelectorAll('ytmusic-menu-popup-renderer ytmusic-menu-service-item-renderer');
                    if (newMenuItems.length > 0) {
                        obs.disconnect();
                        fireQueueClick(newMenuItems);
                        document.body.click(); // Close the menu
                    }
                });
                observer.observe(document.body, { childList: true, subtree: true });
                playerBarMenuBtn.click();
                // Safety timeout: disconnect observer and close menu if items never rendered
                setTimeout(() => { observer.disconnect(); document.body.click(); }, 2000);
            } else {
                console.log('[INJECTOR] Player bar menu not found — song may not be loaded yet');
                window.__targetVideoIdToInject = null; // Disarm
            }
        })('\(escapedVideoId)');
        """

        self.logger.info("Injecting video \(videoId) into YouTube Music native queue")
        webView.evaluateJavaScript(injectionScript) { _, error in
            if let error {
                self.logger.error("Failed to inject next song: \(error.localizedDescription)")
            }
        }
    }
}
