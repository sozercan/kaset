import Foundation

// MARK: - NowPlayingTracklistProvider

/// Owns the sub-track breakdown (a `MixTracklist`) of the currently-playing item and the machinery
/// that fetches it. This is the single source of truth for "what are the sub-tracks of the now
/// playing video", consumed by both the segmented seek bar (always) and the `ScrobblingCoordinator`
/// (when a scrobble service is connected).
///
/// It is deliberately decoupled from scrobbling: mix segmentation is a playback concern, so the
/// fetch runs regardless of whether Last.fm is connected. The provider is *driven* — `PlayerService`
/// calls `update(track:duration:)` whenever the current track or its duration changes — but owns all
/// the fetch policy: the once-per-video latch and the duration gate that together resolve the race
/// where YouTube reports a track's duration a beat after the track object appears.
@MainActor
@Observable
final class NowPlayingTracklistProvider {
    /// The tracklist for the currently-playing item, or nil when it isn't a mix (or isn't known yet).
    private(set) var tracklist: MixTracklist?

    /// Minimum known duration before attempting a tracklist fetch: below this a video can't be a mix
    /// worth segmenting. Matches the scrobbler's mix-detection floor.
    private static let minMixDuration: TimeInterval = 600

    private let parser: MixTracklistParser?
    private let logger = DiagnosticsLogger.player

    /// Video id currently being tracked; a change resets the latch and clears the tracklist.
    private var currentVideoId: String?

    /// Title/artist of the track currently being tracked, for change detection when videoId is
    /// stale. `PlayerService.updateTrackMetadata` falls back to the previous videoId when YouTube's
    /// observer hasn't reported a fresh one yet, so a real track change can arrive with an unchanged
    /// `videoId` — only the title/artist reveal it.
    private var currentTrackTitle: String?
    private var currentTrackArtist: String?

    /// Video id a fetch has already been started for — latches the fetch to run at most once per
    /// video even though `update` is called repeatedly as duration settles.
    private var attemptedVideoId: String?

    /// In-flight parse for the current video. Cancelled on video changes so a slow request for the
    /// previous video never blocks or overwrites the next one.
    private var parseTask: Task<Void, Never>?

    /// Whether a tracklist parse is in flight for the current video. Consumers that would act on
    /// "this is not a mix" (e.g. whole-track scrobbling) should wait until this settles.
    var isParsing: Bool {
        self.parseTask != nil
    }

    init(parser: MixTracklistParser?) {
        self.parser = parser
    }

    /// Drive the provider from playback observation. Idempotent and cheap: it resets on a video
    /// change, then attempts the fetch once the best-known duration crosses the mix threshold. Safe
    /// to call on every track/duration mutation — once a fetch has been attempted for a video it
    /// returns immediately.
    func update(track: Song?, duration: TimeInterval) {
        guard let track else {
            self.reset(to: nil)
            return
        }

        let videoIdChanged = track.videoId != self.currentVideoId
        let metadataChanged = self.currentVideoId != nil
            && !videoIdChanged
            && (track.title != self.currentTrackTitle || track.artistsDisplay != self.currentTrackArtist)

        if videoIdChanged || metadataChanged {
            self.reset(to: track.videoId)
        }
        self.currentTrackTitle = track.title
        self.currentTrackArtist = track.artistsDisplay

        // Duration isn't reliably available at track-start; wait until it crosses the mix threshold.
        let knownDuration = track.duration ?? duration
        guard self.tracklist == nil,
              self.attemptedVideoId != track.videoId,
              knownDuration > Self.minMixDuration
        else { return }

        guard let parser else { return }

        self.attemptedVideoId = track.videoId
        let videoId = track.videoId
        let title = track.title
        self.parseTask = Task { [weak self] in
            let parsed = await parser.parseTracklist(videoId: videoId)
            guard let self else { return }
            // Only the task for the current video owns the in-flight slot; a stale task's slot
            // was already cleared (and possibly re-occupied) by `reset(to:)`.
            if self.currentVideoId == videoId {
                self.parseTask = nil
            }
            guard !Task.isCancelled, self.currentVideoId == videoId else { return }
            if let parsed, parsed.isMix {
                self.tracklist = parsed
                self.logger.info("Now-playing tracklist loaded: \(parsed.entries.count) sub-tracks for \(title)")
            }
        }
    }

    /// The sub-track active at the given playback progress, or nil outside any entry / when not a mix.
    func currentEntry(at progress: TimeInterval) -> MixTrackEntry? {
        self.tracklist?.entry(at: progress)
    }

    private func reset(to videoId: String?) {
        self.parseTask?.cancel()
        self.parseTask = nil
        self.currentVideoId = videoId
        self.attemptedVideoId = nil
        self.tracklist = nil
    }
}
