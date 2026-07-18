import WebKit

extension YouTubeWatchWebView {
    private var activePlaybackVideoId: String? {
        self.coordinator?.playerService.currentVideo?.videoId ?? self.currentVideoId
    }

    func pendingSeekForActiveNavigation() -> Double? {
        let generation = self.documentGeneration.pendingGeneration
            ?? self.documentGeneration.inFlightGeneration
            ?? self.documentGeneration.currentGeneration
        return Self.recoverySeek(
            candidate: self.pendingSeeksByGeneration[generation],
            candidateVideoId: self.pendingSeekVideoIdsByGeneration[generation],
            activeVideoId: self.activePlaybackVideoId
        )
    }

    nonisolated static func recoverySeek(
        candidate: Double?,
        candidateVideoId: String?,
        activeVideoId: String?
    ) -> Double? {
        guard let activeVideoId, candidateVideoId == activeVideoId else { return nil }
        return candidate
    }

    @discardableResult
    func beginPendingSeekAttempt(generation: UInt64) -> UInt64 {
        self.nextPendingSeekAttemptID &+= 1
        self.pendingSeekAttemptIDsByGeneration[generation] = self.nextPendingSeekAttemptID
        self.cancelledPendingSeekGenerations.remove(generation)
        return self.nextPendingSeekAttemptID
    }

    @discardableResult
    func completePendingSeek(
        generation: UInt64,
        attemptID: UInt64,
        target: Double? = nil,
        videoId: String? = nil
    ) -> Bool {
        guard let currentTarget = self.pendingSeeksByGeneration[generation] else { return false }
        guard self.pendingSeekAttemptIDsByGeneration[generation] == attemptID else { return false }
        if let target,
           currentTarget != target
        {
            return false
        }
        let currentVideoId = self.pendingSeekVideoIdsByGeneration[generation]
        if let videoId, currentVideoId != videoId {
            return false
        }
        self.pendingSeeksByGeneration.removeValue(forKey: generation)
        self.pendingSeekVideoIdsByGeneration.removeValue(forKey: generation)
        self.pendingSeekAttemptIDsByGeneration.removeValue(forKey: generation)
        self.pendingSeekRetryCounts.removeValue(forKey: generation)
        self.directSeekGenerations.remove(generation)
        if self.pendingSeek == currentTarget {
            self.pendingSeek = nil
        }
        for (key, var navigation) in self.documentNavigations
            where navigation.generation == generation
        {
            navigation.pendingSeek = nil
            self.documentNavigations[key] = navigation
        }
        if let webView = self.webView {
            webView.evaluateJavaScript(
                Self.pendingSeekCompletionScript(
                    documentGeneration: generation,
                    attemptID: attemptID,
                    target: currentTarget,
                    videoId: currentVideoId
                ),
                completionHandler: nil
            )
        }
        return true
    }

    func seekWithRecovery(to seconds: Double) {
        self.pendingSeek = seconds
        let generation = self.documentGeneration.pendingGeneration
            ?? self.documentGeneration.inFlightGeneration
            ?? self.documentGeneration.currentGeneration
        self.pendingSeeksByGeneration[generation] = seconds
        let videoId = self.coordinator?.playerService.currentVideo?.videoId ?? self.currentVideoId
        if let videoId {
            self.pendingSeekVideoIdsByGeneration[generation] = videoId
        }
        self.directSeekGenerations.insert(generation)
        self.pendingSeekRetryCounts[generation] = 0
        self.beginPendingSeekAttempt(generation: generation)
        for (key, var navigation) in self.documentNavigations
            where navigation.generation == generation
        {
            navigation.pendingSeek = seconds
            self.documentNavigations[key] = navigation
        }
        guard let webView = self.webView else { return }
        if self.documentGeneration.pendingGeneration != nil
            || self.documentGeneration.inFlightGeneration != nil
        {
            let targetVolume = self.coordinator?.playerService.volume ?? 1.0
            self.installUserScripts(
                on: webView.configuration.userContentController,
                targetVolume: targetVolume,
                documentGeneration: generation,
                pendingSeek: seconds,
                pendingSeekVideoId: self.pendingSeekVideoIdsByGeneration[generation],
                pendingSeekAttemptID: self.pendingSeekAttemptIDsByGeneration[generation]
            )
        }
        guard let attemptID = self.pendingSeekAttemptIDsByGeneration[generation] else { return }
        let videoIdLiteral = WebPlaybackDocumentGeneration.javaScriptStringLiteral(
            self.pendingSeekVideoIdsByGeneration[generation]
        )
        webView.evaluateJavaScript(
            Self.seekWithRecoveryScript(
                documentGeneration: generation,
                target: seconds,
                videoIdLiteral: videoIdLiteral,
                attemptID: attemptID
            ),
            completionHandler: nil
        )
    }

