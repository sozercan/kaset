import Foundation

extension YouTubeWatchWebView {
    /// Document-start state handed to each new watch page.
    ///
    /// `documentGeneration` scopes bridge messages to this page. `pendingSeek`,
    /// when present, is a resume position (seconds) applied by the observer once
    /// the `<video>` element exists and is seekable (see `applyPendingSeek` in the
    /// observer script). Injected at document start so both values are in place
    /// before the player boots and naturally scoped to this one navigation.
    nonisolated static func pageBootstrapScript(
        targetVolume: Double,
        documentGeneration _: UInt64,
        pendingSeek: Double? = nil,
        pendingSeekVideoId: String? = nil,
        pendingSeekAttemptID: UInt64? = nil
    ) -> String {
        let clamped = targetVolume.isFinite ? min(max(targetVolume, 0), 1) : 1.0
        var script = """
        (function() {
            try {
                const queryGeneration = new URLSearchParams(window.location.search)
                    .get('\(WebPlaybackDocumentGeneration.urlQueryKey)');
                const fragmentGeneration = new URLSearchParams(
                    window.location.hash.replace(/^#/, '')
                ).get('\(WebPlaybackDocumentGeneration.urlQueryKey)');
                const rawGeneration = queryGeneration || fragmentGeneration;
                const parsedGeneration = rawGeneration === null || rawGeneration === ''
                    ? Number.NaN
                    : Number(rawGeneration);
                window.__kasetDocumentGeneration =
                    Number.isSafeInteger(parsedGeneration) && parsedGeneration >= 0
                        ? parsedGeneration
                        : -1;
            } catch (e) {
                window.__kasetDocumentGeneration = -1;
            }
        })();
        window.__kasetTargetVolume = \(clamped);
        window.__kasetNativePausePending = false;
        \(Self.documentStartAudioGuardScript(targetVolume: clamped))
        """
        if let pendingSeek, pendingSeek.isFinite, pendingSeek >= 0 {
            let attemptID = pendingSeekAttemptID ?? 1
            script += " window.__kasetPendingSeek = \(pendingSeek); window.__kasetPendingSeekWaits = 0; window.__kasetPendingSeekApplied = false; window.__kasetPendingSeekFailed = false; window.__kasetPendingSeekAttempt = \(attemptID); window.__kasetPendingSeekInFlightAttempt = null;"
            if let pendingSeekVideoId {
                let literal = WebPlaybackDocumentGeneration.javaScriptStringLiteral(pendingSeekVideoId)
                script += " window.__kasetPendingSeekVideoId = \(literal);"
            }
        }
        return script
    }

