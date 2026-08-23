import Foundation

// MARK: - SingletonPlayerWebView Media Controls

extension SingletonPlayerWebView {
    /// Updates the current page and the bootstrap state used by future page loads.
    func setMediaControlStyle(useNextPrev: Bool) {
        self.mediaControlUsesNextPrev = useNextPrev
        self.refreshInstalledUserScripts()

        guard let webView = self.webView else { return }
        let script = Self.mediaControlStyleSyncScript(useNextPrev: useNextPrev)
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func mediaControlBootstrapScript() -> String {
        Self.mediaControlStyleBootstrapScript(useNextPrev: self.mediaControlUsesNextPrev)
    }

    /// Re-asserts Kaset's `nexttrack`/`previoustrack` media-session override immediately.
    ///
    /// The document-start `setActionHandler` wrapper keeps YouTube from overwriting
    /// Kaset-owned next/previous handlers, so normal operation relies on bounded
    /// event-driven refreshes instead of a steady animation-frame loop.
    func reassertMediaControlOverride() {
        guard self.mediaControlUsesNextPrev, let webView = self.webView else { return }
        webView.evaluateJavaScript(
            "if (typeof window.__kasetRefreshMediaControlStyle === 'function') { window.__kasetRefreshMediaControlStyle(); }",
            completionHandler: nil
        )
    }

    /// Performs a bounded re-assertion when the app enters the background.
    ///
    /// YouTube handler writes are blocked by the document-start wrapper while Kaset owns
    /// next/previous, so no steady background timer is needed.
    func beginBackgroundMediaControlReassertion() {
        guard self.mediaControlUsesNextPrev else { return }
        self.reassertMediaControlOverride()
        self.mediaControlReassertTimer?.invalidate()
        self.mediaControlReassertTimer = nil
    }

    /// Clears any legacy background re-assertion timer.
    func endBackgroundMediaControlReassertion() {
        self.mediaControlReassertTimer?.invalidate()
        self.mediaControlReassertTimer = nil
    }

    static func mediaControlStyleBootstrapScript(useNextPrev: Bool) -> String {
        let jsBoolean = useNextPrev ? "true" : "false"
        return """
            (function() {
                try {
                    localStorage.setItem('kasetUseNextPrev', '\(jsBoolean)');
                } catch (e) {}
                window.__kasetUseNextPrev = \(jsBoolean);
                // Wrap setActionHandler at document start so YouTube registrations cannot
                // steal remote-command ownership. Seek handlers always stay native-owned;
                // next/previous stay Kaset-owned in nextPrev mode unless Kaset is installing
                // its own handlers under the temporary install flag.
                try {
                    if (typeof window.__kasetInstallingMediaControlHandlers !== 'boolean') {
                        window.__kasetInstallingMediaControlHandlers = false;
                    }
                    var ms = navigator.mediaSession;
                    if (ms && !ms.__kasetSetActionHandlerWrapped) {
                        var orig = ms.setActionHandler.bind(ms);
                        ms.setActionHandler = function(type, handler) {
                            var isSeekSkip = type === 'seekforward' || type === 'seekbackward';
                            var isNextPrevious = type === 'nexttrack' || type === 'previoustrack';
                            if (isSeekSkip) {
                                return orig(type, null);
                            }
                            if (isNextPrevious) {
                                if (window.__kasetUseNextPrev) {
                                    if (!window.__kasetInstallingMediaControlHandlers) {
                                        return undefined;
                                    }
                                } else {
                                    return orig(type, null);
                                }
                            }
                            return orig(type, handler);
                        };
                        ms.__kasetSetActionHandlerWrapped = true;
                    }
                } catch (e) {}
            })();
        """
    }

    static func mediaControlStyleSyncScript(useNextPrev: Bool) -> String {
        let jsBoolean = useNextPrev ? "true" : "false"
        let clearWebViewSkipHandlers = if useNextPrev {
            ""
        } else {
            """
                try {
                    var ms = navigator.mediaSession;
                    ms.setActionHandler('nexttrack', null);
                    ms.setActionHandler('previoustrack', null);
                    ms.setActionHandler('seekforward', null);
                    ms.setActionHandler('seekbackward', null);
                } catch (e) {}
            """
        }

        return """
            (function() {
                try {
                    localStorage.setItem('kasetUseNextPrev', '\(jsBoolean)');
                } catch (e) {}
                window.__kasetUseNextPrev = \(jsBoolean);
                if (typeof window.__kasetRefreshMediaControlStyle === 'function') {
                    window.__kasetRefreshMediaControlStyle();
                }
                \(clearWebViewSkipHandlers)
            })();
        """
    }

    static var mediaControlOverrideScript: String {
        """
        (function() {
            \(eventTimestampFunctionJS)
            if (typeof window.__kasetUseNextPrev !== 'boolean') {
                try {
                    window.__kasetUseNextPrev =
                        localStorage.getItem('kasetUseNextPrev') === 'true';
                } catch (e) {
                    window.__kasetUseNextPrev = false;
                }
            }

            function withKasetMediaControlInstall(action) {
                var previousFlag = window.__kasetInstallingMediaControlHandlers === true;
                window.__kasetInstallingMediaControlHandlers = true;
                try {
                    action();
                } finally {
                    window.__kasetInstallingMediaControlHandlers = previousFlag;
                }
            }

            function applyOverride() {
                if (!window.__kasetUseNextPrev) {
                    return;
                }
                try {
                    var ms = navigator.mediaSession;
                    withKasetMediaControlInstall(function() {
                        ms.setActionHandler('seekforward', null);
                        ms.setActionHandler('seekbackward', null);
                        ms.setActionHandler('nexttrack', function() {
                            window.webkit.messageHandlers.singletonPlayer
                                .postMessage({
                                    type: 'REMOTE_NEXT',
                                    documentGeneration: window.__kasetDocumentGeneration,
                                    commandIssuedAtMilliseconds: __kasetEventTimestampMilliseconds()
                                });
                        });
                        ms.setActionHandler('previoustrack', function() {
                            window.webkit.messageHandlers.singletonPlayer
                                .postMessage({
                                    type: 'REMOTE_PREVIOUS',
                                    documentGeneration: window.__kasetDocumentGeneration,
                                    commandIssuedAtMilliseconds: __kasetEventTimestampMilliseconds()
                                });
                        });
                    });
                } catch (e) {}
            }

            window.__kasetRefreshMediaControlStyle = function() {
                applyOverride();
            };

            window.__kasetRefreshMediaControlStyle();

            // Re-apply on bounded page lifecycle events where YouTube recreates the player.
            function attachVideoOverride() {
                var v = document.querySelector('video');
                if (!v || v.__kasetOverrideAttached) return;
                v.__kasetOverrideAttached = true;
                ['playing','loadedmetadata','loadeddata','canplay','seeked']
                    .forEach(function(e) { v.addEventListener(e, applyOverride); });
                applyOverride();
            }

            attachVideoOverride();
            new MutationObserver(attachVideoOverride)
                .observe(document.documentElement, {childList:true, subtree:true});
        })();
        """
    }

    // MARK: - Playback Audio Quality

    /// Updates the current page and the bootstrap state used by future page loads.
    func setPlaybackAudioQuality(_ quality: SettingsManager.PlaybackAudioQuality) {
        self.playbackAudioQuality = quality
        self.refreshInstalledUserScripts()

        guard let webView = self.webView else { return }
        let script = Self.playbackAudioQualitySyncScript(quality: quality)
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func playbackAudioQualityBootstrapScript() -> String {
        Self.playbackAudioQualityBootstrapScript(quality: self.playbackAudioQuality)
    }
}
