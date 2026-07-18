import Foundation
import os
import WebKit

// MARK: - SingletonPlayerWebView.Coordinator

extension SingletonPlayerWebView {
    nonisolated static func finitePlaybackBridgeDouble(from value: Any?) -> Double? {
        guard !(value is Bool) else { return nil }

        let decoded: Double? = switch value {
        case let number as NSNumber:
            number.doubleValue
        case let double as Double:
            double
        case let float as Float:
            Double(float)
        case let integer as Int:
            Double(integer)
        default:
            nil
        }
        guard let decoded, decoded.isFinite else { return nil }
        return decoded
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let playerService: PlayerService

        init(playerService: PlayerService) {
            self.playerService = playerService
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            let singleton = SingletonPlayerWebView.shared
            guard let body = message.body as? [String: Any],
                  let messageDocumentGeneration = WebPlaybackDocumentGeneration.decode(
                      body["documentGeneration"]
                  ),
                  SingletonPlayerWebView.acceptsBridgeSource(
                      isMainFrame: message.frameInfo.isMainFrame,
                      sourceScheme: message.frameInfo.securityOrigin.protocol,
                      sourceHost: message.frameInfo.securityOrigin.host
                  ),
                  SingletonPlayerWebView.isCurrentBridgeWebView(
                      sourceWebView: message.webView,
                      currentWebView: singleton.webView
                  ),
                  let type = body["type"] as? String
            else { return }

            let isUserCommand = type == "REMOTE_NEXT" || type == "REMOTE_PREVIOUS"
            let commandIssuedAtMilliseconds = SingletonPlayerWebView.finitePlaybackBridgeDouble(
                from: body["commandIssuedAtMilliseconds"]
            )
            let acceptsGeneration = isUserCommand
                ? singleton.documentGeneration.acceptsUserCommand(
                    generation: messageDocumentGeneration,
                    issuedAtMilliseconds: commandIssuedAtMilliseconds,
                    navigationStartedAtMilliseconds: singleton.documentNavigationStartedAtMilliseconds
                )
                : singleton.documentGeneration.accepts(generation: messageDocumentGeneration)
            guard acceptsGeneration else { return }

            let observedVideoId = Self.observedVideoId(from: body)
            let playbackOccurrence = Self.musicPlaybackOccurrence(
                from: body,
                documentGeneration: messageDocumentGeneration
            )
            let musicPlaybackIntent = self.playerService.currentMusicPlaybackIntent
            let eventIssuedAtMilliseconds = SingletonPlayerWebView.finitePlaybackBridgeDouble(
                from: body["eventIssuedAtMilliseconds"]
            )

            switch type {
            case "TRACK_ENDED":
                let endedDuringAd = body["isAd"] as? Bool ?? false
                Task { @MainActor in
                    guard SingletonPlayerWebView.shared.documentGeneration.accepts(
                        generation: messageDocumentGeneration
                    ), self.playerService.acceptsMusicTerminalBridgeEvent(
                        intent: musicPlaybackIntent,
                        eventIssuedAtMilliseconds: eventIssuedAtMilliseconds
                    ),
                        !endedDuringAd
                    else { return }
                    await self.playerService.handleTrackEnded(
                        observedVideoId: observedVideoId,
                        playbackOccurrence: playbackOccurrence,
                        intent: musicPlaybackIntent
                    )
                }
            case "REMOTE_NEXT", "REMOTE_PREVIOUS":
                self.handleRemoteCommand(
                    type: type,
                    documentGeneration: messageDocumentGeneration,
                    commandIssuedAtMilliseconds: commandIssuedAtMilliseconds,
                    musicPlaybackIntent: musicPlaybackIntent
                )
            case "AIRPLAY_STATUS":
                self.handleAirPlayStatusUpdate(
                    body: body,
                    documentGeneration: messageDocumentGeneration
                )
            case "LYRICS_TIME":
                self.handleLyricsTimeUpdate(
                    body: body,
                    documentGeneration: messageDocumentGeneration
                )
            case "LYRICS_LINE":
                self.handleLyricsLineUpdate(
                    body: body,
                    documentGeneration: messageDocumentGeneration
                )
            case "PLAYBACK_AUDIO_QUALITY_STATS":
                Self.logAudioQualityStats(body: body, observedVideoId: observedVideoId)
            case "STATE_UPDATE":
                self.handleStateUpdate(
                    body: body,
                    observedVideoId: observedVideoId,
                    documentGeneration: messageDocumentGeneration,
                    musicPlaybackIntent: musicPlaybackIntent,
                    eventIssuedAtMilliseconds: eventIssuedAtMilliseconds
                )
            default:
                return
            }
        }

        private func handleRemoteCommand(
            type: String,
            documentGeneration: UInt64,
            commandIssuedAtMilliseconds: Double?,
            musicPlaybackIntent: MusicPlaybackIntent
        ) {
            guard SingletonPlayerWebView.shared.documentGeneration.acceptsUserCommand(
                generation: documentGeneration,
                issuedAtMilliseconds: commandIssuedAtMilliseconds,
                navigationStartedAtMilliseconds: SingletonPlayerWebView.shared
                    .documentNavigationStartedAtMilliseconds
            ), self.playerService.acceptsMusicRemoteCommand(
                intent: musicPlaybackIntent,
                commandIssuedAtMilliseconds: commandIssuedAtMilliseconds
            ), let commandIssuedAtMilliseconds
            else { return }
            self.playerService.enqueueRemoteMusicTransportCommand(
                type == "REMOTE_NEXT" ? .next : .previous,
                issuedAtMilliseconds: commandIssuedAtMilliseconds
            )
        }

        private static func observedVideoId(from body: [String: Any]) -> String? {
            guard let videoId = body["videoId"] as? String, !videoId.isEmpty else { return nil }
            return videoId
        }

        private static func musicPlaybackOccurrence(
            from body: [String: Any],
            documentGeneration: UInt64
        ) -> MusicPlaybackOccurrence? {
            guard let mediaGeneration = WebPlaybackDocumentGeneration.decode(body["mediaGeneration"]),
                  mediaGeneration > 0
            else {
                return nil
            }
            return .web(
                documentGeneration: documentGeneration,
                mediaGeneration: mediaGeneration,
                nativeGeneration: WebPlaybackDocumentGeneration.decode(
                    body["nativePlaybackGeneration"]
                ) ?? 0,
                videoId: Self.observedVideoId(from: body)
            )
        }

        private func handleAirPlayStatusUpdate(
            body: [String: Any],
            documentGeneration: UInt64
        ) {
            let isConnected = body["isConnected"] as? Bool ?? false
            let wasRequested = body["wasRequested"] as? Bool ?? false

            Task { @MainActor in
                guard SingletonPlayerWebView.shared.documentGeneration.accepts(
                    generation: documentGeneration
                ) else { return }
                self.playerService.updateAirPlayStatus(
                    isConnected: isConnected,
                    wasRequested: wasRequested
                )
            }
        }

        private func handleLyricsTimeUpdate(
            body: [String: Any],
            documentGeneration: UInt64
        ) {
            guard let time = body["time"] as? Double,
                  body["isAd"] as? Bool != true
            else { return }

            Task { @MainActor in
                guard SingletonPlayerWebView.shared.documentGeneration.accepts(
                    generation: documentGeneration
                ) else { return }
                self.playerService.currentTimeMs = Int(time * 1000)
            }
        }

        private func handleLyricsLineUpdate(
            body: [String: Any],
            documentGeneration: UInt64
        ) {
            guard body["isAd"] as? Bool != true else { return }
            let lineIndex = body["lineIndex"] as? Int ?? -1
            let normalizedLineIndex = lineIndex >= 0 ? lineIndex : nil
            let displayTimeMs = body["timeMs"] as? Int

            Task { @MainActor in
                guard SingletonPlayerWebView.shared.documentGeneration.accepts(
                    generation: documentGeneration
                ), self.playerService.currentLyricsLineIndex != normalizedLineIndex
                    || self.playerService.currentLyricsDisplayTimeMs != displayTimeMs
                else { return }
                self.playerService.currentLyricsLineIndex = normalizedLineIndex
                self.playerService.currentLyricsDisplayTimeMs = displayTimeMs
            }
        }

        private static func likeStatus(from rawValue: String?) -> LikeStatus {
            switch rawValue {
            case "LIKE":
                .like
            case "DISLIKE":
                .dislike
            default:
                .indifferent
            }
        }

        private static let allowedAudioQualityStatsKeys: Set<String> = [
            "afmt",
            "audioBitrate",
            "audioCodec",
            "audioCodecs",
            "audioFormat",
            "audioItag",
            "audioMimeType",
            "audioQuality",
            "audio_format",
            "bitrate",
            "codec",
            "codecs",
            "debug_audioFormat",
            "debug_audioQuality",
            "debug_playbackQuality",
            "itag",
            "mimeType",
            "quality",
        ]

        private static let allowedAudioQualityStatsFragments: Set<String> = [
            "bitrate",
            "codec",
            "format",
            "itag",
            "mime",
            "quality",
        ]

        private static func logAudioQualityStats(body: [String: Any], observedVideoId: String?) {
            let message = Self.audioQualityStatsLogMessage(body: body, observedVideoId: observedVideoId)
            DiagnosticsLogger.player.info("Audio quality stats: \(message, privacy: .private)")
        }

        static func audioQualityStatsLogMessage(body: [String: Any], observedVideoId: String?) -> String {
            let preferred = Self.sanitizedLogString(body["preferred"])
            let desired = Self.sanitizedLogString(body["desired"])
            let applied = (body["applied"] as? Bool) == true ? "true" : "false"
            let observed = Self.sanitizedLogString(body["observed"])
            let source = Self.sanitizedLogString(body["source"])
            let videoId = Self.sanitizedLogString(observedVideoId, fallback: "unknown")
            let available = Self.compactJSONText(
                Self.sanitizedPrimitiveArray(body["available"]) ?? [],
                fallback: "[]"
            )
            let stats = Self.compactJSONText(Self.sanitizedStatsForNerds(body["stats"]), fallback: "{}")

            return """
            preferred=\(preferred) desired=\(desired) applied=\(applied) observed=\(observed) \
            source=\(source) videoId=\(videoId) available=\(available) stats=\(stats)
            """
        }

        private static func sanitizedLogString(_ value: Any?, fallback: String = "unknown") -> String {
            guard let value else { return fallback }

            let string: String = if let stringValue = value as? String {
                stringValue
            } else {
                String(describing: value)
            }

            let flattened = string
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\t", with: " ")

            guard !flattened.isEmpty else { return fallback }
            return String(flattened.prefix(200))
        }

        private static func compactJSONText(_ value: Any, fallback: String) -> String {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8)
            else {
                return fallback
            }

            return text
        }

