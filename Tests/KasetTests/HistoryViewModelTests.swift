import Foundation
import Testing
@testable import Kaset

/// Tests for HistoryViewModel using mock client.
@Suite(.serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct HistoryViewModelTests {
    var mockClient: MockYTMusicClient
    var viewModel: HistoryViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.viewModel = HistoryViewModel(client: self.mockClient)
    }

    @Test("Initial state is idle with empty sections")
    func initialState() {
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.sections.isEmpty)
    }

    @Test("Load success sets sections")
    func loadSuccess() async {
        let expectedSections = [
            TestFixtures.makeHomeSection(title: "Today"),
            TestFixtures.makeHomeSection(title: "Yesterday"),
        ]
        self.mockClient.historyResponse = HomeResponse(sections: expectedSections)

        await self.viewModel.load()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.count == 2)
        #expect(self.viewModel.sections[0].title == "Today")
        #expect(self.viewModel.sections[1].title == "Yesterday")
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

    @Test("Refresh clears sections and reloads")
    func refreshClearsSectionsAndReloads() async {
        self.mockClient.historyResponse = TestFixtures.makeHomeResponse(sectionCount: 2)
        await self.viewModel.load()
        #expect(self.viewModel.sections.count == 2)

        self.mockClient.historyResponse = TestFixtures.makeHomeResponse(sectionCount: 3)
        await self.viewModel.refresh()

        #expect(self.viewModel.sections.count == 3)
    }
}
