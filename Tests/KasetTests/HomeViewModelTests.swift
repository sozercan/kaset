import Foundation
import Testing
@testable import Kaset

/// Tests for HomeViewModel using mock client.
@Suite(.serialized)
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
        #expect(viewModel.loadingState == .idle)
        #expect(viewModel.sections.isEmpty)
    }

    @Test("Load success sets sections")
    func loadSuccess() async {
        let expectedSections = [
            TestFixtures.makeHomeSection(title: "Quick picks"),
            TestFixtures.makeHomeSection(title: "Recommended"),
        ]
        mockClient.homeResponse = HomeResponse(sections: expectedSections)

        await viewModel.load()

        #expect(mockClient.getHomeCalled == true)
        #expect(viewModel.loadingState == .loaded)
        #expect(viewModel.sections.count == 2)
        #expect(viewModel.sections[0].title == "Quick picks")
        #expect(viewModel.sections[1].title == "Recommended")
    }

    @Test("Load error sets error state")
    func loadError() async {
        mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await viewModel.load()

        #expect(mockClient.getHomeCalled == true)
        if case let .error(message) = viewModel.loadingState {
            #expect(!message.isEmpty)
        } else {
            Issue.record("Expected error state")
        }
        #expect(viewModel.sections.isEmpty)
    }

    @Test("Load does not duplicate when already loading")
    func loadDoesNotDuplicateWhenAlreadyLoading() async {
        mockClient.homeResponse = TestFixtures.makeHomeResponse(sectionCount: 1)

        await viewModel.load()
        await viewModel.load()

        #expect(mockClient.getHomeCallCount == 2)
    }

    @Test("Refresh clears sections and reloads")
    func refreshClearsSectionsAndReloads() async {
        mockClient.homeResponse = TestFixtures.makeHomeResponse(sectionCount: 2)
        await viewModel.load()
        #expect(viewModel.sections.count == 2)

        mockClient.homeResponse = TestFixtures.makeHomeResponse(sectionCount: 3)
        await viewModel.refresh()

        #expect(viewModel.sections.count == 3)
        #expect(mockClient.getHomeCallCount == 2)
    }
}
