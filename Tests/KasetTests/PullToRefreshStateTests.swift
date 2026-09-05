import Testing
@testable import Kaset

@Suite("PullToRefreshState")
struct PullToRefreshStateTests {
    @Test("A short pull does not refresh when released")
    func shortPullDoesNotRefresh() {
        var state = PullToRefreshState()

        state.update(
            pullDistance: PullToRefreshState.threshold - 1,
            isInteracting: true
        )
        let didRefresh = state.release(pullDistance: PullToRefreshState.threshold - 1)
        state.update(pullDistance: 0, isInteracting: false)

        #expect(didRefresh == false)
        #expect(state.isRefreshing == false)
        #expect(state.phase == .idle)
    }

    @Test("An armed pull refreshes once when released")
    func armedPullRefreshesOnce() {
        var state = PullToRefreshState()

        state.update(pullDistance: PullToRefreshState.threshold, isInteracting: true)
        #expect(state.isArmed)
        let didRefresh = state.release(pullDistance: PullToRefreshState.threshold)
        #expect(didRefresh)
        #expect(state.isRefreshing)
        let duplicateRefresh = state.release(pullDistance: PullToRefreshState.threshold)
        #expect(duplicateRefresh == false)
    }

    @Test("Finishing a refresh allows the next pull")
    func finishingRefreshAllowsNextPull() {
        var state = PullToRefreshState()

        state.update(pullDistance: PullToRefreshState.threshold, isInteracting: true)
        let firstRefresh = state.release(pullDistance: PullToRefreshState.threshold)
        #expect(firstRefresh)

        state.update(pullDistance: 0, isInteracting: false)
        state.finishRefreshing()

        state.update(pullDistance: PullToRefreshState.threshold, isInteracting: true)
        let secondRefresh = state.release(pullDistance: PullToRefreshState.threshold)
        #expect(secondRefresh)
    }

    @Test("An armed pull can be cancelled before release")
    func armedPullCanBeCancelled() {
        var state = PullToRefreshState()

        state.update(pullDistance: PullToRefreshState.threshold, isInteracting: true)
        #expect(state.isArmed)

        state.update(
            pullDistance: PullToRefreshState.disarmThreshold - 1,
            isInteracting: true
        )
        #expect(state.isArmed == false)
        let didRefresh = state.release(pullDistance: PullToRefreshState.disarmThreshold - 1)
        #expect(didRefresh == false)
    }

    @Test("A completed action waits for rubber-banding to settle")
    func completedActionWaitsForSettling() {
        var state = PullToRefreshState()

        state.update(pullDistance: PullToRefreshState.threshold, isInteracting: true)
        let didRefresh = state.release(pullDistance: PullToRefreshState.threshold)
        #expect(didRefresh)

        state.finishRefreshing()
        #expect(state.phase == .settling)

        state.update(pullDistance: 0, isInteracting: false)
        #expect(state.phase == .idle)
    }

    @Test("Pull distance is normalized against the top inset")
    func pullDistanceAccountsForInset() {
        #expect(PullToRefreshState.normalizedPullDistance(
            contentOffsetY: -20,
            topInset: 20
        ) == 0)
        #expect(PullToRefreshState.normalizedPullDistance(
            contentOffsetY: -84,
            topInset: 20
        ) == 64)
    }

    @Test("A programmatic refresh returns directly to idle")
    func programmaticRefreshReturnsToIdle() {
        var state = PullToRefreshState()

        let didRefresh = state.beginRefreshing()
        #expect(didRefresh)
        #expect(state.phase == .refreshing)

        state.finishRefreshing()
        #expect(state.phase == .idle)
    }
}
