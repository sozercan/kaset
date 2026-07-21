import Foundation
import Testing
@testable import Kaset

/// Tests for the scroll-wheel swipe-to-skip state machine used by PlayerBar.
@Suite(.tags(.model))
struct HorizontalSwipeSkipDetectorTests {
    private typealias Detector = HorizontalSwipeSkipDetector

    /// Feeds one event with natural scrolling enabled (deltas follow fingers).
    private func feed(
        _ detector: inout Detector,
        deltaX: CGFloat,
        deltaY: CGFloat = 0,
        phase: Detector.Phase,
        hasMomentumPhase: Bool = false,
        inverted: Bool = true,
        timestamp: TimeInterval = 0
    ) -> Detector.SkipAction? {
        detector.process(
            deltaX: deltaX,
            deltaY: deltaY,
            phase: phase,
            hasMomentumPhase: hasMomentumPhase,
            isDirectionInvertedFromDevice: inverted,
            timestamp: timestamp
        )
    }

    // MARK: - Phased gestures (trackpad)

    @Test("One continuous swipe past the threshold fires exactly once")
    func firesOncePerGesture() {
        var detector = Detector()
        #expect(self.feed(&detector, deltaX: 10, phase: .began) == nil)
        #expect(self.feed(&detector, deltaX: 30, phase: .changed) == nil)
        #expect(self.feed(&detector, deltaX: 30, phase: .changed) == .next)
        // Continuing the same gesture never re-fires.
        #expect(self.feed(&detector, deltaX: 100, phase: .changed) == nil)
        #expect(self.feed(&detector, deltaX: 100, phase: .changed) == nil)
        #expect(self.feed(&detector, deltaX: 0, phase: .ended) == nil)
    }

    @Test("Below-threshold swipe fires nothing")
    func belowThreshold() {
        var detector = Detector()
        #expect(self.feed(&detector, deltaX: 10, phase: .began) == nil)
        #expect(self.feed(&detector, deltaX: 20, phase: .changed) == nil)
        #expect(self.feed(&detector, deltaX: 0, phase: .ended) == nil)
    }

    @Test("Vertically dominant scrolls never skip")
    func verticalDominance() {
        var detector = Detector()
        #expect(self.feed(&detector, deltaX: 10, deltaY: 40, phase: .began) == nil)
        #expect(self.feed(&detector, deltaX: 60, deltaY: 100, phase: .changed) == nil)
    }

    @Test("Momentum events after the gesture never fire")
    func momentumIgnored() {
        var detector = Detector()
        #expect(self.feed(&detector, deltaX: 10, phase: .began) == nil)
        #expect(self.feed(&detector, deltaX: 60, phase: .changed) == .next)
        #expect(self.feed(&detector, deltaX: 0, phase: .ended) == nil)
        // Momentum carries large deltas but must be ignored entirely.
        #expect(self.feed(&detector, deltaX: 200, phase: .changed, hasMomentumPhase: true) == nil)
        #expect(self.feed(&detector, deltaX: 200, phase: .none, hasMomentumPhase: true) == nil)
    }

    @Test("A new gesture after a completed one can fire again")
    func newGestureFiresAgain() {
        var detector = Detector()
        #expect(self.feed(&detector, deltaX: 70, phase: .began) == nil)
        #expect(self.feed(&detector, deltaX: 1, phase: .changed) == .next)
        #expect(self.feed(&detector, deltaX: 0, phase: .ended) == nil)

        #expect(self.feed(&detector, deltaX: -70, phase: .began) == nil)
        #expect(self.feed(&detector, deltaX: -1, phase: .changed) == .previous)
    }

    // MARK: - Direction mapping

    @Test("Fingers right skips next, fingers left skips previous (natural scrolling)")
    func directionNatural() {
        var next = Detector()
        _ = self.feed(&next, deltaX: 0, phase: .began)
        #expect(self.feed(&next, deltaX: 80, phase: .changed, inverted: true) == .next)

        var previous = Detector()
        _ = self.feed(&previous, deltaX: 0, phase: .began)
        #expect(self.feed(&previous, deltaX: -80, phase: .changed, inverted: true) == .previous)
    }

    @Test("Non-natural scrolling normalizes back to physical finger direction")
    func directionNonNatural() {
        // With natural scrolling off, AppKit reports deltas opposite to the
        // fingers; a negative delta means fingers moved right.
        var next = Detector()
        _ = self.feed(&next, deltaX: 0, phase: .began, inverted: false)
        #expect(self.feed(&next, deltaX: -80, phase: .changed, inverted: false) == .next)

        var previous = Detector()
        _ = self.feed(&previous, deltaX: 0, phase: .began, inverted: false)
        #expect(self.feed(&previous, deltaX: 80, phase: .changed, inverted: false) == .previous)
    }

    // MARK: - Legacy (non-phased) input

    @Test("Legacy wheel fires on threshold and rate-limits subsequent fires")
    func legacyDebounce() {
        var detector = Detector()
        #expect(self.feed(&detector, deltaX: 40, phase: .none, timestamp: 1.00) == nil)
        #expect(self.feed(&detector, deltaX: 40, phase: .none, timestamp: 1.05) == .next)
        // Within the minimum fire interval: accumulation continues but no fire.
        #expect(self.feed(&detector, deltaX: 80, phase: .none, timestamp: 1.10) == nil)
    }

    @Test("Legacy accumulation resets after a quiet gap")
    func legacyGapReset() {
        var detector = Detector()
        #expect(self.feed(&detector, deltaX: 40, phase: .none, timestamp: 1.0) == nil)
        // Gap larger than the reset window: the earlier 40pt is discarded.
        #expect(self.feed(&detector, deltaX: 40, phase: .none, timestamp: 2.0) == nil)
        #expect(self.feed(&detector, deltaX: 40, phase: .none, timestamp: 2.05) == .next)
    }
}
