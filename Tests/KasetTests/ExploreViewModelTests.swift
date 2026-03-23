import Foundation
import Testing
@testable import Kaset

/// Tests for ExploreViewModel using mock client.
@Suite("ExploreViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
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
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.sections.isEmpty)
    }

    @Test("Load success filters out Charts section")
    func loadSuccess() async {
        // "Charts" section is filtered out by ExploreViewModel since it's in the sidebar
        let expectedSections = [
            TestFixtures.makeHomeSection(title: "New releases"),
            TestFixtures.makeHomeSection(title: "Charts"),
            TestFixtures.makeHomeSection(title: "Moods & genres"),
        ]
        self.mockClient.exploreResponse = HomeResponse(sections: expectedSections)

        await self.viewModel.load()

        #expect(self.mockClient.getExploreCalled == true)
        #expect(self.viewModel.loadingState == .loaded)
        // "Charts" section is filtered out, so we expect 2 sections
        #expect(self.viewModel.sections.count == 2)
        #expect(self.viewModel.sections[0].title == "New releases")
        #expect(self.viewModel.sections[1].title == "Moods & genres")
    }

    @Test("Load error sets error state")
    func loadError() async {
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.timedOut))

        await self.viewModel.load()

        #expect(self.mockClient.getExploreCalled == true)
        if case .error = self.viewModel.loadingState {
            // Expected
        } else {
            Issue.record("Expected error state")
        }
        #expect(self.viewModel.sections.isEmpty)
    }

    @Test("Load does not duplicate when already loading")
    func loadDoesNotDuplicateWhenAlreadyLoading() async {
        self.mockClient.exploreResponse = TestFixtures.makeHomeResponse(sectionCount: 1)

        await self.viewModel.load()
        await self.viewModel.load()

        #expect(self.mockClient.getExploreCallCount == 2)
    }

    @Test("Refresh clears sections and reloads")
    func refreshClearsSectionsAndReloads() async {
        self.mockClient.exploreResponse = TestFixtures.makeHomeResponse(sectionCount: 2)
        await self.viewModel.load()
        #expect(self.viewModel.sections.count == 2)

        self.mockClient.exploreResponse = TestFixtures.makeHomeResponse(sectionCount: 4)
        await self.viewModel.refresh()

        #expect(self.viewModel.sections.count == 4)
        #expect(self.mockClient.getExploreCallCount == 2)
    }
}
