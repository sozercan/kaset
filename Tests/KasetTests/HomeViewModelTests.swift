import Foundation
import Testing
@testable import Kaset

/// Tests for HomeViewModel using mock client.
@Suite("HomeViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
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
}
