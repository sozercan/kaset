import Foundation

// MARK: - HorizontalSwipeSkipDetector

/// Turns a stream of scroll-wheel deltas into discrete track-skip actions.
///
/// One continuous two-finger trackpad swipe fires exactly one action: deltas
/// accumulate from the gesture's `began` phase and, once the horizontal
/// distance passes the threshold (and dominates the vertical distance), the
/// action fires and latches until the gesture ends. Momentum events are
/// ignored entirely so a flick can never fire twice.
///
/// Legacy devices that report no gesture phases (classic scroll wheels) are
/// handled with a time-gap accumulator reset and a minimum interval between
/// fires.
///
/// Pure value type with injected timestamps — unit-testable without AppKit.
/// The call site maps from `NSEvent` (see `PlayerBar`).
struct HorizontalSwipeSkipDetector {
    // MARK: - Types

    enum SkipAction: Equatable {
        case next
        case previous
    }

    /// Gesture phase, mirroring the `NSEvent.Phase` cases the detector cares about.
    enum Phase {
        case began
        case changed
        case ended
        case cancelled
        /// No phase information (legacy scroll wheels) or phases the detector ignores.
        case none
    }

    // MARK: - Tuning

    /// Accumulated horizontal points required to trigger a skip.
    static let threshold: CGFloat = 60

    /// Minimum interval between fires for non-phased (legacy wheel) input.
    static let legacyMinFireInterval: TimeInterval = 0.5

    /// Gap after which legacy accumulation resets (treated as a new gesture).
    static let legacyGapReset: TimeInterval = 0.25

    /// Maps physical finger direction to a skip action. Fingers moving right
    /// skip forward. Flip this single constant if the mapping feels inverted
    /// on real hardware.
    static let fingersRightSkipsForward = true

    // MARK: - State

    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var hasFiredForGesture = false
    private var lastLegacyEventTime: TimeInterval = 0
    private var lastLegacyFireTime: TimeInterval = 0

    // MARK: - Processing

    /// Feeds one scroll event; returns a skip action when a swipe commits.
    ///
    /// - Parameters:
    ///   - deltaX/deltaY: `scrollingDeltaX`/`scrollingDeltaY` from the event.
    ///   - phase: gesture phase of the event.
    ///   - hasMomentumPhase: `true` when the event's `momentumPhase` is
    ///     non-empty — such events are ignored so momentum never re-fires.
    ///   - isDirectionInvertedFromDevice: `NSEvent.isDirectionInvertedFromDevice`,
    ///     used to normalize deltas back to physical finger direction so the
    ///     mapping is stable regardless of the natural-scrolling setting.
    ///   - timestamp: event time in seconds (legacy debounce only).
    mutating func process(
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: Phase,
        hasMomentumPhase: Bool,
        isDirectionInvertedFromDevice: Bool,
        timestamp: TimeInterval
    ) -> SkipAction? {
        guard !hasMomentumPhase else { return nil }

        // With natural scrolling ("inverted from device"), deltas already follow
        // the fingers; without it, flip so `fingerX > 0` always means fingers
        // moved right.
        let fingerX = isDirectionInvertedFromDevice ? deltaX : -deltaX

        switch phase {
        case .began:
            self.accumulatedX = fingerX
            self.accumulatedY = deltaY
            self.hasFiredForGesture = false
            return nil

        case .changed:
            self.accumulatedX += fingerX
            self.accumulatedY += deltaY
            return self.fireIfCommitted()

        case .ended, .cancelled:
            self.accumulatedX = 0
            self.accumulatedY = 0
            return nil

        case .none:
            // Legacy wheel: reset after a quiet gap, accumulate, and rate-limit fires.
            if timestamp - self.lastLegacyEventTime > Self.legacyGapReset {
                self.accumulatedX = 0
                self.accumulatedY = 0
                self.hasFiredForGesture = false
            }
            self.lastLegacyEventTime = timestamp
            self.accumulatedX += fingerX
            self.accumulatedY += deltaY

            guard timestamp - self.lastLegacyFireTime >= Self.legacyMinFireInterval else { return nil }
            let action = self.fireIfCommitted()
            if action != nil {
                self.lastLegacyFireTime = timestamp
            }
            return action
        }
    }

    /// Fires once per gesture when the horizontal distance passes the threshold
    /// and dominates the vertical distance.
    private mutating func fireIfCommitted() -> SkipAction? {
        guard !self.hasFiredForGesture,
              abs(self.accumulatedX) >= Self.threshold,
              abs(self.accumulatedX) > abs(self.accumulatedY)
        else {
            return nil
        }

        self.hasFiredForGesture = true
        let fingersMovedRight = self.accumulatedX > 0
        return fingersMovedRight == Self.fingersRightSkipsForward ? .next : .previous
    }
}