    nonisolated static func seekWithRecoveryScript(
        documentGeneration: UInt64,
        target: Double,
        videoIdLiteral: String,
        attemptID: UInt64
    ) -> String {
        """
        (function() {
            if (window.__kasetDocumentGeneration !== \(documentGeneration)) { return false; }
            window.__kasetPendingSeek = \(target);
            window.__kasetPendingSeekVideoId = \(videoIdLiteral);
            window.__kasetPendingSeekWaits = 0;
            window.__kasetPendingSeekApplied = false;
            window.__kasetPendingSeekFailed = false;
            window.__kasetPendingSeekAttempt = \(attemptID);
            window.__kasetPendingSeekInFlightAttempt = null;

            const video = document.querySelector('video');
            const player = document.getElementById('movie_player');
            const isAd = !!(player && player.classList && player.classList.contains('ad-showing'));
            const expectedVideoId = \(videoIdLiteral);
            if (isAd || !video || video.readyState < 1 || !video.currentSrc) { return 'armed'; }
            if (expectedVideoId && (video.__kasetBoundVideoId || '') !== expectedVideoId) { return 'armed'; }
            if (!video.seekable || video.seekable.length === 0) { return 'armed'; }
            video.currentTime = \(target);
            return 'seeked';
        })();
        """
    }

    func cancelPendingRecoverySeek() {
        let generations = Set([
            self.documentGeneration.currentGeneration,
            self.documentGeneration.inFlightGeneration,
            self.documentGeneration.pendingGeneration,
        ].compactMap(\.self))
        let provisionalGenerations = Set([
            self.documentGeneration.inFlightGeneration,
            self.documentGeneration.pendingGeneration,
        ].compactMap(\.self))
        self.cancelledPendingSeekGenerations.formUnion(provisionalGenerations)

        self.pendingSeek = nil
        self.pendingSeeksByGeneration.removeAll()
        self.pendingSeekVideoIdsByGeneration.removeAll()
        self.pendingSeekAttemptIDsByGeneration.removeAll()
        self.pendingSeekRetryCounts.removeAll()
        self.directSeekGenerations.removeAll()
        for (key, var navigation) in self.documentNavigations {
            navigation.pendingSeek = nil
            self.documentNavigations[key] = navigation
        }

        guard let webView = self.webView else { return }
        for generation in generations {
            webView.evaluateJavaScript(
                Self.pendingSeekCancellationScript(documentGeneration: generation),
                completionHandler: nil
            )
        }
    }

    nonisolated static func pendingSeekCancellationScript(documentGeneration: UInt64) -> String {
        """
        (function() {
            if (window.__kasetDocumentGeneration !== \(documentGeneration)) { return false; }
            window.__kasetPendingSeek = null;
            window.__kasetPendingSeekVideoId = null;
            window.__kasetPendingSeekWaits = 0;
            window.__kasetPendingSeekApplied = false;
            window.__kasetPendingSeekFailed = false;
            window.__kasetPendingSeekResultTarget = null;
            window.__kasetPendingSeekResultVideoId = null;
            window.__kasetPendingSeekAttempt = (window.__kasetPendingSeekAttempt || 0) + 1;
            window.__kasetPendingSeekInFlightAttempt = null;
            return true;
        })();
        """
    }

