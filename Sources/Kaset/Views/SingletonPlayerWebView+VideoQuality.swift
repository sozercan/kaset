import WebKit

// MARK: - SingletonPlayerWebView Video Quality Extension

/// Video resolution controls for music **video mode** (Official Music Videos).
///
/// music.youtube.com embeds the same `#movie_player` as regular YouTube, so the
/// player's quality JS API is identical — these methods are ported near-verbatim
/// from `YouTubeWatchWebView+Scripts.swift`. A runtime probe confirmed the music
/// player exposes real levels (`hd720/large/medium/small/tiny/auto`) and that
/// `setPlaybackQualityRange` actually changes the resolution (not a no-op).
/// See ADR-0024.
///
/// Captions are deliberately NOT ported: the same probe found the music
/// `WEB_REMIX` player returns empty caption tracklists for OMVs.
extension SingletonPlayerWebView {
    /// Evaluates JavaScript that returns a string (nil on error).
    private func evaluateForString(_ script: String) async -> String? {
        guard let webView else { return nil }
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }

    /// Fetches the quality levels the player offers (empty until the stream has
    /// buffered enough for the player to report them).
    func availableQualityLevels() async -> [String] {
        let script = """
        (function() {
            try {
                const player = document.getElementById('movie_player');
                if (!player || typeof player.getAvailableQualityLevels !== 'function') { return '[]'; }
                return JSON.stringify(player.getAvailableQualityLevels() || []);
            } catch (e) { return '[]'; }
        })();
        """
        guard let json = await self.evaluateForString(script),
              let data = json.data(using: .utf8),
              let levels = try? JSONSerialization.jsonObject(with: data) as? [String]
        else {
            return []
        }
        return levels
    }

    /// The player's current quality level.
    func currentQualityLevel() async -> String? {
        let script = """
        (function() {
            try {
                const player = document.getElementById('movie_player');
                if (!player || typeof player.getPlaybackQuality !== 'function') { return ''; }
                return player.getPlaybackQuality() || '';
            } catch (e) { return ''; }
        })();
        """
        let level = await self.evaluateForString(script)
        return (level?.isEmpty == false) ? level : nil
    }

    /// Requests a playback quality level.
    func setQualityLevel(_ level: String) {
        let script = """
        (function() {
            const player = document.getElementById('movie_player');
            if (!player) { return; }
            try { player.setPlaybackQualityRange('\(level)', '\(level)'); } catch (e) {
                try { player.setPlaybackQuality('\(level)'); } catch (e2) {}
            }
        })();
        """
        self.webView?.evaluateJavaScript(script, completionHandler: nil)
    }
}
