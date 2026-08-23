import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct MoodsAndGenresViewModelTests {
    var mockClient: MockYTMusicClient
    var viewModel: MoodsAndGenresViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.viewModel = MoodsAndGenresViewModel(client: self.mockClient)
    }

    // MARK: - Initial State Tests

    @Test("Initial state is idle")
    func initialStateIsIdle() {
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.sections.isEmpty)
        #expect(self.viewModel.hasMoreSections == true)
    }

    // MARK: - Load Tests

    @Test("Load success sets sections and loaded state")
    func loadSuccessSetsData() async {
        self.mockClient.moodsAndGenresResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Moods"),
            TestFixtures.makeHomeSection(title: "Genres"),
        ])

        await self.viewModel.load()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.count == 2)
        #expect(self.viewModel.sections[0].title == "Moods")
        #expect(self.viewModel.sections[1].title == "Genres")
    }

    @Test("Load error sets error state")
    func loadErrorSetsErrorState() async {
        self.mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )

        await self.viewModel.load()

        if case .error = self.viewModel.loadingState {
            // Expected
        } else {
            Issue.record("Expected error state, got \(self.viewModel.loadingState)")
        }
    }

    @Test("Load does not run concurrently when already loading")
    func loadPreventsConncurrentCalls() async {
        self.mockClient.moodsAndGenresResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Section 1"),
        ])

        // Start first load
        let task1 = Task {
            await self.viewModel.load()
        }

        // Try to start another load immediately
        try? await Task.sleep(for: .milliseconds(20))
        let task2 = Task {
            await self.viewModel.load()
        }

        await task1.value
        await task2.value

        // Should complete without issues
        #expect(self.viewModel.loadingState == .loaded)
    }

    // MARK: - Background Continuation Tests

    @Test("Initial load does not drain continuations")
    func initialLoadDoesNotDrainContinuations() async {
        self.mockClient.moodsAndGenresResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Initial"),
        ])
        self.mockClient.moodsAndGenresContinuationSections = [
            [TestFixtures.makeHomeSection(title: "Continuation 1")],
        ]

        await self.viewModel.load()

        #expect(self.viewModel.sections.map(\.title) == ["Initial"])
        #expect(self.viewModel.hasMoreSections == true)
        #expect(self.mockClient.getMoodsAndGenresContinuationCallCount == 0)
    }

    @Test("Load more appends one continuation per demand")
    func loadMoreAppendsOneContinuationPerDemand() async {
        self.mockClient.moodsAndGenresResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Initial"),
        ])
        self.mockClient.moodsAndGenresContinuationSections = [
            [TestFixtures.makeHomeSection(title: "Continuation 1")],
            [TestFixtures.makeHomeSection(title: "Continuation 2")],
        ]

        await self.viewModel.load()
        await self.viewModel.loadMore()

        #expect(self.viewModel.sections.map(\.title) == ["Initial", "Continuation 1"])
        #expect(self.viewModel.hasMoreSections == true)
        #expect(self.mockClient.getMoodsAndGenresContinuationCallCount == 1)

        await self.viewModel.loadMore()

        #expect(self.viewModel.sections.map(\.title) == ["Initial", "Continuation 1", "Continuation 2"])
        #expect(self.viewModel.hasMoreSections == false)
        #expect(self.mockClient.getMoodsAndGenresContinuationCallCount == 2)
    }

    @Test("No continuations means no more sections after load")
    func noContinuationsMeansNoMoreSections() async {
        self.mockClient.moodsAndGenresResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Initial"),
        ])
        // No continuation sections → hasMoreMoodsAndGenresSections will be false

        await self.viewModel.load()

        #expect(self.viewModel.hasMoreSections == false)
    }

    // MARK: - Refresh Tests

    @Test("Refresh clears sections and reloads")
    func refreshClearsAndReloads() async {
        // Initial load
        self.mockClient.moodsAndGenresResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Initial"),
        ])
        // No continuation sections
        await self.viewModel.load()
        #expect(self.viewModel.sections.count == 1)

        // Refresh with different data
        self.mockClient.moodsAndGenresResponse = HomeResponse(sections: [
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
        self.mockClient.moodsAndGenresResponse = HomeResponse(sections: [])
        // No continuation sections
        await self.viewModel.load()
        #expect(self.viewModel.hasMoreSections == false)

        // Refresh - add continuation sections so hasMore becomes true
        self.mockClient.moodsAndGenresContinuationSections = [
            [TestFixtures.makeHomeSection(title: "Continuation")],
        ]
        await self.viewModel.refresh()

        #expect(self.viewModel.hasMoreSections == true)
    }

    // MARK: - Client Exposure Tests

    @Test("Client is exposed for navigation")
    func clientIsExposed() {
        #expect(self.viewModel.client is MockYTMusicClient)
    }
}