    nonisolated static func pendingSeekCompletionScript(
        documentGeneration: UInt64,
        attemptID: UInt64,
        target: Double,
        videoId: String?
    ) -> String {
        let videoIdLiteral = WebPlaybackDocumentGeneration.javaScriptStringLiteral(videoId)
        return """
        (function() {
            if (window.__kasetDocumentGeneration !== \(documentGeneration)) { return false; }
            if (window.__kasetPendingSeekAttempt !== \(attemptID)) { return false; }
            if (window.__kasetPendingSeek !== \(target)) { return false; }
            if (window.__kasetPendingSeekVideoId !== \(videoIdLiteral)) { return false; }
            window.__kasetPendingSeek = null;
            window.__kasetPendingSeekVideoId = null;
            window.__kasetPendingSeekWaits = 0;
            window.__kasetPendingSeekApplied = false;
            window.__kasetPendingSeekFailed = false;
            window.__kasetPendingSeekResultTarget = null;
            window.__kasetPendingSeekResultVideoId = null;
            window.__kasetPendingSeekAttempt = (window.__kasetPendingSeekAttempt || 0) + 1;
            window.__kasetPendingSeekInFlightAttempt = null;
            return true;
        })();
        """
    }

    @discardableResult
    func retryPendingSeek(
        generation: UInt64,
        target acknowledgedTarget: Double,
        videoId acknowledgedVideoId: String,
        attemptID acknowledgedAttemptID: UInt64
    ) -> Bool {
        guard self.pendingSeekVideoIdsByGeneration[generation] == acknowledgedVideoId,
              self.pendingSeekAttemptIDsByGeneration[generation] == acknowledgedAttemptID,
              acknowledgedVideoId == self.activePlaybackVideoId,
              let target = self.pendingSeeksByGeneration[generation],
              target == acknowledgedTarget
        else {
            return false
        }
        let retryCount = (self.pendingSeekRetryCounts[generation] ?? 0) + 1
        guard retryCount <= 3 else {
            self.completePendingSeek(
                generation: generation,
                attemptID: acknowledgedAttemptID,
                target: target,
                videoId: acknowledgedVideoId
            )
            return true
        }
        self.pendingSeekRetryCounts[generation] = retryCount
        self.beginPendingSeekAttempt(generation: generation)
        self.injectPendingSeekIfNeeded(generation: generation)
        return false
    }

    func injectPendingSeekIfNeeded(generation: UInt64, webView: WKWebView? = nil) {
        guard let target = self.pendingSeeksByGeneration[generation],
              let targetWebView = webView ?? self.webView
        else { return }
        let videoIdLiteral = WebPlaybackDocumentGeneration.javaScriptStringLiteral(
            self.pendingSeekVideoIdsByGeneration[generation]
        )
        guard let attemptID = self.pendingSeekAttemptIDsByGeneration[generation] else { return }
        targetWebView.evaluateJavaScript("""
            if (window.__kasetDocumentGeneration === \(generation)) {
                window.__kasetPendingSeek = \(target);
                window.__kasetPendingSeekVideoId = \(videoIdLiteral);
                window.__kasetPendingSeekWaits = 0;
                window.__kasetPendingSeekApplied = false;
                window.__kasetPendingSeekFailed = false;
                window.__kasetPendingSeekAttempt = \(attemptID);
                window.__kasetPendingSeekInFlightAttempt = null;
            }
        """, completionHandler: nil)
    }

    func discardPendingSeekIfActiveVideoChanged(generation: UInt64) {
        guard let expectedVideoId = self.pendingSeekVideoIdsByGeneration[generation],
              Self.shouldDiscardPendingSeek(
                  expectedVideoId: expectedVideoId,
                  activeVideoId: self.activePlaybackVideoId
              )
        else { return }
        self.completePendingSeek(
            generation: generation,
            attemptID: self.pendingSeekAttemptIDsByGeneration[generation] ?? 0,
            target: self.pendingSeeksByGeneration[generation],
            videoId: expectedVideoId
        )
    }

    nonisolated static func shouldDiscardPendingSeek(
        expectedVideoId: String,
        activeVideoId: String?
    ) -> Bool {
        guard let activeVideoId else { return false }
        return activeVideoId != expectedVideoId
    }
}
