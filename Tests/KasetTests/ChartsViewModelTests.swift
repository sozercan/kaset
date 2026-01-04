import Foundation
import Testing
@testable import Kaset

/// Tests for ChartsViewModel using mock client.
@Suite("ChartsViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct ChartsViewModelTests {
    var mockClient: MockYTMusicClient
    var viewModel: ChartsViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.viewModel = ChartsViewModel(client: self.mockClient)
    }

    // MARK: - Initial State Tests

    @Test("Initial state is idle with empty sections")
    func initialState() {
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.sections.isEmpty)
        #expect(self.viewModel.hasMoreSections == true)
    }

    // MARK: - Load Tests

    @Test("Load success sets sections")
    func loadSuccess() async {
        let expectedSections = [
            TestFixtures.makeHomeSection(title: "Top Songs", isChart: true),
            TestFixtures.makeHomeSection(title: "Trending", isChart: true),
        ]
        self.mockClient.chartsResponse = HomeResponse(sections: expectedSections)

        await self.viewModel.load()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.count == 2)
        #expect(self.viewModel.sections[0].title == "Top Songs")
        #expect(self.viewModel.sections[1].title == "Trending")
    }

    @Test("Load error sets error state")
    func loadError() async {
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.viewModel.load()

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
        self.mockClient.chartsResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Charts"),
        ])

        await self.viewModel.load()
        await self.viewModel.load()

        #expect(self.viewModel.loadingState == .loaded)
    }

    // MARK: - Continuation Tests

    @Test("Load triggers background continuation loading")
    func loadTriggersBackgroundContinuation() async {
        let initialSections = [TestFixtures.makeHomeSection(title: "Initial")]
        let continuationSections = [TestFixtures.makeHomeSection(title: "More Charts")]

        self.mockClient.chartsResponse = HomeResponse(sections: initialSections)
        self.mockClient.chartsContinuationSections = [continuationSections]

        await self.viewModel.load()

        // Wait for background loading to complete
        try? await Task.sleep(for: .milliseconds(500))

        #expect(self.viewModel.sections.count == 2)
        #expect(self.viewModel.sections[1].title == "More Charts")
    }

    @Test("hasMoreSections updates after continuations")
    func hasMoreSectionsUpdatesAfterContinuations() async {
        let initialSections = [TestFixtures.makeHomeSection(title: "Initial")]

        self.mockClient.chartsResponse = HomeResponse(sections: initialSections)
        // No continuation sections

        await self.viewModel.load()

        // Wait for background loading to complete
        try? await Task.sleep(for: .milliseconds(500))

        #expect(self.viewModel.hasMoreSections == false)
    }

    // MARK: - Refresh Tests

    @Test("Refresh clears sections and reloads")
    func refreshClearsSectionsAndReloads() async {
        self.mockClient.chartsResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Old Chart"),
        ])
        await self.viewModel.load()
        #expect(self.viewModel.sections.count >= 1)

        self.mockClient.chartsResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "New Chart 1"),
            TestFixtures.makeHomeSection(title: "New Chart 2"),
        ])

        await self.viewModel.refresh()

        #expect(self.viewModel.sections.first?.title == "New Chart 1")
    }

    @Test("Refresh resets continuation state")
    func refreshResetsContinuationState() async {
        self.mockClient.chartsResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Chart"),
        ])
        self.mockClient.chartsContinuationSections = [
            [TestFixtures.makeHomeSection(title: "More")],
        ]

        await self.viewModel.load()
        try? await Task.sleep(for: .milliseconds(500))

        // After load, hasMoreSections should be false (continuations exhausted)
        #expect(self.viewModel.hasMoreSections == false)

        // Reset continuation for refresh
        self.mockClient.chartsContinuationSections = [
            [TestFixtures.makeHomeSection(title: "Even More")],
        ]

        await self.viewModel.refresh()

        #expect(self.viewModel.hasMoreSections == true)
    }
}
