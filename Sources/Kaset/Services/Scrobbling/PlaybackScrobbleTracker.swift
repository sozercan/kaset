import Foundation

struct PlaybackScrobbleTracker {
    struct Thresholds {
        let percent: Double
        let minSeconds: TimeInterval
        var minScrobbleDuration: TimeInterval = 30
        var allowsUnknownDuration = false
    }

    let startTime: Date

    private(set) var accumulatedPlayTime: TimeInterval = 0

    private(set) var hasScrobbled = false

    private(set) var hasSentNowPlaying = false

    private(set) var lastProgress: TimeInterval

    private var lastProgressTime: Date?

    init(startTime: Date, initialProgress: TimeInterval = 0) {
        self.startTime = startTime
        self.lastProgress = initialProgress
    }

    @discardableResult
    mutating func accumulate(progress: TimeInterval, isPlaying: Bool, now: Date) -> TimeInterval {
        defer {
            self.lastProgress = progress
            self.lastProgressTime = isPlaying ? now : nil
        }

        guard isPlaying, let lastTime = self.lastProgressTime else { return 0 }

        let wallClockDelta = now.timeIntervalSince(lastTime)
        let progressDelta = progress - self.lastProgress

        if progressDelta > 0, progressDelta < 2.0, wallClockDelta < 2.0 {
            self.accumulatedPlayTime += progressDelta
            return progressDelta
        }
        return 0
    }

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

    mutating func creditVerifiedPlayTime(_ duration: TimeInterval) {
        self.accumulatedPlayTime += max(0, duration)
    }

    mutating func markScrobbled() {
        self.hasScrobbled = true
    }

    mutating func clearScrobbledLatch() {
        self.hasScrobbled = false
    }

    mutating func markNowPlayingSent() {
        self.hasSentNowPlaying = true
    }

    mutating func resetForSeek() {
        self.accumulatedPlayTime = 0
    }
}
