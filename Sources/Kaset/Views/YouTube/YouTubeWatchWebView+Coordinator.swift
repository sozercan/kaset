import WebKit

extension YouTubeWatchWebView {
    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let playerService: YouTubePlayerService

        init(playerService: YouTubePlayerService) {
            self.playerService = playerService
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            let watchWebView = YouTubeWatchWebView.shared
            guard let body = message.body as? [String: Any],
                  let messageDocumentGeneration = WebPlaybackDocumentGeneration.decode(
                      body["documentGeneration"]
                  ),
                  YouTubeWatchWebView.acceptsBridgeSource(
                      isMainFrame: message.frameInfo.isMainFrame,
                      sourceScheme: message.frameInfo.securityOrigin.protocol,
                      sourceHost: message.frameInfo.securityOrigin.host
                  ),
                  YouTubeWatchWebView.acceptsBridgeMessage(
                      sourceWebView: message.webView,
                      currentWebView: watchWebView.webView,
                      documentGeneration: watchWebView.documentGeneration,
                      rawDocumentGeneration: messageDocumentGeneration
                  ),
                  let type = body["type"] as? String
            else { return }

            switch type {
            case "STATE_UPDATE":
                self.handleStateUpdate(body, documentGeneration: messageDocumentGeneration)
            case "VIDEO_ENDED":
                self.handleVideoEnded(body, documentGeneration: messageDocumentGeneration)
            default:
                return
            }
        }

