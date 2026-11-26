import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct NewReleasesViewModelTests {
    var mockClient: MockYTMusicClient
    var viewModel: NewReleasesViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.viewModel = NewReleasesViewModel(client: self.mockClient)
    }

    @Test("Initial state is idle")
    func initialStateIsIdle() {
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.sections.isEmpty)
        #expect(self.viewModel.hasMoreSections == true)
    }

    @Test("Load success sets sections and loaded state")
    func loadSuccessSetsData() async {
        self.mockClient.newReleasesResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "New Albums"),
            TestFixtures.makeHomeSection(title: "New Singles"),
        ])

        await self.viewModel.load()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.count == 2)
        #expect(self.viewModel.sections[0].title == "New Albums")
        #expect(self.viewModel.sections[1].title == "New Singles")
    }

    @Test("Load error sets error state")
    func loadErrorSetsErrorState() async {
        self.mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )

        await self.viewModel.load()

        if case .error = self.viewModel.loadingState {
        } else {
            Issue.record("Expected error state, got \(self.viewModel.loadingState)")
        }
    }

    @Test("Load does not run concurrently when already loading")
    func loadPreventsConncurrentCalls() async {
        self.mockClient.newReleasesResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Section 1"),
        ])

        let task1 = Task {
            await self.viewModel.load()
        }

        try? await Task.sleep(for: .milliseconds(20))
        let task2 = Task {
            await self.viewModel.load()
        }

        await task1.value
        await task2.value

        #expect(self.viewModel.loadingState == .loaded)
    }

    @Test("Initial load does not drain continuations")
    func initialLoadDoesNotDrainContinuations() async {
        self.mockClient.newReleasesResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Initial"),
        ])
        self.mockClient.newReleasesContinuationSections = [
            [TestFixtures.makeHomeSection(title: "Continuation 1")],
        ]

        await self.viewModel.load()

        #expect(self.viewModel.sections.map(\.title) == ["Initial"])
        #expect(self.viewModel.hasMoreSections == true)
        #expect(self.mockClient.getNewReleasesContinuationCallCount == 0)
    }

    @Test("Load more appends one continuation per demand")
    func loadMoreAppendsOneContinuationPerDemand() async {
        self.mockClient.newReleasesResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Initial"),
        ])
        self.mockClient.newReleasesContinuationSections = [
            [TestFixtures.makeHomeSection(title: "Continuation 1")],
            [TestFixtures.makeHomeSection(title: "Continuation 2")],
        ]

        await self.viewModel.load()
        await self.viewModel.loadMore()

        #expect(self.viewModel.sections.map(\.title) == ["Initial", "Continuation 1"])
        #expect(self.viewModel.hasMoreSections == true)
        #expect(self.mockClient.getNewReleasesContinuationCallCount == 1)

        await self.viewModel.loadMore()

        #expect(self.viewModel.sections.map(\.title) == ["Initial", "Continuation 1", "Continuation 2"])
        #expect(self.viewModel.hasMoreSections == false)
        #expect(self.mockClient.getNewReleasesContinuationCallCount == 2)
    }

    @Test("No continuations means no more sections after load")
    func noContinuationsMeansNoMoreSections() async {
        self.mockClient.newReleasesResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Initial"),
        ])

        await self.viewModel.load()

        #expect(self.viewModel.hasMoreSections == false)
    }

    @Test("Refresh clears sections and reloads")
    func refreshClearsAndReloads() async {
        self.mockClient.newReleasesResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Initial"),
        ])
        await self.viewModel.load()
        #expect(self.viewModel.sections.count == 1)

        self.mockClient.newReleasesResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Refreshed 1"),
            TestFixtures.makeHomeSection(title: "Refreshed 2"),
        ])

        await self.viewModel.refresh()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.count == 2)
        #expect(self.viewModel.sections[0].title == "Refreshed 1")
    }

    @Test("Refresh resets hasMoreSections flag")
    func refreshResetsHasMoreSections() async {
        self.mockClient.newReleasesResponse = HomeResponse(sections: [])
        await self.viewModel.load()
        #expect(self.viewModel.hasMoreSections == false)

        self.mockClient.newReleasesContinuationSections = [
            [TestFixtures.makeHomeSection(title: "Continuation")],
        ]
        await self.viewModel.refresh()

        #expect(self.viewModel.hasMoreSections == true)
    }

    @Test("Client is exposed for navigation")
    func clientIsExposed() {
        #expect(self.viewModel.client is MockYTMusicClient)
    }
}
