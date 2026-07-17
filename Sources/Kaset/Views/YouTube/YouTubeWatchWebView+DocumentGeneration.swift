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