        private static func sanitizedStatsForNerds(_ value: Any?) -> [String: Any] {
            guard let value = value as? [String: Any] else { return [:] }

            var sanitized: [String: Any] = [:]
            for key in value.keys.sorted() where sanitized.count < 12 {
                guard Self.isAllowedAudioQualityStatsKey(key) else { continue }

                let sanitizedKey = String(key.prefix(80))
                if let primitive = Self.sanitizedPrimitive(value[key]) {
                    sanitized[sanitizedKey] = primitive
                    continue
                }

                if let primitiveArray = Self.sanitizedPrimitiveArray(value[key]) {
                    sanitized[sanitizedKey] = primitiveArray
                }
            }

            return sanitized
        }

        private static func isAllowedAudioQualityStatsKey(_ key: String) -> Bool {
            if self.allowedAudioQualityStatsKeys.contains(key) {
                return true
            }

            let lowercasedKey = key.lowercased()
            return lowercasedKey.contains("audio")
                && Self.allowedAudioQualityStatsFragments.contains { lowercasedKey.contains($0) }
        }

        private static func sanitizedPrimitiveArray(_ value: Any?) -> [Any]? {
            guard let values = value as? [Any] else { return nil }

            let sanitized = values.prefix(12).compactMap { Self.sanitizedPrimitive($0) }
            return sanitized.isEmpty ? nil : sanitized
        }

