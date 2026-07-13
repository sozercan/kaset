import Foundation

// MARK: - PlaybackScrobbleTracker

/// Accumulates verified play time for a single playable item — a whole track or one sub-track
/// within a mix — and decides when it has been played enough to scrobble.
///
/// This is a pure state machine: it owns no queue, no network, and no clock. The
/// `ScrobblingCoordinator` drives it (feeding progress observations and the wall clock) and owns
/// the side effects (enqueue, now-playing fan-out). It is the single source of truth for the
/// accumulate / seek-rejection / threshold / latch logic that previously lived twice — once for
/// single-track playback and once for mix sub-tracks — and had already drifted between the two.
struct PlaybackScrobbleTracker {
    /// Thresholds controlling when accumulated play time counts as a scrobble.
    struct Thresholds {
        /// Fraction of the item's duration that must be played (e.g. 0.5).
        let percent: Double
        /// Absolute play time that always qualifies, regardless of duration.
        let minSeconds: TimeInterval
        /// Minimum item duration Last.fm will accept (items shorter than this never scrobble).
        var minScrobbleDuration: TimeInterval = 30
        /// When true, an unknown/zero duration still qualifies via `minSeconds` alone. Mix
        /// sub-tracks (whose final entry has no known end) rely on this; whole tracks always
        /// have a duration and set it false.
        var allowsUnknownDuration = false
    }

    /// When accumulation started — used as the scrobble timestamp.
    let startTime: Date

    /// Verified play time accumulated so far, in seconds.
    private(set) var accumulatedPlayTime: TimeInterval = 0

    /// Whether this item has already been scrobbled (latched to fire once).
    private(set) var hasScrobbled = false

    /// Whether a "now playing" update has been sent for this item (latched to fire once).
    private(set) var hasSentNowPlaying = false

    /// Last observed progress value — read by the coordinator for replay/seek detection.
    private(set) var lastProgress: TimeInterval

    /// Wall-clock time of the last counted progress update; nil while paused or before the first.
    private var lastProgressTime: Date?

    init(startTime: Date, initialProgress: TimeInterval = 0) {
        self.startTime = startTime
        self.lastProgress = initialProgress
    }

    /// Records a progress observation. Counts only small positive deltas that also fall within a
    /// small wall-clock window, so seeks and suspend/resume gaps can't inflate play time. Pausing
    /// (isPlaying == false) drops the wall-clock baseline so the paused span isn't counted on resume.
    @discardableResult
    mutating func accumulate(progress: TimeInterval, isPlaying: Bool, now: Date) -> TimeInterval {
        defer {
            self.lastProgress = progress
            self.lastProgressTime = isPlaying ? now : nil
        }

        guard isPlaying, let lastTime = self.lastProgressTime else { return 0 }

        let wallClockDelta = now.timeIntervalSince(lastTime)
        let progressDelta = progress - self.lastProgress

        // A normal playback tick advances ~1s or less; anything larger is a seek or a gap.
        if progressDelta > 0, progressDelta < 2.0, wallClockDelta < 2.0 {
            self.accumulatedPlayTime += progressDelta
            return progressDelta
        }
        return 0
    }

    /// Whether accumulated play time has reached the scrobble threshold for the given duration.
    /// Pure — the coordinator calls this each poll with the item's current best-known duration
    /// (which for whole tracks may only become available after playback starts).
    func meetsThreshold(duration: TimeInterval?, thresholds: Thresholds) -> Bool {
        Self.meetsThreshold(
            accumulatedPlayTime: self.accumulatedPlayTime,
            duration: duration,
            thresholds: thresholds
        )
    }

    static func meetsThreshold(
        accumulatedPlayTime: TimeInterval,
        duration: TimeInterval?,
        thresholds: Thresholds
    ) -> Bool {
        let duration = duration ?? 0

        if duration <= 0 {
            return thresholds.allowsUnknownDuration && accumulatedPlayTime >= thresholds.minSeconds
        }

        guard duration >= thresholds.minScrobbleDuration else { return false }

        return accumulatedPlayTime >= duration * thresholds.percent
            || accumulatedPlayTime >= thresholds.minSeconds
    }

    /// Adds already-verified playback (for example, samples captured while mix metadata loaded).
    mutating func creditVerifiedPlayTime(_ duration: TimeInterval) {
        self.accumulatedPlayTime += max(0, duration)
    }

    /// Latches the scrobbled flag once the coordinator has enqueued the scrobble.
    mutating func markScrobbled() {
        self.hasScrobbled = true
    }

    /// Clears a provisional latch after final duration data makes the earlier threshold invalid.
    mutating func clearScrobbledLatch() {
        self.hasScrobbled = false
    }

    /// Latches the now-playing flag once the coordinator has sent the update.
    mutating func markNowPlayingSent() {
        self.hasSentNowPlaying = true
    }

    /// Resets accumulation after a seek within the same play, so skipped time cannot satisfy the
    /// threshold. Preserves latches, `startTime`, and `lastProgress`; a confirmed replay must use
    /// a fresh tracker so it receives a new timestamp and can scrobble independently.
    mutating func resetForSeek() {
        self.accumulatedPlayTime = 0
    }
}
