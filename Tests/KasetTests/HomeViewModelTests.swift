import Foundation
import Testing
@testable import Kaset

/// Tests for HomeViewModel using mock client.
@Suite(.serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct HomeViewModelTests {
    var mockClient: MockYTMusicClient
    var viewModel: HomeViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.viewModel = HomeViewModel(client: self.mockClient)
    }

    @Test("Initial state is idle with empty sections")
    func initialState() {
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.sections.isEmpty)
    }

    @Test("Load success sets sections")
    func loadSuccess() async {
        let expectedSections = [
            TestFixtures.makeHomeSection(title: "Quick picks"),
            TestFixtures.makeHomeSection(title: "Recommended"),
        ]
        self.mockClient.homeResponse = HomeResponse(sections: expectedSections)

        await self.viewModel.load()

        #expect(self.mockClient.getHomeCalled == true)
        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.count == 2)
        #expect(self.viewModel.sections[0].title == "Quick picks")
        #expect(self.viewModel.sections[1].title == "Recommended")
    }

    @Test("Initial home load does not drain continuations in the background")
    func initialLoadDoesNotDrainContinuationsInBackground() async {
        self.mockClient.homeResponse = HomeResponse(sections: [TestFixtures.makeHomeSection(title: "Initial")])
        self.mockClient.homeContinuationSections = [
            [TestFixtures.makeHomeSection(title: "Continuation 1")],
            [TestFixtures.makeHomeSection(title: "Continuation 2")],
        ]

        await self.viewModel.load()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.map(\.title) == ["Initial"])
        #expect(self.viewModel.hasMoreSections == true)
        #expect(self.mockClient.getHomeContinuationCallCount == 0)
    }

    @Test("Load more fetches one home continuation per demand")
    func loadMoreFetchesOneHomeContinuationPerDemand() async {
        self.mockClient.homeResponse = HomeResponse(sections: [TestFixtures.makeHomeSection(title: "Initial")])
        self.mockClient.homeContinuationSections = [
            [TestFixtures.makeHomeSection(title: "Continuation 1")],
            [TestFixtures.makeHomeSection(title: "Continuation 2")],
        ]

        await self.viewModel.load()
        await self.viewModel.loadMore()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.map(\.title) == ["Initial", "Continuation 1"])
        #expect(self.viewModel.hasMoreSections == true)
        #expect(self.mockClient.getHomeContinuationCallCount == 1)

        await self.viewModel.loadMore()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.map(\.title) == ["Initial", "Continuation 1", "Continuation 2"])
        #expect(self.viewModel.hasMoreSections == false)
        #expect(self.mockClient.getHomeContinuationCallCount == 2)
    }

    @Test("Load does not overlap an in-flight home continuation")
    func loadDoesNotOverlapInFlightContinuation() async {
        let continuationGate = AsyncGate()
        self.mockClient.homeResponse = HomeResponse(sections: [TestFixtures.makeHomeSection(title: "Initial")])
        self.mockClient.homeContinuationSections = [
            [TestFixtures.makeHomeSection(title: "Continuation")],
        ]
        self.mockClient.beforeGetHomeContinuationReturn = {
            await continuationGate.wait()
        }

        await self.viewModel.load()
        let continuationLoad = Task { await self.viewModel.loadMore() }
        while self.mockClient.getHomeContinuationCallCount == 0 {
            await Task.yield()
        }

        await self.viewModel.load()

        #expect(self.mockClient.getHomeCallCount == 1)
        await continuationGate.open()
        await continuationLoad.value
        #expect(self.viewModel.sections.map(\.title) == ["Initial", "Continuation"])
    }

    @Test("Load error sets error state")
    func loadError() async {
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.viewModel.load()

        #expect(self.mockClient.getHomeCalled == true)
        if case let .error(error) = viewModel.loadingState {
            #expect(!error.message.isEmpty)
            #expect(error.isRetryable)
        } else {
            Issue.record("Expected error state")
        }
        #expect(self.viewModel.sections.isEmpty)
    }

    @Test("Load does not duplicate when already loading")
    func loadDoesNotDuplicateWhenAlreadyLoading() async {
        self.mockClient.homeResponse = TestFixtures.makeHomeResponse(sectionCount: 1)

        await self.viewModel.load()
        await self.viewModel.load()

        #expect(self.mockClient.getHomeCallCount == 2)
    }

    @Test("Refresh clears sections and reloads")
    func refreshClearsSectionsAndReloads() async {
        self.mockClient.homeResponse = TestFixtures.makeHomeResponse(sectionCount: 2)
        await self.viewModel.load()
        #expect(self.viewModel.sections.count == 2)

        self.mockClient.homeResponse = TestFixtures.makeHomeResponse(sectionCount: 3)
        await self.viewModel.refresh()

        #expect(self.viewModel.sections.count == 3)
        #expect(self.mockClient.getHomeCallCount == 2)
    }

    @Test("Refresh replaces an in-flight home load")
    func refreshReplacesInFlightHomeLoad() async {
        let firstLoadGate = AsyncGate()
        self.mockClient.homeResponse = HomeResponse(sections: [TestFixtures.makeHomeSection(title: "Initial")])
        self.mockClient.beforeGetHomeReturn = { [mockClient = self.mockClient] in
            if mockClient.getHomeCallCount == 1 {
                await firstLoadGate.wait()
            }
        }

        let firstLoad = Task { await self.viewModel.load() }
        while self.mockClient.getHomeCallCount == 0 {
            await Task.yield()
        }

        self.mockClient.homeResponse = HomeResponse(sections: [TestFixtures.makeHomeSection(title: "Refreshed")])
        let refresh = Task { await self.viewModel.refresh() }
        await Task.yield()
        #expect(self.mockClient.getHomeCallCount == 1)

        await firstLoadGate.open()
        await refresh.value
        await firstLoad.value

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.map(\.title) == ["Refreshed"])
        #expect(self.mockClient.getHomeCallCount == 2)
    }

    @Test("Concurrent refreshes coalesce after an in-flight home load")
    func concurrentRefreshesCoalesceAfterInFlightLoad() async {
        let initialLoadGate = AsyncGate()
        self.mockClient.homeResponse = HomeResponse(sections: [TestFixtures.makeHomeSection(title: "Initial")])
        self.mockClient.beforeGetHomeReturn = { [mockClient = self.mockClient] in
            if mockClient.getHomeCallCount == 1 {
                await initialLoadGate.wait()
            }
        }

        let initialLoad = Task { await self.viewModel.load() }
        while self.mockClient.getHomeCallCount == 0 {
            await Task.yield()
        }

        self.mockClient.homeResponse = HomeResponse(sections: [TestFixtures.makeHomeSection(title: "Refreshed")])
        let firstRefresh = Task { await self.viewModel.refresh() }
        let secondRefresh = Task { await self.viewModel.refresh() }

        await initialLoadGate.open()
        await firstRefresh.value
        await secondRefresh.value
        await initialLoad.value

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.map(\.title) == ["Refreshed"])
        #expect(self.mockClient.getHomeCallCount == 2)
    }

    @Test("Refresh requested after an active refresh fetch runs a follow-up")
    func laterRefreshDuringActiveRefreshRunsFollowUp() async {
        let firstRefreshGate = AsyncGate()
        self.mockClient.homeResponse = HomeResponse(sections: [TestFixtures.makeHomeSection(title: "Old Account")])
        self.mockClient.beforeGetHomeReturn = { [mockClient = self.mockClient] in
            if mockClient.getHomeCallCount == 1 {
                await firstRefreshGate.wait()
            }
        }

        let firstRefresh = Task { await self.viewModel.refresh() }
        while self.mockClient.getHomeCallCount == 0 {
            await Task.yield()
        }

        self.mockClient.homeResponse = HomeResponse(sections: [TestFixtures.makeHomeSection(title: "New Account")])
        let laterRefresh = Task { await self.viewModel.refresh() }
        await Task.yield()
        #expect(self.mockClient.getHomeCallCount == 1)

        await firstRefreshGate.open()
        await firstRefresh.value
        await laterRefresh.value

        #expect(self.mockClient.getHomeCallCount == 2)
        #expect(self.viewModel.sections.map(\.title) == ["New Account"])
    }
}
