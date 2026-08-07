import Foundation

// MARK: - NowPlayingTracklistProvider

/// Owns the sub-track breakdown (a `MixTracklist`) of the currently-playing item and the machinery
/// that fetches it for playback UI. It is the segmented seek bar's source of truth for "what are the
/// sub-tracks of the now-playing video." `ScrobblingCoordinator` retains a separate classification
/// state machine for provisional credit, timeouts, and post-exit finalization; both consumers share
/// the cached, in-flight-coalescing `MixTracklistParser`.
///
/// It is deliberately decoupled from scrobbling: mix segmentation is a playback concern, so the
/// fetch runs regardless of whether Last.fm is connected. The provider is *driven* — `PlayerService`
/// calls `update(track:duration:)` whenever the current track or its correlated playback duration
/// changes — but owns all the fetch policy: the once-per-video latch and the duration gate that
/// together resolve the race where YouTube reports a track's duration a beat after the track object
/// appears.
@MainActor
@Observable
final class NowPlayingTracklistProvider {
    /// The tracklist for the currently-playing item, or nil when it isn't a mix (or isn't known yet).
    private(set) var tracklist: MixTracklist?

    /// Minimum correlated playback duration before attempting a tracklist fetch: below this a video
    /// can't be a mix worth segmenting. Matches the scrobbler's mix-detection floor.
    private static let minMixDuration: TimeInterval = 600

    private let parser: MixTracklistParser?
    private let retryDelay: Duration
    private let maxTransientRetryAttempts: Int
    private let logger = DiagnosticsLogger.player

    /// Video id currently being tracked; a change resets the latch and clears the tracklist.
    private var currentVideoId: String?

    /// Video id a fetch has already been started for — latches the fetch to run at most once per
    /// video even though `update` is called repeatedly as duration settles.
    private var attemptedVideoId: String?

    /// In-flight parse for the current video. Cancelled on video changes so a slow request for the
    /// previous video never blocks or overwrites the next one.
    private var parseTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var parseGeneration = 0
    private var transientRetryAttempts = 0

    /// Whether a tracklist parse is in flight for the current video. Consumers that would act on
    /// "this is not a mix" (e.g. whole-track scrobbling) should wait until this settles.
    var isParsing: Bool {
        self.parseTask != nil || self.retryTask != nil
    }

    init(
        parser: MixTracklistParser?,
        retryDelay: Duration = .seconds(1),
        maxTransientRetryAttempts: Int = 1
    ) {
        self.parser = parser
        self.retryDelay = retryDelay
        self.maxTransientRetryAttempts = max(0, maxTransientRetryAttempts)
    }

    /// Drive the provider from playback observation. Idempotent and cheap: it resets on a video
    /// change, then attempts the fetch once the correlated observed duration crosses the mix
    /// threshold. Safe to call on every track/duration mutation — once a fetch has been attempted for
    /// a video it returns immediately.
    func update(track: Song?, duration: TimeInterval) {
        guard let track else {
            self.reset(to: nil)
            return
        }

        let normalizedVideoId = track.videoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedVideoId.isEmpty, normalizedVideoId != "unknown" else {
            self.reset(to: nil)
            return
        }

        if track.videoId != self.currentVideoId {
            self.reset(to: track.videoId)
        }

        guard self.tracklist == nil,
              self.attemptedVideoId != track.videoId,
              duration > Self.minMixDuration
        else { return }

        guard let parser else { return }

        self.attemptedVideoId = track.videoId
        let videoId = track.videoId
        let title = track.title
        let generation = self.parseGeneration
        self.parseTask = Task { [weak self] in
            let parsed = await parser.parseTracklist(videoId: videoId)
            guard let self else { return }
            guard self.currentVideoId == videoId, self.parseGeneration == generation else { return }
            self.parseTask = nil
            guard !Task.isCancelled else { return }
            if let parsed, parsed.isMix {
                self.tracklist = parsed
                self.logger.info("Now-playing tracklist loaded: \(parsed.entries.count) sub-tracks for \(title)")
                return
            }
            guard !parser.hasCachedResult(for: videoId) else { return }
            self.scheduleTransientRetry(
                track: track,
                duration: duration,
                videoId: videoId,
                generation: generation
            )
        }
    }

    private func scheduleTransientRetry(
        track: Song,
        duration: TimeInterval,
        videoId: String,
        generation: Int
    ) {
        guard self.transientRetryAttempts < self.maxTransientRetryAttempts else { return }
        self.transientRetryAttempts += 1
        let delay = self.retryDelay
        self.retryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.currentVideoId == videoId,
                  self.parseGeneration == generation
            else { return }

            self.retryTask = nil
            self.attemptedVideoId = nil
            self.update(track: track, duration: duration)
        }
    }

    /// The sub-track active at the given playback progress, or nil outside any entry / when not a mix.
    func currentEntry(at progress: TimeInterval) -> MixTrackEntry? {
        self.tracklist?.entry(at: progress)
    }

    private func reset(to videoId: String?) {
        self.parseTask?.cancel()
        self.parseTask = nil
        self.retryTask?.cancel()
        self.retryTask = nil
        self.parseGeneration &+= 1
        self.currentVideoId = videoId
        self.attemptedVideoId = nil
        self.transientRetryAttempts = 0
        self.tracklist = nil
    }
}
