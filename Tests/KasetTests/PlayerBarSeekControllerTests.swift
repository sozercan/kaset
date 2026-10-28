import Foundation
import Observation
import Testing
@testable import Kaset

// MARK: - PlayerBarSeekControllerTests

@Suite(.tags(.model))
@MainActor
struct PlayerBarSeekControllerTests {
    @Test("Progress ticks without a pending seek don't notify hold observers")
    func progressTickWithoutHoldDoesNotNotifyHoldObservers() {
        let controller = PlayerBarSeekController()
        let flag = ObservationFlag()
        withObservationTracking {
            _ = controller.hold
        } onChange: {
            flag.fired = true
        }

        controller.progressDidChange(12, duration: 300)
        controller.durationDidChange(301, progress: 12)

        #expect(!flag.fired)
    }

    @Test("cancelScrub ends a drag without seeking")
    func cancelScrubEndsDrag() {
        let controller = PlayerBarSeekController()
        controller.scrub(to: 0.4)
        #expect(controller.isSeeking)

        controller.cancelScrub()

        #expect(!controller.isSeeking)
        #expect(!controller.hold.isActive)
    }

    @Test("Mini player progress ticks without a pending seek don't notify hold observers")
    func miniPlayerTickWithoutHoldDoesNotNotifyHoldObservers() {
        let state = MiniPlayerSeekState()
        let flag = ObservationFlag()
        withObservationTracking {
            _ = state.hold
        } onChange: {
            flag.fired = true
        }

        state.reconcileHold(observedProgress: 12)

        #expect(!flag.fired)
    }

    @Test("Mini player progress that confirms a pending seek clears the hold")
    func miniPlayerConfirmedSeekClearsHold() {
        let state = MiniPlayerSeekState()
        state.hold.begin(target: 42, issuedAt: Date().addingTimeInterval(-1))
        let flag = ObservationFlag()
        withObservationTracking {
            _ = state.hold
        } onChange: {
            flag.fired = true
        }

        state.reconcileHold(observedProgress: 42)

        #expect(flag.fired)
        #expect(!state.hold.isActive)
    }
}

// MARK: - ObservationFlag

/// Records whether an observation fired; only touched on the main actor in these tests.
private final class ObservationFlag: @unchecked Sendable {
    var fired = false
}