        private static func sanitizedPrimitive(_ value: Any?) -> Any? {
            guard let value else { return nil }

            if let value = value as? String {
                return String(value.prefix(160))
            }

            if let value = value as? Bool {
                return value
            }

            return Self.sanitizedNumericPrimitive(value)
        }

        private static func sanitizedNumericPrimitive(_ value: Any) -> Any? {
            if let value = value as? Int {
                return value
            }

            if let value = value as? Int8 {
                return value
            }

            if let value = value as? Int16 {
                return value
            }

            if let value = value as? Int32 {
                return value
            }

            if let value = value as? Int64 {
                return value
            }

            if let value = value as? UInt {
                return value
            }

            if let value = value as? UInt8 {
                return value
            }

            if let value = value as? UInt16 {
                return value
            }

            if let value = value as? UInt32 {
                return value
            }

            if let value = value as? UInt64 {
                return value
            }

            if let value = value as? Double {
                return value.isFinite ? value : nil
            }

            if let value = value as? Float {
                return value.isFinite ? Double(value) : nil
            }

            if let value = value as? NSNumber {
                return value.doubleValue.isFinite ? value : nil
            }

            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            SingletonPlayerWebView.shared.decideNavigationPolicy(
                webView: webView,
                navigationAction: navigationAction,
                decisionHandler: decisionHandler
            )
        }

