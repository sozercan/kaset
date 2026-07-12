import Foundation
import WebKit

@MainActor
extension SingletonPlayerWebView {
    /// Cancels any page-side queue injection attempt that has not completed yet.
    func cancelQueueInjection() {
        guard let webView else { return }
        let script = """
        (function() {
            if (typeof window.__kasetCancelQueueInjectionAttempt === 'function') {
                window.__kasetCancelQueueInjectionAttempt();
            }
            window.__kasetQueueInjectionAttemptId = null;
            window.__kasetQueueInjectionReport = null;
            window.__kasetCancelQueueInjectionAttempt = null;
            return 'cancelled';
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Injects a song into YouTube Music's native "Up Next" queue.
    ///
    /// The player-bar **Play next** item already carries a `queueAddEndpoint`. Kaset
    /// temporarily substitutes its queue-target video ID, invokes the menu item's
    /// native click path, and immediately restores the endpoint. The attempt is
    /// trusted only after the visible queue model confirms the expected target after
    /// the source video captured by Swift.
    ///
    /// - Returns: `true` if the injection script was started. Completion is reported
    ///   asynchronously through `QUEUE_INJECTION_RESULT`.
    @discardableResult
    func injectNextSong(
        videoId: String,
        afterVideoId sourceVideoId: String,
        attemptGeneration: Int
    ) -> Bool {
        guard let webView else { return false }

        let injectionScript = Self.queueInjectionScript(
            videoId: videoId,
            afterVideoId: sourceVideoId,
            attemptGeneration: attemptGeneration
        )
        self.logger.info("Injecting video \(videoId) into YouTube Music native queue")
        webView.evaluateJavaScript(injectionScript) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.logger.error("Failed to inject next song: \(error.localizedDescription)")
                self?.coordinator?.playerService.handleWebQueueInjectionResult(
                    videoId: videoId,
                    attemptGeneration: attemptGeneration,
                    success: false,
                    reason: error.localizedDescription
                )
            }
        }
        return true
    }

    // swiftlint:disable:next function_body_length
    nonisolated static func queueInjectionScript(
        videoId: String,
        afterVideoId sourceVideoId: String,
        attemptGeneration: Int = 1
    ) -> String {
        let videoIdLiteral = Self.javaScriptStringLiteral(videoId)
        let sourceVideoIdLiteral = Self.javaScriptStringLiteral(sourceVideoId)
        return """
        (function(targetVideoId, sourceVideoId) {
            const bridge = window.webkit && window.webkit.messageHandlers
                && window.webkit.messageHandlers.singletonPlayer;
            const injectionAttemptId = \(attemptGeneration);
            const documentID = Number(window.__kasetDocumentID || 0);
            const startedAt = Date.now();
            let menuObserver = null;
            let menuWaitTimerId = null;
            let menuTimeoutId = null;
            let verificationTimerId = null;
            let didReport = false;
            let didOpenMenu = false;
            let didDispatchCommand = false;

            if (typeof window.__kasetCancelQueueInjectionAttempt === 'function') {
                window.__kasetCancelQueueInjectionAttempt();
            }

            function clearTimer(timerId) {
                if (timerId !== null) clearTimeout(timerId);
            }

            function clearGlobals() {
                if (window.__kasetQueueInjectionAttemptId !== injectionAttemptId) return;
                window.__kasetQueueInjectionAttemptId = null;
                window.__kasetQueueInjectionReport = null;
                window.__kasetCancelQueueInjectionAttempt = null;
            }

            function dismissPlayerMenu() {
                if (!didOpenMenu) return;
                didOpenMenu = false;
                document.body.click();
            }

            function finishAttempt() {
                clearTimer(menuWaitTimerId);
                clearTimer(menuTimeoutId);
                clearTimer(verificationTimerId);
                menuWaitTimerId = null;
                menuTimeoutId = null;
                verificationTimerId = null;
                if (menuObserver) {
                    menuObserver.disconnect();
                    menuObserver = null;
                }
                dismissPlayerMenu();
                clearGlobals();
            }

            function report(success, reason, reportedVideoId) {
                if (didReport) return;
                didReport = true;
                finishAttempt();
                try {
                    if (bridge) {
                        bridge.postMessage({
                            type: 'QUEUE_INJECTION_RESULT',
                            videoId: reportedVideoId || targetVideoId,
                            attemptGeneration: injectionAttemptId,
                            documentID: documentID,
                            success: !!success,
                            reason: reason || ''
                        });
                    }
                } catch (_) {}
            }

            function cancelAttempt() {
                if (didReport) return;
                didReport = true;
                finishAttempt();
            }

            window.__kasetQueueInjectionAttemptId = injectionAttemptId;
            window.__kasetQueueInjectionReport = report;
            window.__kasetCancelQueueInjectionAttempt = cancelAttempt;

            function collectVideoIds(root) {
                const ids = [];
                const seenObjects = new Set();
                function visit(value, depth) {
                    if (!value || depth > 7 || ids.length >= 40) return;
                    if (typeof value !== 'object') return;
                    if (seenObjects.has(value)) return;
                    seenObjects.add(value);
                    if (Array.isArray(value)) {
                        for (const item of value.slice(0, 100)) visit(item, depth + 1);
                        return;
                    }
                    for (const [key, child] of Object.entries(value)) {
                        if ((key === 'videoId' || key === 'video_id')
                            && typeof child === 'string' && child.length > 0) {
                            if (!ids.includes(child)) ids.push(child);
                        } else if (typeof child === 'object') {
                            visit(child, depth + 1);
                        }
                        if (ids.length >= 40) break;
                    }
                }
                visit(root, 0);
                return ids;
            }

            function queueItemIsCurrent(item) {
                if (item.__kasetIsCurrent === true) return true;
                if (typeof item.hasAttribute === 'function'
                    && (item.hasAttribute('selected')
                        || item.hasAttribute('is-playlist-panel-video-renderer-selected'))) {
                    return true;
                }
                if (typeof item.getAttribute === 'function') {
                    const ariaCurrent = item.getAttribute('aria-current');
                    if (ariaCurrent === 'true' || ariaCurrent === 'page') return true;
                }
                return !!(item.classList && typeof item.classList.contains === 'function'
                    && item.classList.contains('selected'));
            }

            function currentQueueItems() {
                const queueItems = Array.from(document.querySelectorAll(
                    'ytmusic-player-queue-item, ytmusic-player-queue-item-renderer, '
                        + 'ytmusic-player-queue ytmusic-responsive-list-item-renderer'
                ));
                const items = [];
                for (const item of queueItems) {
                    const ids = collectVideoIds(item.data || item.__data || null);
                    if (ids.length > 0) {
                        items.push({ videoId: ids[0], isCurrent: queueItemIsCurrent(item) });
                    }
                }
                return items;
            }

            function queueItemVideoIds(items) {
                return items.map(item => item.videoId);
            }

            function queueOccurrencesMatch(lhs, rhs) {
                return lhs.length === rhs.length
                    && lhs.every((videoId, index) => videoId === rhs[index]);
            }

            function hasExpectedNextOccurrence(items) {
                const currentIndex = items.findIndex(item => item.isCurrent);
                if (currentIndex < 0) return false;
                return items[currentIndex].videoId === sourceVideoId
                    && !!items[currentIndex + 1]
                    && items[currentIndex + 1].videoId === targetVideoId;
            }

            function currentPlayerVideoId() {
                const ytmusicPlayer = document.querySelector('ytmusic-player');
                if (ytmusicPlayer && ytmusicPlayer.playerApi
                    && typeof ytmusicPlayer.playerApi.getVideoData === 'function') {
                    const data = ytmusicPlayer.playerApi.getVideoData();
                    const videoId = data && (data.video_id || data.videoId);
                    if (videoId) return videoId;
                }
                const moviePlayer = document.getElementById('movie_player');
                if (moviePlayer && typeof moviePlayer.getVideoData === 'function') {
                    const data = moviePlayer.getVideoData();
                    const videoId = data && (data.video_id || data.videoId);
                    if (videoId) return videoId;
                }
                return '';
            }

            function findPlayNextItem(menuItems) {
                const playNextPathData = "M6 2.86V5H3a1 1 0 00-1 1v12a1 1 0 102 0V7h2v2.137a.5.5 0 00.748.434L13 5.998 6.748 2.426A.5.5 0 006 2.86ZM21 5h-5a1 1 0 100 2h5a1 1 0 100-2Zm0 6H9a1 1 0 000 2h12a1 1 0 000-2Zm0 6H9a1 1 0 000 2h12a1 1 0 000-2Z";
                const iconItem = Array.from(menuItems).find(item =>
                    typeof item.querySelector === 'function'
                        && item.querySelector('path[d="' + playNextPathData + '"]')
                );
                if (iconItem) return iconItem;
                return Array.from(menuItems).find(item => {
                    const text = (item.textContent || '').toLowerCase();
                    const ariaLabel = (item.getAttribute('aria-label') || '').toLowerCase();
                    return text.includes('next') || ariaLabel.includes('next');
                }) || null;
            }

            function dispatchVerifiedQueueClick(menuItems) {
                if (window.__kasetQueueInjectionAttemptId !== injectionAttemptId) return false;
                const targetItem = findPlayNextItem(menuItems);
                if (!targetItem) {
                    report(false, 'play-next-item-not-found');
                    return false;
                }

                const targetData = targetItem.data || targetItem.__data || null;
                const serviceEndpoint = targetData
                    && (targetData.serviceEndpoint || targetData.navigationEndpoint || targetData.endpoint);
                const queueAddEndpoint = serviceEndpoint && serviceEndpoint.queueAddEndpoint;
                const queueTarget = queueAddEndpoint && queueAddEndpoint.queueTarget;
                if (!queueAddEndpoint
                    || !queueTarget
                    || typeof queueTarget.videoId !== 'string'
                    || typeof targetItem.click !== 'function') {
                    report(false, 'play-next-endpoint-unavailable');
                    return false;
                }
                const activeVideoId = currentPlayerVideoId();
                if (activeVideoId && activeVideoId !== sourceVideoId) {
                    report(false, 'source-video-changed');
                    return false;
                }
                if (queueTarget.videoId !== sourceVideoId) {
                    dismissPlayerMenu();
                    if (Date.now() - startedAt < 8000) {
                        menuWaitTimerId = setTimeout(openPlayerBarMenuWhenReady, 100);
                    } else {
                        report(false, 'menu-source-mismatch');
                    }
                    return false;
                }
                const queueItemsBeforeClick = currentQueueItems();
                if (hasExpectedNextOccurrence(queueItemsBeforeClick)) {
                    dismissPlayerMenu();
                    report(true, 'queue-readback-confirmed', targetVideoId);
                    return true;
                }
                if (queueItemsBeforeClick[0]
                    && !queueItemsBeforeClick[0].isCurrent
                    && queueItemsBeforeClick[0].videoId === sourceVideoId
                    && queueItemsBeforeClick[1]
                    && queueItemsBeforeClick[1].videoId === targetVideoId) {
                    report(false, 'queue-readback-ambiguous');
                    return false;
                }

                didDispatchCommand = true;
                const queueOccurrencesBeforeClick = queueItemVideoIds(queueItemsBeforeClick);
                const onEmptyWatchEndpoint = queueTarget.onEmptyQueue
                    && queueTarget.onEmptyQueue.watchEndpoint;
                const originalTargetVideoId = queueTarget.videoId;
                const originalOnEmptyVideoId = onEmptyWatchEndpoint
                    && onEmptyWatchEndpoint.videoId;

                function restoreEndpoint() {
                    queueTarget.videoId = originalTargetVideoId;
                    if (onEmptyWatchEndpoint) {
                        onEmptyWatchEndpoint.videoId = originalOnEmptyVideoId;
                    }
                }

                queueTarget.videoId = targetVideoId;
                if (onEmptyWatchEndpoint) {
                    onEmptyWatchEndpoint.videoId = targetVideoId;
                }

                try {
                    targetItem.click();
                } catch (_) {
                    restoreEndpoint();
                    report(false, 'play-next-click-threw');
                    return false;
                }
                setTimeout(restoreEndpoint, 0);
                dismissPlayerMenu();

                const verificationStartedAt = Date.now();
                function verifyQueuedTarget() {
                    if (didReport || window.__kasetQueueInjectionAttemptId !== injectionAttemptId) {
                        return;
                    }
                    const items = currentQueueItems();
                    const ids = queueItemVideoIds(items);
                    const queueChanged = !queueOccurrencesMatch(
                        queueOccurrencesBeforeClick,
                        ids
                    );
                    const activeVideoIdAfterClick = currentPlayerVideoId();
                    if (activeVideoIdAfterClick && activeVideoIdAfterClick !== sourceVideoId) {
                        report(false, 'source-video-changed-before-readback');
                        return;
                    }
                    if (queueChanged && hasExpectedNextOccurrence(items)) {
                        report(true, 'queue-readback-confirmed', targetVideoId);
                        return;
                    }
                    if (Date.now() - verificationStartedAt >= 6000) {
                        report(false, 'queue-readback-timeout');
                        return;
                    }
                    verificationTimerId = setTimeout(verifyQueuedTarget, 100);
                }
                verificationTimerId = setTimeout(verifyQueuedTarget, 0);
                return true;
            }

            function findPlayerBarMenuButton() {
                const menuRendererButton = document.querySelector(
                    '.middle-controls-buttons.ytmusic-player-bar ytmusic-menu-renderer button'
                );
                if (menuRendererButton) return menuRendererButton;

                // Compatibility fallback for the newer player-bar button shape.
                return Array.from(document.querySelectorAll('ytmusic-player-bar button')).find(button =>
                    (button.getAttribute('aria-label') || '').toLowerCase() === 'action menu'
                ) || null;
            }

            function openPlayerBarMenuWhenReady() {
                if (didReport || window.__kasetQueueInjectionAttemptId !== injectionAttemptId) return;
                const playerBarMenuButton = findPlayerBarMenuButton();
                if (!playerBarMenuButton) {
                    if (Date.now() - startedAt < 8000) {
                        menuWaitTimerId = setTimeout(openPlayerBarMenuWhenReady, 100);
                    } else {
                        report(false, 'player-bar-menu-not-found');
                    }
                    return;
                }

                function tryDispatchFromMenu() {
                    if (didReport || didDispatchCommand
                        || window.__kasetQueueInjectionAttemptId !== injectionAttemptId) {
                        return;
                    }
                    const menuItems = document.querySelectorAll(
                        'ytmusic-menu-popup-renderer ytmusic-menu-service-item-renderer'
                    );
                    if (menuItems.length === 0) return;
                    if (menuObserver) {
                        menuObserver.disconnect();
                        menuObserver = null;
                    }
                    clearTimer(menuTimeoutId);
                    menuTimeoutId = null;
                    dispatchVerifiedQueueClick(menuItems);
                }

                menuObserver = new MutationObserver(() => tryDispatchFromMenu());
                menuObserver.observe(document.body, { childList: true, subtree: true });
                didOpenMenu = true;
                menuTimeoutId = setTimeout(() => {
                    if (didReport) return;
                    report(false, 'menu-timeout');
                }, 5000);
                playerBarMenuButton.click();
                // Menus can stay mounted between SPA navigations and only toggle
                // visibility, producing no child-list mutation.
                setTimeout(tryDispatchFromMenu, 0);
            }

            openPlayerBarMenuWhenReady();
        })(\(videoIdLiteral), \(sourceVideoIdLiteral));
        """
    }
}
