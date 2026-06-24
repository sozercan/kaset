import Foundation

// MARK: - MusicVideoQualitySource

/// The async quality-control surface backing music video mode. The production
/// implementation is `SingletonPlayerWebView`; tests inject a recorder so the
/// discovery/retry logic can be exercised without a live WebView.
@MainActor
protocol MusicVideoQualitySource: AnyObject {
    /// The videoId the WebView's player currently reports as loaded (reads the
    /// live `#movie_player`), or nil if not yet known. Used to confirm the page
    /// has actually navigated before trusting its quality levels.
    func loadedVideoId() async -> String?
    func availableQualityLevels() async -> [String]
    func currentQualityLevel() async -> String?
    func setQualityLevel(_ level: String)
}

// MARK: - SingletonPlayerWebView + MusicVideoQualitySource

extension SingletonPlayerWebView: MusicVideoQualitySource {
    /// Reads the videoId the live player reports (via `currentPlaybackSnapshot`),
    /// which reflects the actually-loaded page rather than the requested id.
    func loadedVideoId() async -> String? {
        await self.currentPlaybackSnapshot()?.videoId
    }
}

// MARK: - PlayerService Video Quality

/// Resolution selection for music **video mode** (Official Music Videos).
///
/// Parallels the YouTube side's quality handling (`YouTubePlayerService`), but
/// drives the music `SingletonPlayerWebView`'s `#movie_player`. Only meaningful
/// while `showVideo` is active; audio-only playback reports no levels. See
/// ADR-0024.
///
/// Discovery is keyed to the active `videoId` (mirroring
/// `YouTubePlayerService.updatePlaybackState`), not to the video-window-open
/// transition — so the quality menu repopulates when the track changes while
/// video mode stays open, and a slow/empty first probe can retry.
extension PlayerService {
    /// Delay between quality-discovery retries. Injectable (mirrors
    /// `HistoryViewModel.playbackRefreshDelay`) so tests can set `.zero` and not
    /// block on real wall-clock time.
    static var videoQualityRetryDelay: Duration = .milliseconds(1500)

    /// Loads the resolution levels for the current video if they haven't been
    /// loaded yet. Idempotent: the per-video guard is set only **after** a
    /// successful fetch whose levels are confirmed to belong to the requested
    /// video. When the player isn't ready yet — or still has the *previous*
    /// video loaded after a skip (the WebView navigates asynchronously, and
    /// `play(song:)` updates `currentTrack` before the page changes) — it
    /// retries a few times internally rather than latching stale levels.
    /// Re-checks `showVideo`/`videoId` between attempts so it can't loop forever
    /// or leak across track changes.
    func refreshVideoQualityOptionsIfNeeded() async {
        guard self.showVideo, let videoId = self.currentTrack?.videoId else { return }
        guard self.videoQualityOptionsVideoId != videoId else { return }

        // We're about to probe a different video than whatever is currently
        // displayed: drop the previous video's levels and fetch guard now so the
        // menu doesn't show stale resolutions while the new page loads, and a
        // previously-fetched video stays eligible for rediscovery.
        self.resetVideoQualityOptions()

        for attempt in 0 ..< 3 {
            // Confirm the player has actually navigated to the requested video
            // before trusting its quality levels — otherwise a skip can latch
            // the previous page's levels under the new videoId.
            let loadedId = await self.videoQualitySource.loadedVideoId()
            guard self.showVideo, self.currentTrack?.videoId == videoId else { return }

            let levels = loadedId == videoId ? await self.videoQualitySource.availableQualityLevels() : []

            // Bail if video mode closed or the track changed mid-fetch.
            guard self.showVideo, self.currentTrack?.videoId == videoId else { return }

            if !levels.isEmpty {
                let current = await self.videoQualitySource.currentQualityLevel()

                // Re-check after the second await as well, so a track change
                // mid-fetch can't leak the previous video's state onto the new one.
                guard self.showVideo, self.currentTrack?.videoId == videoId else { return }

                self.videoQualityLevels = levels
                self.currentVideoQuality = current
                self.videoQualityOptionsVideoId = videoId
                return
            }

            // Player not ready / still on the old page; wait and retry (guard
            // stays unset).
            if attempt < 2 {
                try? await Task.sleep(for: Self.videoQualityRetryDelay)
                guard self.showVideo, self.currentTrack?.videoId == videoId else { return }
            }
        }
    }

    /// Selects a playback resolution and remembers it optimistically.
    func selectVideoQuality(_ level: String) {
        self.currentVideoQuality = level
        self.videoQualitySource.setQualityLevel(level)
        HapticService.toggle()
    }

    /// Fully clears per-track quality state, including the fetch guard, so the
    /// next discovery for any video (including one whose options were previously
    /// fetched) re-probes rather than short-circuiting. Called when starting
    /// discovery for a new video, when the active video changes, and when video
    /// playback stops.
    func resetVideoQualityOptions() {
        self.videoQualityLevels = []
        self.currentVideoQuality = nil
        self.videoQualityOptionsVideoId = nil
    }
}
