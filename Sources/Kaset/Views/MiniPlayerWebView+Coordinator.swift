// swiftlint:disable file_length
import Foundation
import os
import WebKit

// MARK: - PlaybackBridgeEventQueue

@MainActor
final class PlaybackBridgeEventQueue {
    private typealias Operation = @MainActor () async -> Void

    private var activeDocumentGeneration: UInt64?
    private var pendingOperations: [Operation] = []
    private var workerTask: Task<Void, Never>?
    private var workerID: UInt64 = 0

    func enqueue(
        documentGeneration: UInt64,
        operation: @escaping @MainActor () async -> Void
    ) {
        if self.activeDocumentGeneration != documentGeneration {
            self.cancelAll()
            self.activeDocumentGeneration = documentGeneration
        }

        self.pendingOperations.append(operation)
        guard self.workerTask == nil else { return }
        self.startWorker()
    }

    func cancelAll() {
        self.workerID &+= 1
        self.workerTask?.cancel()
        self.workerTask = nil
        self.pendingOperations.removeAll()
        self.activeDocumentGeneration = nil
    }

    func waitUntilIdle() async {
        await self.workerTask?.value
    }

    private func startWorker() {
        self.workerID &+= 1
        let workerID = self.workerID
        self.workerTask = Task { @MainActor [weak self] in
            await self?.drainOperations(workerID: workerID)
        }
    }

