import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.service))
struct PlaybackScrobbleTrackerTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func makeTracker(initialProgress: TimeInterval = 0) -> PlaybackScrobbleTracker {
        PlaybackScrobbleTracker(startTime: self.epoch, initialProgress: initialProgress)
    }

    private func thresholds(
        percent: Double = 0.5,
        minSeconds: TimeInterval = 240,
        allowsUnknownDuration: Bool = false
    ) -> PlaybackScrobbleTracker.Thresholds {
        .init(percent: percent, minSeconds: minSeconds, allowsUnknownDuration: allowsUnknownDuration)
    }

    // MARK: - Accumulation

    @Test("First observation establishes a baseline without accumulating")
    func firstObservationIsBaseline() {
        var tracker = self.makeTracker()
        tracker.accumulate(progress: 1, isPlaying: true, now: self.epoch)
        #expect(tracker.accumulatedPlayTime == 0)
        #expect(tracker.lastProgress == 1)
    }

    @Test("Normal ticks accumulate the progress delta")
    func normalTicksAccumulate() {
        var tracker = self.makeTracker()
        var now = self.epoch
        tracker.accumulate(progress: 0, isPlaying: true, now: now)
        for step in 1 ... 10 {
            now = self.epoch.addingTimeInterval(TimeInterval(step))
            tracker.accumulate(progress: TimeInterval(step), isPlaying: true, now: now)
        }
        #expect(abs(tracker.accumulatedPlayTime - 10) < 0.001)
    }

    @Test("A forward seek is not counted")
    func forwardSeekIgnored() {
        var tracker = self.makeTracker()
        tracker.accumulate(progress: 10, isPlaying: true, now: self.epoch)
        tracker.accumulate(progress: 100, isPlaying: true, now: self.epoch.addingTimeInterval(1))
        #expect(tracker.accumulatedPlayTime == 0)
    }

    @Test("A backward seek is not counted")
    func backwardSeekIgnored() {
        var tracker = self.makeTracker()
        tracker.accumulate(progress: 100, isPlaying: true, now: self.epoch)
        tracker.accumulate(progress: 10, isPlaying: true, now: self.epoch.addingTimeInterval(1))
        #expect(tracker.accumulatedPlayTime == 0)
    }

    @Test("A large wall-clock gap with a small progress delta is not counted")
    func wallClockGapIgnored() {
        var tracker = self.makeTracker()
        tracker.accumulate(progress: 0, isPlaying: true, now: self.epoch)
        // Only 1s of progress, but 60s of wall clock elapsed (app was suspended).
        tracker.accumulate(progress: 1, isPlaying: true, now: self.epoch.addingTimeInterval(60))
        #expect(tracker.accumulatedPlayTime == 0)
    }

    @Test("Pausing drops the baseline so the paused span isn't counted on resume")
    func pauseDropsBaseline() {
        var tracker = self.makeTracker()
        tracker.accumulate(progress: 0, isPlaying: true, now: self.epoch)
        tracker.accumulate(progress: 1, isPlaying: true, now: self.epoch.addingTimeInterval(1))
        #expect(abs(tracker.accumulatedPlayTime - 1) < 0.001)

        // Pause for a while.
        tracker.accumulate(progress: 1, isPlaying: false, now: self.epoch.addingTimeInterval(2))
        // Resume: the first tick after resume re-establishes the baseline, no jump counted.
        tracker.accumulate(progress: 1.5, isPlaying: true, now: self.epoch.addingTimeInterval(120))
        #expect(abs(tracker.accumulatedPlayTime - 1) < 0.001)
    }

    // MARK: - Threshold

    @Test("Percent threshold qualifies at half of a known duration")
    func percentThreshold() {
        var tracker = self.makeTracker()
        var now = self.epoch
        // Accumulate 100s over a 200s track (>= 50%).
        for step in 0 ... 100 {
            now = self.epoch.addingTimeInterval(TimeInterval(step))
            tracker.accumulate(progress: TimeInterval(step), isPlaying: true, now: now)
        }
        #expect(tracker.meetsThreshold(duration: 200, thresholds: self.thresholds()))
    }

    @Test("minSeconds cap qualifies a long track before the percent threshold")
    func minSecondsCap() {
        var tracker = self.makeTracker()
        var now = self.epoch
        // 240s accumulated on a 3600s track: below 50% but hits the 240s cap.
        for step in 0 ... 240 {
            now = self.epoch.addingTimeInterval(TimeInterval(step))
            tracker.accumulate(progress: TimeInterval(step), isPlaying: true, now: now)
        }
        #expect(tracker.meetsThreshold(duration: 3600, thresholds: self.thresholds()))
    }

    @Test("Tracks shorter than the minimum scrobble duration never qualify")
    func tooShortRejected() {
        var tracker = self.makeTracker()
        var now = self.epoch
        for step in 1 ... 20 {
            now = self.epoch.addingTimeInterval(TimeInterval(step))
            tracker.accumulate(progress: TimeInterval(step), isPlaying: true, now: now)
        }
        #expect(tracker.meetsThreshold(duration: 20, thresholds: self.thresholds()) == false)
    }

    @Test("Unknown duration qualifies via minSeconds only when allowed")
    func unknownDurationPolicy() {
        var tracker = self.makeTracker()
        var now = self.epoch
        for step in 0 ... 240 {
            now = self.epoch.addingTimeInterval(TimeInterval(step))
            tracker.accumulate(progress: TimeInterval(step), isPlaying: true, now: now)
        }
        #expect(tracker.meetsThreshold(duration: nil, thresholds: self.thresholds(allowsUnknownDuration: false)) == false)
        #expect(tracker.meetsThreshold(duration: nil, thresholds: self.thresholds(allowsUnknownDuration: true)))
    }

    // MARK: - Latches & Reset

    @Test("Scrobbled and now-playing flags latch")
    func latches() {
        var tracker = self.makeTracker()
        #expect(!tracker.hasScrobbled)
        #expect(!tracker.hasSentNowPlaying)
        tracker.markScrobbled()
        tracker.markNowPlayingSent()
        #expect(tracker.hasScrobbled)
        #expect(tracker.hasSentNowPlaying)
    }

    @Test("resetForSeek clears accumulation but preserves latches, startTime, and lastProgress")
    func resetForSeek() {
        var tracker = self.makeTracker()
        tracker.accumulate(progress: 0, isPlaying: true, now: self.epoch)
        tracker.accumulate(progress: 1, isPlaying: true, now: self.epoch.addingTimeInterval(1))
        tracker.markScrobbled()
        tracker.markNowPlayingSent()

        tracker.resetForSeek()
        #expect(tracker.accumulatedPlayTime == 0)
        #expect(tracker.hasScrobbled)
        #expect(tracker.hasSentNowPlaying)
        #expect(tracker.startTime == self.epoch)
        #expect(tracker.lastProgress == 1)
    }
}