        private func handleStateUpdate(
            _ body: [String: Any],
            documentGeneration: UInt64
        ) {
            let update = YouTubePlayerService.PlaybackUpdate(
                isPlaying: body["isPlaying"] as? Bool ?? false,
                progress: body["progress"] as? Double ?? 0,
                duration: body["duration"] as? Double ?? 0,
                hasReadyMedia: body["hasReadyMedia"] as? Bool ?? false,
                videoId: (body["videoId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                boundVideoId: (body["boundVideoId"] as? String)
                    .flatMap { $0.isEmpty ? nil : $0 },
                title: body["title"] as? String,
                isAd: body["isAd"] as? Bool ?? false,
                didApplyPendingSeek: body["pendingSeekApplied"] as? Bool ?? false,
                didFailPendingSeek: body["pendingSeekFailed"] as? Bool ?? false,
                pendingSeekTarget: body["pendingSeekTarget"] as? Double,
                pendingSeekVideoId: (body["pendingSeekVideoId"] as? String)
                    .flatMap { $0.isEmpty ? nil : $0 },
                pendingSeekAttempt: WebPlaybackDocumentGeneration.decode(
                    body["pendingSeekAttempt"]
                ),
                nativePausePending: body["nativePausePending"] as? Bool ?? false,
                eventIssuedAtMilliseconds: body["eventIssuedAtMilliseconds"] as? Double,
                playbackOccurrence: Self.playbackOccurrence(
                    from: body,
                    documentGeneration: documentGeneration
                )
            )
            // WebKit has already admitted this main-frame message for the active
            // document. Persist the recovery-only marker synchronously so a
            // process-termination callback cannot invalidate the generation first.
            self.playerService.recordPostConclusionAutoplayTransitionIfNeeded(update)
            Task { @MainActor in
                guard YouTubeWatchWebView.shared.documentGeneration.accepts(
                    generation: documentGeneration
                ) else { return }
                guard self.playerService.acceptsPlaybackOccurrence(
                    update.playbackOccurrence
                ) else { return }
                var validatedUpdate = update
                if update.didApplyPendingSeek,
                   let target = update.pendingSeekTarget,
                   let pendingSeekVideoId = update.pendingSeekVideoId,
                   let pendingSeekAttempt = update.pendingSeekAttempt
                {
                    let didAcceptSeek = YouTubeWatchWebView.shared.completePendingSeek(
                        generation: documentGeneration,
                        attemptID: pendingSeekAttempt,
                        target: target,
                        videoId: pendingSeekVideoId
                    )
                    if !didAcceptSeek {
                        validatedUpdate.didApplyPendingSeek = false
                    }
                }
                self.playerService.updatePlaybackState(validatedUpdate)
                self.reconcilePendingSeek(
                    after: validatedUpdate,
                    documentGeneration: documentGeneration
                )
            }
        }

        @MainActor
        private func reconcilePendingSeek(
            after update: YouTubePlayerService.PlaybackUpdate,
            documentGeneration: UInt64
        ) {
            if !update.isAd, update.hasReadyMedia {
                YouTubeWatchWebView.shared.discardPendingSeekIfActiveVideoChanged(
                    generation: documentGeneration
                )
            }
            guard let target = update.pendingSeekTarget,
                  let pendingSeekVideoId = update.pendingSeekVideoId,
                  let pendingSeekAttempt = update.pendingSeekAttempt
            else { return }

            if update.didFailPendingSeek {
                let didExhaustRetries = YouTubeWatchWebView.shared.retryPendingSeek(
                    generation: documentGeneration,
                    target: target,
                    videoId: pendingSeekVideoId,
                    attemptID: pendingSeekAttempt
                )
                if didExhaustRetries {
                    self.playerService.handlePendingSeekExhausted(
                        videoId: pendingSeekVideoId,
                        target: target
                    )
                }
            }
        }

        private func handleVideoEnded(
            _ body: [String: Any],
            documentGeneration: UInt64
        ) {
            let videoId = (body["videoId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let endedDuringAd = body["isAd"] as? Bool ?? false
            let playbackOccurrence = Self.playbackOccurrence(
                from: body,
                documentGeneration: documentGeneration
            )
            let endedSeekAttempt = WebPlaybackDocumentGeneration.decode(
                body["pendingSeekAttempt"]
            )
            let eventIssuedAtMilliseconds = body["eventIssuedAtMilliseconds"] as? Double
            guard !endedDuringAd else { return }
            // The outer bridge admission already validated WebView identity and
            // document generation. Commit this terminal occurrence synchronously;
            // a process-termination callback may invalidate the document next.
            let didAcceptEnd = self.playerService.handleVideoEnded(
                videoId: videoId,
                playbackOccurrence: playbackOccurrence,
                eventIssuedAtMilliseconds: eventIssuedAtMilliseconds
            )
            if didAcceptEnd, let endedSeekAttempt {
                YouTubeWatchWebView.shared.completePendingSeek(
                    generation: documentGeneration,
                    attemptID: endedSeekAttempt
                )
            }
        }

        private static func playbackOccurrence(
            from body: [String: Any],
            documentGeneration: UInt64
        ) -> YouTubePlaybackOccurrence? {
            guard let mediaGeneration = WebPlaybackDocumentGeneration.decode(
                body["mediaGeneration"]
            ), mediaGeneration > 0 else { return nil }
            return YouTubePlaybackOccurrence(
                documentGeneration: documentGeneration,
                mediaGeneration: mediaGeneration
            )
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            YouTubeWatchWebView.shared.decideNavigationPolicy(
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
            let watchWebView = YouTubeWatchWebView.shared
            let isAllowed = YouTubeWatchWebView.acceptsMainFrameResponse(
                navigationResponse.response,
                expectedVideoID: watchWebView.currentVideoId
                    ?? self.playerService.currentVideo?.videoId,
                documentGeneration: watchWebView.documentGeneration
            )
            if isAllowed {
                watchWebView.recordAcceptedMainFrameResponse(navigationResponse.response)
            }
            decisionHandler(isAllowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            YouTubeWatchWebView.shared.trackDocumentNavigationStart(navigation, webView: webView)
            YouTubeWatchWebView.shared.webKitManager?.extensionHostWebViewDidStartNavigation(webView)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            YouTubeWatchWebView.shared.handleDocumentNavigationRedirect(navigation, webView: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            YouTubeWatchWebView.shared.commitDocumentNavigation(navigation, webView: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let cancelledNavigation = YouTubeWatchWebView.shared.consumeCancelledDocumentNavigation(
                navigation
            ) {
                if cancelledNavigation.shouldReportFailure {
                    YouTubeWatchWebView.shared.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
                }
                return
            }
            guard YouTubeWatchWebView.shared.finishDocumentNavigation(
                navigation,
                webView: webView
            ) else {
                YouTubeWatchWebView.shared.webKitManager?.extensionHostWebViewDidFailNavigation(webView)
                return
            }
            YouTubeWatchWebView.shared.webKitManager?.extensionHostWebViewDidFinishNavigation(webView)
            guard WebPlaybackDocumentGeneration.isExpectedPlaybackURL(
                webView.url,
                host: "www.youtube.com"
            ) else { return }
            DiagnosticsLogger.player.info(
                "YouTube watch WebView finished loading: \(webView.url?.absoluteString ?? "nil")"
            )

            // The resume-seek for an identity-switch reload is applied by the
            // observer's applyPendingSeek (gated on the <video> existing and being
            // seekable), not here: at didFinish the element often does not exist
            // yet, so a one-shot seek would be lost. Clear the Swift-side copy now
            // that the per-load bootstrap has carried the value into the page.
            YouTubeWatchWebView.shared.pendingSeek = nil

            let savedVolume = self.playerService.volume
            webView.evaluateJavaScript(
                """
                (function() {
                    window.__kasetTargetVolume = \(savedVolume);
                    const video = document.querySelector('video');
                    if (video) { video.volume = \(savedVolume); }
                    if (window.__kasetExtractVideo) { window.__kasetExtractVideo(); }
                })();
                """,
                completionHandler: nil
            )
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            YouTubeWatchWebView.shared.handleDocumentNavigationFailure(navigation, webView: webView, error: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            YouTubeWatchWebView.shared.handleDocumentNavigationFailure(navigation, webView: webView, error: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            DiagnosticsLogger.player.error("YouTube watch WebView content process terminated, recovering")
            let resumeAt = YouTubeWatchWebView.shared.pendingSeekForActiveNavigation()
            guard YouTubeWatchWebView.shared.beginContentProcessRecovery(webView: webView) else { return }
            self.playerService.recoverAfterWebContentProcessTermination(
                resumeAtOverride: resumeAt
            )
        }
    }
}