        func webView(
            _: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
        ) {
            guard navigationResponse.isForMainFrame else {
                decisionHandler(.allow)
                return
            }
            let singleton = SingletonPlayerWebView.shared
            let isAllowed = SingletonPlayerWebView.acceptsMainFrameResponse(
                navigationResponse.response,
                expectedVideoID: singleton.currentVideoId,
                documentGeneration: singleton.documentGeneration
            )
            if isAllowed {
                singleton.recordAcceptedMainFrameResponse(navigationResponse.response)
            }
            decisionHandler(isAllowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            SingletonPlayerWebView.shared.handleDocumentNavigationStart(navigation, webView: webView)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            SingletonPlayerWebView.shared.handleDocumentNavigationRedirect(navigation, webView: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            SingletonPlayerWebView.shared.commitDocumentNavigation(navigation, webView: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let cancelledNavigation = SingletonPlayerWebView.shared.consumeCancelledDocumentNavigation(
                navigation
            ) {
                if cancelledNavigation.shouldReportFailure {
                    SingletonPlayerWebView.shared.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
                }
                return
            }
            guard SingletonPlayerWebView.shared.handleDocumentNavigationFinish(
                navigation,
                webView: webView
            ) else {
                SingletonPlayerWebView.shared.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
                return
            }
            guard WebPlaybackDocumentGeneration.isExpectedPlaybackURL(
                webView.url,
                host: "music.youtube.com"
            ) else { return }
            SingletonPlayerWebView.shared.syncAutoplayIntent(on: webView)
            DiagnosticsLogger.player.info(
                "Singleton WebView finished loading: \(webView.url?.absoluteString ?? "nil")"
            )

            // Apply the current volume when page finishes loading
            // This is critical because YouTube may set its own default volume
            let savedVolume = self.playerService.volume
            let applyVolumeScript = """
                (function() {
                    try {
                        const volume = \(savedVolume);
                        window.__kasetTargetVolume = volume;
                        window.__kasetIsSettingVolume = true;

                        const video = document.querySelector('video');
                        if (video) {
                            video.volume = volume;
                        }

                        // Sync YouTube's internal player APIs if ready
                        const ytVolume = Math.round(volume * 100);
                        const player = document.querySelector('ytmusic-player');
                        if (player && player.playerApi && typeof player.playerApi.setVolume === 'function') {
                            player.playerApi.setVolume(ytVolume);
                        }
                        const moviePlayer = document.getElementById('movie_player');
                        if (moviePlayer && typeof moviePlayer.setVolume === 'function') {
                            moviePlayer.setVolume(ytVolume);
                        }

                        setTimeout(() => { window.__kasetIsSettingVolume = false; }, 100);
                        return video ? 'applied' : 'no-video-yet';
                    } catch (e) {
                         return 'error: ' + e;
                    }
                })();
            """
            webView.evaluateJavaScript(applyVolumeScript) { result, error in
                if let error {
                    DiagnosticsLogger.player.error(
                        "Failed to apply saved volume \(savedVolume): \(error.localizedDescription)"
                    )
                } else if let resultString = result as? String {
                    DiagnosticsLogger.player.debug("Volume apply result: \(resultString)")
                }

                // Restore lyrics high-frequency polling if it was active
                if SingletonPlayerWebView.shared.isLyricsPollActive {
                    SingletonPlayerWebView.shared.startLyricsPoll()
                }

                // Re-inject video mode CSS if it was active
                if SingletonPlayerWebView.shared.displayMode == .video {
                    SingletonPlayerWebView.shared.refreshVideoModeCSS()
                    // If refresh fails to find the container (because it's a new page),
                    // it will log a debug message. We should also call the full injection.
                    SingletonPlayerWebView.shared.injectVideoModeCSS()
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            SingletonPlayerWebView.shared.handleDocumentNavigationFailure(navigation, webView: webView, error: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            SingletonPlayerWebView.shared.handleDocumentNavigationFailure(navigation, webView: webView, error: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            SingletonPlayerWebView.shared.recoverFromContentProcessTermination(webView: webView)
        }
    }
}

private extension SingletonPlayerWebView.Coordinator {
    private func handleStateUpdate(
        body: [String: Any],
        observedVideoId: String?,
        documentGeneration: UInt64,
        musicPlaybackIntent: MusicPlaybackIntent,
        eventIssuedAtMilliseconds: Double?
    ) {
        let isPlaying = body["isPlaying"] as? Bool ?? false
        let progress = SingletonPlayerWebView.finitePlaybackBridgeDouble(from: body["progress"]) ?? 0
        let duration = SingletonPlayerWebView.finitePlaybackBridgeDouble(from: body["duration"]) ?? 0
        let isAd = body["isAd"] as? Bool ?? false
        let hasReadyMedia = body["hasReadyMedia"] as? Bool ?? false
        let title = body["title"] as? String ?? ""
        let artist = body["artist"] as? String ?? ""
        let thumbnailUrl = body["thumbnailUrl"] as? String ?? ""
        let trackChanged = body["trackChanged"] as? Bool ?? false
        let likeStatus = Self.likeStatus(from: body["likeStatus"] as? String)
        let hasVideo = body["hasVideo"] as? Bool ?? false
        let playbackOccurrence = Self.musicPlaybackOccurrence(
            from: body,
            documentGeneration: documentGeneration
        )

        Task { @MainActor in
            guard SingletonPlayerWebView.shared.documentGeneration.accepts(
                generation: documentGeneration
            ), self.playerService.acceptsMusicBridgeEvent(
                intent: musicPlaybackIntent,
                eventIssuedAtMilliseconds: eventIssuedAtMilliseconds
            ), self.playerService.currentTrack != nil || self.playerService.pendingPlayVideoId != nil
            else { return }
            if let playbackOccurrence,
               !self.playerService.acceptsWebMusicPlaybackOccurrence(playbackOccurrence)
            {
                return
            }
            let currentPlaybackOccurrence = self.playerService.currentMusicPlaybackOccurrence
            let terminalPlaybackOccurrence = currentPlaybackOccurrence ?? playbackOccurrence
            defer {
                if let playbackOccurrence {
                    self.playerService.bindWebMusicPlaybackOccurrence(
                        documentGeneration: documentGeneration,
                        mediaGeneration: playbackOccurrence.mediaGeneration,
                        nativeGeneration: playbackOccurrence.nativeGeneration,
                        videoId: observedVideoId
                    )
                }
            }
            let isAuthoritativeContent = SingletonPlayerWebView.isAuthoritativePlaybackSample(
                hasReadyMedia: hasReadyMedia,
                isShowingAd: isAd
            )
            self.playerService.updateAdPlaybackState(
                isShowingAd: isAd,
                observedProgress: Double(progress),
                observedVideoId: observedVideoId,
                isAuthoritativeContent: isAuthoritativeContent
            )
            if isAuthoritativeContent {
                self.playerService.updatePlaybackState(
                    isPlaying: isPlaying,
                    progress: Double(progress),
                    duration: Double(duration),
                    observedVideoId: observedVideoId
                )
            } else if hasReadyMedia, isAd {
                self.playerService.updatePlaybackTransportState(isPlaying: isPlaying)
                if !isPlaying, self.playerService.shouldResumeReadyAdDuringRestoration {
                    SingletonPlayerWebView.shared.resumeReadyAdvertisementIfPresent()
                }
            }

            // Update video availability
            self.playerService.updateVideoAvailability(hasVideo: hasVideo)

            // Update like status only when track changes (initial state)
            if trackChanged {
                self.playerService.updateLikeStatus(likeStatus)
            }

            let hasObservedMetadata = observedVideoId != nil || !title.isEmpty
            // Repeat-one still needs drift recovery, but the normal same-song polling path
            // should not rewrite `currentTrack` on every observer tick.
            let repeatOneNeedsReconcile = self.playerService.repeatMode == .one
                && hasObservedMetadata
                && (trackChanged
                    || (observedVideoId != nil && observedVideoId != self.playerService.currentTrack?.videoId)
                    || (observedVideoId == nil && !title.isEmpty && title != self.playerService.currentTrack?.title))
            let shouldReconcileMetadata = hasObservedMetadata && (trackChanged || repeatOneNeedsReconcile)

            if shouldReconcileMetadata {
                self.playerService.updateTrackMetadata(
                    title: title,
                    artist: artist,
                    thumbnailUrl: thumbnailUrl,
                    videoId: observedVideoId,
                    playbackOccurrence: terminalPlaybackOccurrence
                )

                // Close video window on track change, but skip during grace period.
                // We only close if the videoId actually changed to prevent closing
                // due to spurious metadata (title/artist) glitches during resize.
                let videoIdChanged = observedVideoId != nil && observedVideoId != self.playerService.currentTrack?.videoId

                if self.playerService.showVideo, videoIdChanged, !self.playerService.isVideoGracePeriodActive {
                    DiagnosticsLogger.player.info(
                        "trackChanged to videoId '\(observedVideoId ?? "unknown")' while video shown - closing video window"
                    )
                    self.playerService.showVideo = false
                }
            }
        }
    }
}
