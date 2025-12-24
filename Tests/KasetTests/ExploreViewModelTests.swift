import Foundation
import Testing
@testable import Kaset

/// Tests for ExploreViewModel using mock client.
@Suite(.serialized)
@MainActor
struct ExploreViewModelTests {
    var mockClient: MockYTMusicClient
    var viewModel: ExploreViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.viewModel = ExploreViewModel(client: self.mockClient)
    }

    @Test("Initial state is idle with empty sections")
    func initialState() {
        #expect(viewModel.loadingState == .idle)
        #expect(viewModel.sections.isEmpty)
    }

    @Test("Load success filters out Charts section")
    func loadSuccess() async {
        // "Charts" section is filtered out by ExploreViewModel since it's in the sidebar
        let expectedSections = [
            TestFixtures.makeHomeSection(title: "New releases"),
            TestFixtures.makeHomeSection(title: "Charts"),
            TestFixtures.makeHomeSection(title: "Moods & genres"),
        ]
        mockClient.exploreResponse = HomeResponse(sections: expectedSections)

        await viewModel.load()

        #expect(mockClient.getExploreCalled == true)
        #expect(viewModel.loadingState == .loaded)
        // "Charts" section is filtered out, so we expect 2 sections
        #expect(viewModel.sections.count == 2)
        #expect(viewModel.sections[0].title == "New releases")
        #expect(viewModel.sections[1].title == "Moods & genres")
    }

    @Test("Load error sets error state")
    func loadError() async {
        mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.timedOut))

        await viewModel.load()

        #expect(mockClient.getExploreCalled == true)
        if case .error = viewModel.loadingState {
            // Expected
        } else {
            Issue.record("Expected error state")
        }
        #expect(viewModel.sections.isEmpty)
    }

    @Test("Load does not duplicate when already loading")
    func loadDoesNotDuplicateWhenAlreadyLoading() async {
        mockClient.exploreResponse = TestFixtures.makeHomeResponse(sectionCount: 1)

        await viewModel.load()
        await viewModel.load()

        #expect(mockClient.getExploreCallCount == 2)
    }

    @Test("Refresh clears sections and reloads")
    func refreshClearsSectionsAndReloads() async {
        mockClient.exploreResponse = TestFixtures.makeHomeResponse(sectionCount: 2)
        await viewModel.load()
        #expect(viewModel.sections.count == 2)

        mockClient.exploreResponse = TestFixtures.makeHomeResponse(sectionCount: 4)
        await viewModel.refresh()

        #expect(viewModel.sections.count == 4)
        #expect(mockClient.getExploreCallCount == 2)
    }
}