    // swiftlint:disable function_body_length
    /// Installs an audio gate before YouTube creates or autoplays its media.
    ///
    /// Merely storing `__kasetTargetVolume` at document start leaves a race: a
    /// newly created video can begin at YouTube's persisted volume before the
    /// document-end observer attaches. This gate applies the target at the
    /// `HTMLMediaElement.play()` boundary, covers native autoplay via capture
    /// listeners, and immediately protects replacement media elements.
    nonisolated static func documentStartAudioGuardScript(targetVolume: Double) -> String {
        let clamped = targetVolume.isFinite ? min(max(targetVolume, 0), 1) : 1.0
        return """
        (function() {
            'use strict';
            window.__kasetTargetVolume = \(clamped);

            function resolvedTarget() {
                const target = window.__kasetTargetVolume;
                return typeof target === 'number' && Number.isFinite(target)
                    ? Math.min(Math.max(target, 0), 1)
                    : 1;
            }

            function applyPlayerTarget(target) {
                const player = document.getElementById('movie_player');
                if (!player) { return; }

                const percent = Math.round(target * 100);
                const lastTarget = window.__kasetLastAppliedPlayerVolume;
                let volumeMismatch = lastTarget !== target;
                if (typeof player.getVolume === 'function') {
                    try {
                        const currentVolume = Number(player.getVolume());
                        if (Number.isFinite(currentVolume)) {
                            volumeMismatch = Math.abs(currentVolume - percent) > 1;
                        }
                    } catch (e) {}
                }

                let muteMismatch = lastTarget !== target;
                if (typeof player.isMuted === 'function') {
                    try {
                        const currentMuted = player.isMuted();
                        if (typeof currentMuted === 'boolean') {
                            muteMismatch = currentMuted !== (target <= 0);
                        }
                    } catch (e) {}
                }

                try {
                    if (target <= 0 && muteMismatch && typeof player.mute === 'function') {
                        player.mute();
                    }
                    if (volumeMismatch && typeof player.setVolume === 'function') {
                        player.setVolume(percent);
                    }
                    if (target > 0 && muteMismatch && typeof player.unMute === 'function') {
                        player.unMute();
                    }
                    window.__kasetLastAppliedPlayerVolume = target;
                } catch (e) {}
            }

            function applyTarget(media) {
                if (!media || typeof media.volume !== 'number') { return; }
                const target = resolvedTarget();
                try {
                    if (target <= 0) {
                        // Mute first so lowering volume can never expose an audible frame.
                        if (!media.muted) { media.muted = true; }
                        if (Math.abs(media.volume) > 0.001) { media.volume = 0; }
                    } else {
                        // Set the requested level before unmuting for the same reason.
                        if (Math.abs(media.volume - target) > 0.001) { media.volume = target; }
                        if (media.muted) { media.muted = false; }
                    }
                } catch (e) {}
                applyPlayerTarget(target);
            }

            function applyNode(node) {
                if (!node) { return; }
                if (typeof HTMLMediaElement !== 'undefined' && node instanceof HTMLMediaElement) {
                    applyTarget(node);
                }
                if (typeof node.querySelectorAll === 'function') {
                    node.querySelectorAll('video, audio').forEach(applyTarget);
                }
            }

            window.__kasetApplyTargetVolume = applyTarget;
            window.__kasetApplyTargetVolumeToAllMedia = function() {
                if (typeof document.querySelectorAll === 'function') {
                    document.querySelectorAll('video, audio').forEach(applyTarget);
                }
                applyPlayerTarget(resolvedTarget());
            };

            const mediaPrototype = typeof HTMLMediaElement !== 'undefined'
                ? HTMLMediaElement.prototype
                : null;
            function guardMediaAccessor(name, marker, valueForTarget) {
                if (!mediaPrototype
                    || Object.prototype.hasOwnProperty.call(mediaPrototype, marker)) {
                    return;
                }

                const descriptor = Object.getOwnPropertyDescriptor(mediaPrototype, name);
                if (!descriptor || !descriptor.configurable
                    || typeof descriptor.get !== 'function'
                    || typeof descriptor.set !== 'function') {
                    return;
                }

                try {
                    Object.defineProperty(mediaPrototype, name, {
                        configurable: descriptor.configurable,
                        enumerable: descriptor.enumerable,
                        get: descriptor.get,
                        set: function() {
                            const target = resolvedTarget();
                            descriptor.set.call(this, valueForTarget(target));
                        }
                    });
                    Object.defineProperty(mediaPrototype, marker, {
                        configurable: true,
                        value: descriptor
                    });
                } catch (e) {}
            }
            guardMediaAccessor(
                'volume',
                '__kasetOriginalVolumeDescriptor',
                function(target) { return target; }
            );
            guardMediaAccessor(
                'muted',
                '__kasetOriginalMutedDescriptor',
                function(target) { return target <= 0; }
            );

            if (mediaPrototype && typeof mediaPrototype.play === 'function'
                && !mediaPrototype.__kasetOriginalPlay) {
                const originalPlay = mediaPrototype.play;
                try {
                    Object.defineProperty(mediaPrototype, '__kasetOriginalPlay', {
                        configurable: true,
                        value: originalPlay
                    });
                    mediaPrototype.play = function() {
                        applyTarget(this);
                        return originalPlay.apply(this, arguments);
                    };
                } catch (e) {}
            }

            if (typeof document.addEventListener === 'function') {
                ['play', 'playing', 'loadedmetadata', 'canplay', 'volumechange'].forEach(function(name) {
                    document.addEventListener(name, function(event) {
                        applyTarget(event.target);
                    }, true);
                });
            }

            if (typeof MutationObserver === 'function' && document.documentElement) {
                const audioObserver = new MutationObserver(function(records) {
                    records.forEach(function(record) {
                        if (!record.addedNodes) { return; }
                        record.addedNodes.forEach(applyNode);
                    });
                    applyPlayerTarget(resolvedTarget());
                });
                audioObserver.observe(document.documentElement, { childList: true, subtree: true });
                window.__kasetAudioGuardObserver = audioObserver;
            }

            window.__kasetApplyTargetVolumeToAllMedia();
        })();
        """
    }

    // swiftlint:enable function_body_length

    nonisolated static func watchURL(videoId: String, documentGeneration: UInt64) -> URL? {
        var components = URLComponents(string: "https://www.youtube.com/watch")
        components?.queryItems = [
            URLQueryItem(name: "v", value: videoId),
            URLQueryItem(
                name: WebPlaybackDocumentGeneration.urlQueryKey,
                value: String(documentGeneration)
            ),
        ]
        components?.fragment = "\(WebPlaybackDocumentGeneration.urlQueryKey)=\(documentGeneration)"
        return components?.url
    }

    nonisolated static func userScriptDocumentGeneration(
        from documentGeneration: WebPlaybackDocumentGeneration
    ) -> UInt64 {
        documentGeneration.userScriptGeneration
    }

    nonisolated static func acceptsBridgeMessage(
        sourceWebView: AnyObject?,
        currentWebView: AnyObject?,
        documentGeneration: WebPlaybackDocumentGeneration,
        rawDocumentGeneration: Any?
    ) -> Bool {
        guard let sourceWebView,
              let currentWebView,
              sourceWebView === currentWebView
        else { return false }
        return documentGeneration.accepts(rawGeneration: rawDocumentGeneration)
    }

    nonisolated static func acceptsBridgeSource(
        isMainFrame: Bool,
        sourceScheme: String,
        sourceHost: String
    ) -> Bool {
        isMainFrame && sourceScheme == "https" && sourceHost == "www.youtube.com"
    }

    nonisolated static func acceptsMainFrameResponse(
        _ response: URLResponse,
        expectedVideoID: String?,
        documentGeneration: WebPlaybackDocumentGeneration
    ) -> Bool {
        WebPlaybackDocumentGeneration.acceptsMainFrameResponse(
            response,
            expectedHost: "www.youtube.com",
            expectedVideoID: expectedVideoID,
            allowsInternalBlank: documentGeneration.ownsBlankNavigation(response.url)
        )
    }
}
