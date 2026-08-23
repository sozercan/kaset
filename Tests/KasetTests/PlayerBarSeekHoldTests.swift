import Foundation
import Testing
@testable import Kaset

// MARK: - PlayerBarSeekHoldTests

@Suite(.tags(.model))
struct PlayerBarSeekHoldTests {
    @Test("begin holds the requested target for display")
    func beginHoldsTargetForDisplay() {
        var hold = PlayerBarSeekHold()
        hold.begin(target: 42)

        #expect(hold.isActive)
        #expect(hold.targetProgress == 42)
        #expect(hold.displayProgress(observedProgress: 10) == 42)
    }

    @Test("begin clamps negative target to zero")
    func beginClampsNegativeTarget() {
        var hold = PlayerBarSeekHold()
        hold.begin(target: -3)

        #expect(hold.targetProgress == 0)
        #expect(hold.displayProgress(observedProgress: 12) == 0)
    }

    @Test("reconcile waits for the minimum confirmation age")
    func reconcileWaitsForMinimumConfirmationAge() {
        let issuedAt = Date(timeIntervalSinceReferenceDate: 100)
        var hold = PlayerBarSeekHold()
        hold.begin(target: 30, issuedAt: issuedAt)

        hold.reconcile(
            observedProgress: 30,
            now: issuedAt.addingTimeInterval(0.34)
        )

        #expect(hold.isActive)
        #expect(hold.targetProgress == 30)
    }

    @Test("reconcile clears after a matching progress confirmation")
    func reconcileClearsAfterMatchingConfirmation() {
        let issuedAt = Date(timeIntervalSinceReferenceDate: 100)
        var hold = PlayerBarSeekHold()
        hold.begin(target: 30, issuedAt: issuedAt)

        hold.reconcile(
            observedProgress: 30.5,
            now: issuedAt.addingTimeInterval(0.36)
        )

        #expect(!hold.isActive)
        #expect(hold.targetProgress == nil)
        #expect(hold.displayProgress(observedProgress: 31) == 31)
    }

    @Test("reconcile keeps holding progress outside confirmation tolerance")
    func reconcileKeepsProgressOutsideTolerance() {
        let issuedAt = Date(timeIntervalSinceReferenceDate: 100)
        var hold = PlayerBarSeekHold()
        hold.begin(target: 30, issuedAt: issuedAt)

        hold.reconcile(
            observedProgress: 32,
            now: issuedAt.addingTimeInterval(0.5)
        )

        #expect(hold.isActive)
        #expect(hold.displayProgress(observedProgress: 32) == 30)
    }

    @Test("reconcile clears when timeout elapses")
    func reconcileClearsWhenTimeoutElapses() {
        let issuedAt = Date(timeIntervalSinceReferenceDate: 100)
        var hold = PlayerBarSeekHold()
        hold.begin(target: 30, issuedAt: issuedAt)

        hold.reconcile(
            observedProgress: 5,
            now: issuedAt.addingTimeInterval(2.21)
        )

        #expect(!hold.isActive)
        #expect(hold.targetProgress == nil)
    }

    @Test("clearIfCurrent only clears the active hold ID")
    func clearIfCurrentRequiresMatchingID() {
        var hold = PlayerBarSeekHold()
        let activeID = hold.begin(target: 30)

        let staleClearResult = hold.clearIfCurrent(UUID())

        #expect(!staleClearResult)
        #expect(hold.isActive)

        let activeClearResult = hold.clearIfCurrent(activeID)

        #expect(activeClearResult)
        #expect(!hold.isActive)
    }
}