    private func drainOperations(workerID: UInt64) async {
        defer {
            if self.workerID == workerID {
                self.pendingOperations.removeAll()
                self.workerTask = nil
            }
        }

        while self.workerID == workerID,
              !Task.isCancelled,
              !self.pendingOperations.isEmpty
        {
            let operation = self.pendingOperations.removeFirst()
            await operation()
        }
    }
}

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

    nonisolated static func playbackBridgeInt(from value: Any?) -> Int? {
        WebPlaybackDocumentGeneration.decode(value).flatMap { Int(exactly: $0) }
    }

    /// Sanitizes the thumbnail URL reported by the playback bridge.
    ///
    /// `img.src` resolves relative to the document, so a player-bar image that has not
    /// yet been assigned a source reports the YouTube Music page URL. That value fetches
    /// successfully as HTML and then fails to decode, so it must never reach `currentTrack`.
    nonisolated static func playbackBridgeThumbnailURLString(from value: Any?) -> String {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty,
              !components.path.isEmpty,
              components.path != "/"
        else { return "" }

        return raw
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private static let queueNavigationObservationGrace: Duration = .seconds(1)

        let playerService: PlayerService
        private var lastAcceptedObserverEpoch: Double?
        private var lastAcceptedMediaGeneration: Int?
        private var lastAcceptedQueueEntryID: UUID?
        private var hasAcceptedQueueEntryBaseline = false
        private var lastAcceptedObservedVideoId: String?
        private var lastHandledEndedObserverEpoch: Double?
        private var lastHandledEndedMediaGeneration: Int?
        private let playbackBridgeEvents = PlaybackBridgeEventQueue()

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

            self.dispatchAcceptedBridgeMessage(
                body: body,
                type: type,
                documentGeneration: messageDocumentGeneration,
                commandIssuedAtMilliseconds: commandIssuedAtMilliseconds
            )
        }

        private func dispatchAcceptedBridgeMessage(
            body: [String: Any],
            type: String,
            documentGeneration: UInt64,
            commandIssuedAtMilliseconds: Double?
        ) {
            let observedVideoId = Self.observedVideoId(from: body)
            let musicPlaybackIntent = self.playerService.currentMusicPlaybackIntent
            let eventIssuedAtMilliseconds = SingletonPlayerWebView.finitePlaybackBridgeDouble(
                from: body["eventIssuedAtMilliseconds"]
            )

            switch type {
            case "TRACK_ENDED", "TRACK_ENDED_IDENTITY_DEADLINE":
                self.enqueueTrackEnded(
                    body: body,
                    documentGeneration: documentGeneration,
                    musicPlaybackIntent: musicPlaybackIntent,
                    eventIssuedAtMilliseconds: eventIssuedAtMilliseconds,
                    identityResolutionTimedOut: type == "TRACK_ENDED_IDENTITY_DEADLINE"
                )
            case "REMOTE_NEXT", "REMOTE_PREVIOUS":
                self.handleRemoteCommand(
                    type: type,
                    documentGeneration: documentGeneration,
                    commandIssuedAtMilliseconds: commandIssuedAtMilliseconds,
                    musicPlaybackIntent: musicPlaybackIntent
                )
            case "AIRPLAY_STATUS":
                self.handleAirPlayStatusUpdate(
                    body: body,
                    documentGeneration: documentGeneration
                )
            case "LYRICS_TIME":
                self.handleLyricsTimeUpdate(
                    body: body,
                    documentGeneration: documentGeneration
                )
            case "LYRICS_LINE":
                self.handleLyricsLineUpdate(
                    body: body,
                    documentGeneration: documentGeneration
                )
            case "PLAYBACK_AUDIO_QUALITY_STATS":
                Self.logAudioQualityStats(body: body, observedVideoId: observedVideoId)
            case "STATE_UPDATE":
                self.enqueueStateUpdate(
                    body: body,
                    observedVideoId: observedVideoId,
                    documentGeneration: documentGeneration,
                    musicPlaybackIntent: musicPlaybackIntent,
                    eventIssuedAtMilliseconds: eventIssuedAtMilliseconds
                )
            default:
                return
            }
        }

        private func enqueueTrackEnded(
            body: [String: Any],
            documentGeneration: UInt64,
            musicPlaybackIntent: MusicPlaybackIntent,
            eventIssuedAtMilliseconds: Double?,
            identityResolutionTimedOut: Bool,
            beforeHandling: (@MainActor () async -> Void)? = nil
        ) {
            let observedVideoId = Self.observedVideoId(from: body)
            let playbackOccurrence = Self.musicPlaybackOccurrence(
                from: body,
                documentGeneration: documentGeneration
            )
            let endedDuringAd = body["isAd"] as? Bool ?? false
            let endedIdentityUncertain = body["mediaIdentityUncertain"] as? Bool ?? false
            let observerEpoch = SingletonPlayerWebView.finitePlaybackBridgeDouble(
                from: body["observerEpoch"]
            ) ?? 0
            let mediaGeneration = SingletonPlayerWebView.playbackBridgeInt(from: body["mediaGeneration"]) ?? 0
            self.enqueuePlaybackBridgeMessage(generation: documentGeneration) { coordinator in
                if let beforeHandling {
                    await beforeHandling()
                }
                guard !Task.isCancelled,
                      coordinator.isCurrentPlaybackBridgeDocument(documentGeneration),
                      coordinator.playerService.acceptsMusicTerminalBridgeEvent(
                          intent: musicPlaybackIntent,
                          eventIssuedAtMilliseconds: eventIssuedAtMilliseconds
                      ),
                      !endedDuringAd,
                      // Identity retries retain this occurrence. Neither deduplication layer
                      // may claim it before identity resolves or the observer's deadline arrives.
                      !endedIdentityUncertain || identityResolutionTimedOut,
                      !identityResolutionTimedOut || playbackOccurrence != nil,
                      coordinator.consumeTrackEndedOccurrence(
                          observerEpoch: observerEpoch,
                          mediaGeneration: mediaGeneration
                      )
                else { return }
                await coordinator.playerService.handleTrackEnded(
                    observedVideoId: observedVideoId,
                    playbackOccurrence: playbackOccurrence,
                    intent: musicPlaybackIntent,
                    identityResolutionTimedOut: identityResolutionTimedOut,
                    shouldContinue: {
                        !Task.isCancelled
                            && coordinator.isCurrentPlaybackBridgeDocument(documentGeneration)
                    }
                )
            }
        }

        private func enqueuePlaybackBridgeMessage(
            generation: UInt64,
            operation: @escaping @MainActor (Coordinator) async -> Void
        ) {
            self.playbackBridgeEvents.enqueue(documentGeneration: generation) { [weak self] in
                guard let self,
                      !Task.isCancelled,
                      self.isCurrentPlaybackBridgeDocument(generation)
                else { return }
                await operation(self)
            }
        }

        func enqueueWebQueueInjectionResult(
            videoId: String,
            attemptGeneration: Int,
            success: Bool,
            reason: String?,
            documentGeneration: UInt64
        ) {
            guard self.isCurrentPlaybackBridgeDocument(documentGeneration) else { return }
            self.enqueuePlaybackBridgeMessage(generation: documentGeneration) { coordinator in
                coordinator.playerService.handleWebQueueInjectionResult(
                    videoId: videoId,
                    attemptGeneration: attemptGeneration,
                    success: success,
                    reason: reason
                )
            }
        }

        func cancelPlaybackBridgeTasks() {
            self.playbackBridgeEvents.cancelAll()
        }

        func enqueueTrackEndedForTesting(
            body: [String: Any],
            documentGeneration: UInt64,
            beforeHandling: @escaping @MainActor () async -> Void = {}
        ) {
            self.enqueueTrackEnded(
                body: body,
                documentGeneration: documentGeneration,
                musicPlaybackIntent: self.playerService.currentMusicPlaybackIntent,
                eventIssuedAtMilliseconds: self.playerService.musicPlaybackIntentIssuedAtMilliseconds + 1,
                identityResolutionTimedOut: body["type"] as? String == "TRACK_ENDED_IDENTITY_DEADLINE",
                beforeHandling: beforeHandling
            )
        }

        func enqueueStateUpdateForTesting(
            body: [String: Any],
            observedVideoId: String?,
            documentGeneration: UInt64
        ) {
            self.enqueueStateUpdate(
                body: body,
                observedVideoId: observedVideoId,
                documentGeneration: documentGeneration,
                musicPlaybackIntent: self.playerService.currentMusicPlaybackIntent,
                eventIssuedAtMilliseconds: self.playerService.musicPlaybackIntentIssuedAtMilliseconds + 1
            )
        }

        func awaitPlaybackBridgeDrainForTesting() async {
            await self.playbackBridgeEvents.waitUntilIdle()
        }

        private func isCurrentPlaybackBridgeDocument(_ generation: UInt64) -> Bool {
            SingletonPlayerWebView.shared.coordinator === self
                && SingletonPlayerWebView.shared.documentGeneration.accepts(generation: generation)
        }

        private func consumeTrackEndedOccurrence(
            observerEpoch: Double,
            mediaGeneration: Int
        ) -> Bool {
            guard WebPlaybackIdentityTransition.shouldAcceptEndedOccurrence(
                observerEpoch: observerEpoch,
                lastHandledObserverEpoch: self.lastHandledEndedObserverEpoch,
                mediaGeneration: mediaGeneration,
                lastHandledMediaGeneration: self.lastHandledEndedMediaGeneration
            ) else { return false }
            self.lastHandledEndedObserverEpoch = observerEpoch
            self.lastHandledEndedMediaGeneration = mediaGeneration
            return true
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
            self.normalizedVideoId(body["videoId"])
        }

        /// Uses the physical media identity when a state payload carries one. An explicitly empty
        /// media identity stays unknown instead of falling back to metadata that may lead playback.
        static func playbackVideoId(from body: [String: Any]) -> String? {
            if body.keys.contains("mediaVideoId") {
                return self.normalizedVideoId(body["mediaVideoId"])
            }
            return self.observedVideoId(from: body)
        }

        private static func normalizedVideoId(_ value: Any?) -> String? {
            guard let videoId = value as? String else { return nil }
            let normalized = videoId.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
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
                videoId: Self.playbackVideoId(from: body)
            )
        }

        private func handleAirPlayStatusUpdate(
            body: [String: Any],
            documentGeneration: UInt64
        ) {
            let isConnected = body["isConnected"] as? Bool ?? false

            Task { @MainActor in
                guard SingletonPlayerWebView.shared.documentGeneration.accepts(
                    generation: documentGeneration
                ) else { return }
                self.playerService.updateAirPlayStatus(isConnected: isConnected)
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
            let singleton = SingletonPlayerWebView.shared
            let previousGeneration = singleton.documentGeneration.currentGeneration
            singleton.commitDocumentNavigation(navigation, webView: webView)
            if singleton.documentGeneration.currentGeneration != previousGeneration {
                self.cancelPlaybackBridgeTasks()
            }
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
            self.playerService.syncWebQueue()
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

extension SingletonPlayerWebView.Coordinator {
    /// Test-facing bridge hook for exercising observation ordering without a live WKWebView document.
    func handleStateUpdate(
        body: [String: Any],
        observedVideoId: String?,
        mediaVideoId playbackVideoId: String?,
        observationReceivedAt: ContinuousClock.Instant,
        messageGeneration _: Int
    ) async {
        await self.processStateUpdate(
            body: body,
            observedVideoId: observedVideoId,
            mediaVideoId: playbackVideoId,
            observationReceivedAt: observationReceivedAt,
            documentGeneration: nil,
            musicPlaybackIntent: nil,
            eventIssuedAtMilliseconds: nil,
            validatesBridgeContext: false
        )
    }

    private func enqueueStateUpdate(
        body: [String: Any],
        observedVideoId: String?,
        documentGeneration: UInt64,
        musicPlaybackIntent: MusicPlaybackIntent,
        eventIssuedAtMilliseconds: Double?
    ) {
        let playbackVideoId = Self.playbackVideoId(from: body)
        let observationReceivedAt = ContinuousClock.now
        self.enqueuePlaybackBridgeMessage(generation: documentGeneration) { coordinator in
            await coordinator.processStateUpdate(
                body: body,
                observedVideoId: observedVideoId,
                mediaVideoId: playbackVideoId,
                observationReceivedAt: observationReceivedAt,
                documentGeneration: documentGeneration,
                musicPlaybackIntent: musicPlaybackIntent,
                eventIssuedAtMilliseconds: eventIssuedAtMilliseconds,
                validatesBridgeContext: true,
                shouldContinue: {
                    !Task.isCancelled
                        && coordinator.isCurrentPlaybackBridgeDocument(documentGeneration)
                }
            )
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length function_parameter_count
    private func processStateUpdate(
        body: [String: Any],
        observedVideoId: String?,
        mediaVideoId playbackVideoId: String?,
        observationReceivedAt: ContinuousClock.Instant,
        documentGeneration: UInt64?,
        musicPlaybackIntent: MusicPlaybackIntent?,
        eventIssuedAtMilliseconds: Double?,
        validatesBridgeContext: Bool,
        shouldContinue: @escaping @MainActor () -> Bool = { true }
    ) async {
        guard shouldContinue() else { return }

        let isPlaying = body["isPlaying"] as? Bool ?? false
        let progress = SingletonPlayerWebView.finitePlaybackBridgeDouble(from: body["progress"]) ?? 0
        let duration = SingletonPlayerWebView.finitePlaybackBridgeDouble(from: body["duration"]) ?? 0
        let isAd = body["isAd"] as? Bool ?? false
        let hasReadyMedia = body["hasReadyMedia"] as? Bool ?? true
        let title = body["title"] as? String ?? ""
        let artist = body["artist"] as? String ?? ""
        let thumbnailUrl = SingletonPlayerWebView.playbackBridgeThumbnailURLString(from: body["thumbnailUrl"])
        let trackChanged = body["trackChanged"] as? Bool ?? false
        let likeStatus = Self.likeStatus(from: body["likeStatus"] as? String)
        let hasVideo = body["hasVideo"] as? Bool ?? false
        let mediaGeneration = SingletonPlayerWebView.playbackBridgeInt(from: body["mediaGeneration"]) ?? 0
        let observerEpoch = SingletonPlayerWebView.finitePlaybackBridgeDouble(from: body["observerEpoch"]) ?? 0
        let playbackOccurrence = documentGeneration.flatMap {
            Self.musicPlaybackOccurrence(from: body, documentGeneration: $0)
        }

        if validatesBridgeContext {
            guard let documentGeneration,
                  let musicPlaybackIntent,
                  SingletonPlayerWebView.shared.documentGeneration.accepts(
                      generation: documentGeneration
                  ),
                  self.playerService.acceptsMusicBridgeEvent(
                      intent: musicPlaybackIntent,
                      eventIssuedAtMilliseconds: eventIssuedAtMilliseconds
                  ),
                  self.playerService.currentTrack != nil || self.playerService.pendingPlayVideoId != nil
            else { return }
        }
        if let playbackOccurrence,
           !self.playerService.acceptsWebMusicPlaybackOccurrence(playbackOccurrence)
        {
            return
        }
        let terminalPlaybackOccurrence = self.playerService.currentMusicPlaybackOccurrence
            ?? playbackOccurrence
        defer {
            if shouldContinue(), let playbackOccurrence, let documentGeneration {
                self.playerService.bindWebMusicPlaybackOccurrence(
                    documentGeneration: documentGeneration,
                    mediaGeneration: playbackOccurrence.mediaGeneration,
                    nativeGeneration: playbackOccurrence.nativeGeneration,
                    videoId: playbackVideoId
                )
            }
        }

        let isAuthoritativeContent = SingletonPlayerWebView.isAuthoritativePlaybackSample(
            hasReadyMedia: hasReadyMedia,
            isShowingAd: isAd
        )
        guard isAuthoritativeContent else {
            if WebPlaybackIdentityTransition.shouldAcceptAdvertisementState(
                hasReadyMedia: hasReadyMedia,
                isShowingAd: isAd,
                observedVideoId: playbackVideoId,
                pendingSourceVideoId: self.playerService.pendingNativeQueueAdvance?.sourceVideoId,
                order: WebPlaybackIdentityTransition.ObservationOrder(
                    observerEpoch: observerEpoch,
                    lastAcceptedObserverEpoch: self.lastAcceptedObserverEpoch,
                    mediaGeneration: mediaGeneration,
                    lastAcceptedMediaGeneration: self.lastAcceptedMediaGeneration
                )
            ) {
                self.playerService.updateAdPlaybackState(
                    isShowingAd: true,
                    observedProgress: progress,
                    observedVideoId: playbackVideoId,
                    isAuthoritativeContent: false
                )
                self.playerService.updatePlaybackTransportState(isPlaying: isPlaying)
                if !isPlaying, self.playerService.shouldResumeReadyAdDuringRestoration {
                    SingletonPlayerWebView.shared.resumeReadyAdvertisementIfPresent()
                }
            }
            return
        }

        guard WebPlaybackIdentityTransition.isObservationOrdered(
            observerEpoch: observerEpoch,
            lastAcceptedObserverEpoch: self.lastAcceptedObserverEpoch,
            mediaGeneration: mediaGeneration,
            lastAcceptedMediaGeneration: self.lastAcceptedMediaGeneration
        ) else { return }
        self.playerService.clearAdPlaybackBoundary()
        if let pendingAdvance = self.playerService.pendingNativeQueueAdvance,
           let playbackVideoId,
           playbackVideoId != pendingAdvance.sourceVideoId
        {
            guard WebPlaybackIdentityTransition.shouldAcceptMediaState(
                queueEntryChanged: true,
                observerEpoch: observerEpoch,
                lastAcceptedObserverEpoch: self.lastAcceptedObserverEpoch,
                mediaGeneration: mediaGeneration,
                lastAcceptedMediaGeneration: self.lastAcceptedMediaGeneration
            ) else { return }
        }
        guard shouldContinue() else { return }
        let shouldContinuePendingAdvance = await self.playerService
            .reconcilePendingNativeQueueAdvanceObservation(
                videoId: playbackVideoId,
                shouldContinue: shouldContinue
            )
        if validatesBridgeContext {
            guard shouldContinue(),
                  let documentGeneration,
                  let musicPlaybackIntent,
                  SingletonPlayerWebView.shared.documentGeneration.accepts(
                      generation: documentGeneration
                  ),
                  self.playerService.acceptsMusicBridgeEvent(
                      intent: musicPlaybackIntent,
                      eventIssuedAtMilliseconds: eventIssuedAtMilliseconds
                  ),
                  shouldContinuePendingAdvance
            else { return }
        } else if !shouldContinuePendingAdvance {
            return
        }

        if WebPlaybackIdentityTransition.shouldHandleDeferredIdentitylessObservation(
            isDeferred: self.playerService.isPendingRestoredLoadDeferred,
            observedVideoId: observedVideoId,
            playbackVideoId: playbackVideoId
        ) {
            self.playerService.updateAdPlaybackState(
                isShowingAd: false,
                observedProgress: progress,
                observedVideoId: playbackVideoId,
                isAuthoritativeContent: true
            )
            self.playerService.updatePlaybackState(
                isPlaying: isPlaying,
                progress: self.playerService.progress,
                duration: self.playerService.duration
            )
            return
        }

        let isWithinQueueNavigationObservationGrace = if let navigationStartedAt = self.playerService
            .protectedQueueNavigationStartedAt
        {
            observationReceivedAt - navigationStartedAt < Self.queueNavigationObservationGrace
        } else {
            false
        }

        if !self.hasAcceptedQueueEntryBaseline,
           self.playerService.isKasetInitiatedPlayback,
           playbackVideoId != nil,
           !self.playerService.observedPlaybackMatchesCurrentTarget(videoId: playbackVideoId),
           isWithinQueueNavigationObservationGrace
        {
            return
        }

        let queueEntryIDBeforeReconciliation = self.playerService.currentQueueEntryID
        let queueEntryChangedBeforeReconciliation = WebPlaybackIdentityTransition.didQueueEntryChange(
            hasBaseline: self.hasAcceptedQueueEntryBaseline,
            lastAcceptedQueueEntryID: self.lastAcceptedQueueEntryID,
            currentQueueEntryID: queueEntryIDBeforeReconciliation
        ) || self.playerService.observedPlaybackWouldChangeQueueEntry(videoId: playbackVideoId)
        let shouldAcceptBeforeReconciliation = WebPlaybackIdentityTransition.shouldAcceptMediaState(
            queueEntryChanged: queueEntryChangedBeforeReconciliation,
            observerEpoch: observerEpoch,
            lastAcceptedObserverEpoch: self.lastAcceptedObserverEpoch,
            mediaGeneration: mediaGeneration,
            lastAcceptedMediaGeneration: self.lastAcceptedMediaGeneration
        )
        if !shouldAcceptBeforeReconciliation {
            if !isWithinQueueNavigationObservationGrace {
                self.playerService.handleRejectedQueueNavigationObservationIfNeeded(
                    observedVideoId: playbackVideoId,
                    title: title,
                    artist: artist,
                    thumbnailUrl: thumbnailUrl,
                    trackChanged: trackChanged
                )
            }
            return
        }

        let expectedVideoIdBeforeReconciliation = self.playerService.currentTrack?.videoId
            ?? self.playerService.pendingPlayVideoId
        let shouldApplyPlaybackState = self.playerService.reconcileWebPlaybackMetadata(
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            observedVideoId: observedVideoId,
            playbackVideoId: playbackVideoId,
            bridgeTrackChanged: trackChanged,
            playbackOccurrence: terminalPlaybackOccurrence
        )

        let currentQueueEntryID = self.playerService.currentQueueEntryID
        let queueEntryChanged = WebPlaybackIdentityTransition.didQueueEntryChange(
            hasBaseline: self.hasAcceptedQueueEntryBaseline,
            lastAcceptedQueueEntryID: self.lastAcceptedQueueEntryID,
            currentQueueEntryID: currentQueueEntryID
        )
        let shouldAcceptMediaState = WebPlaybackIdentityTransition.shouldAcceptMediaState(
            queueEntryChanged: queueEntryChanged,
            observerEpoch: observerEpoch,
            lastAcceptedObserverEpoch: self.lastAcceptedObserverEpoch,
            mediaGeneration: mediaGeneration,
            lastAcceptedMediaGeneration: self.lastAcceptedMediaGeneration
        )
        let mediaMatches = self.playerService.observedPlaybackMatchesCurrentTarget(
            videoId: playbackVideoId
        )
        guard shouldApplyPlaybackState, mediaMatches, shouldAcceptMediaState else { return }
        self.playerService.updateAdPlaybackState(
            isShowingAd: false,
            observedProgress: progress,
            observedVideoId: playbackVideoId,
            isAuthoritativeContent: true
        )
        if validatesBridgeContext {
            SingletonPlayerWebView.shared.confirmRouterNavigationIfNeeded(videoId: playbackVideoId)
        }

        let acceptedVideoId = playbackVideoId
        let previousAcceptedVideoId = self.lastAcceptedObservedVideoId
        let acceptedObservedVideoIdChanged = acceptedVideoId != nil
            && acceptedVideoId != previousAcceptedVideoId
        let confirmedTrackTransition = WebPlaybackIdentityTransition.isConfirmed(
            observedVideoId: acceptedVideoId,
            lastAcceptedObservedVideoId: previousAcceptedVideoId,
            expectedVideoIdBeforeReconciliation: expectedVideoIdBeforeReconciliation
        )
        if let acceptedVideoId {
            self.lastAcceptedObservedVideoId = acceptedVideoId
        }

        self.playerService.updatePlaybackState(
            isPlaying: isPlaying,
            progress: progress,
            duration: Double(duration),
            observedVideoId: playbackVideoId
        )
        self.lastAcceptedObserverEpoch = observerEpoch
        self.lastAcceptedMediaGeneration = mediaGeneration
        self.lastAcceptedQueueEntryID = currentQueueEntryID
        self.hasAcceptedQueueEntryBaseline = true

        self.playerService.updateVideoAvailability(hasVideo: hasVideo)
        let logicalMatchesMedia = observedVideoId != nil && observedVideoId == playbackVideoId
        if logicalMatchesMedia, acceptedObservedVideoIdChanged || trackChanged {
            self.playerService.updateLikeStatus(likeStatus)
        }

        self.closeVideoWindowAfterConfirmedTransitionIfNeeded(
            confirmedTrackTransition: confirmedTrackTransition,
            observedVideoId: acceptedVideoId
        )
    }

    private func closeVideoWindowAfterConfirmedTransitionIfNeeded(
        confirmedTrackTransition: Bool,
        observedVideoId: String?
    ) {
        guard self.playerService.showVideo,
              confirmedTrackTransition,
              !self.playerService.isVideoGracePeriodActive
        else { return }

        DiagnosticsLogger.player.info(
            "trackChanged to videoId '\(observedVideoId ?? "unknown")' while video shown - closing video window"
        )
        self.playerService.showVideo = false
    }
}
