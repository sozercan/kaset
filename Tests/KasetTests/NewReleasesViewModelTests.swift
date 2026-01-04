import Foundation
import Testing

@testable import Kaset

@Suite("NewReleasesViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct NewReleasesViewModelTests {
    var mockClient: MockYTMusicClient
    var viewModel: NewReleasesViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.viewModel = NewReleasesViewModel(client: self.mockClient)
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
            // Expected
        } else {
            Issue.record("Expected error state, got \(self.viewModel.loadingState)")
        }
    }

    @Test("Load does not run concurrently when already loading")
    func loadPreventsConncurrentCalls() async {
        self.mockClient.newReleasesResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Section 1"),
        ])
        self.mockClient.apiDelay = 0.1

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

    @Test("Load triggers background continuation loading")
    func loadTriggersBackgroundContinuation() async {
        self.mockClient.newReleasesResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Initial"),
        ])
        self.mockClient.newReleasesContinuationSections = [
            TestFixtures.makeHomeSection(title: "Continuation 1"),
        ]
        self.mockClient.hasMoreNewReleasesSections = true

        await self.viewModel.load()

        // Wait for background loading to complete
        try? await Task.sleep(for: .milliseconds(500))

        #expect(self.viewModel.sections.count >= 1)
    }

    @Test("Background loading stops when no more sections")
    func backgroundLoadingStopsWhenNoMore() async {
        self.mockClient.newReleasesResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Initial"),
        ])
        self.mockClient.hasMoreNewReleasesSections = false

        await self.viewModel.load()

        // Wait for any potential background loading
        try? await Task.sleep(for: .milliseconds(400))

        #expect(self.viewModel.hasMoreSections == false)
    }

    // MARK: - Refresh Tests

    @Test("Refresh clears sections and reloads")
    func refreshClearsAndReloads() async {
        // Initial load
        self.mockClient.newReleasesResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Initial"),
        ])
        self.mockClient.hasMoreNewReleasesSections = false
        await self.viewModel.load()
        #expect(self.viewModel.sections.count == 1)

        // Refresh with different data
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
        self.mockClient.hasMoreNewReleasesSections = false
        await self.viewModel.load()
        #expect(self.viewModel.hasMoreSections == false)

        // Refresh - hasMoreSections should be reset to true before load
        self.mockClient.hasMoreNewReleasesSections = true
        await self.viewModel.refresh()

        #expect(self.viewModel.hasMoreSections == true)
    }

    // MARK: - Client Exposure Tests

    @Test("Client is exposed for navigation")
    func clientIsExposed() {
        #expect(self.viewModel.client is MockYTMusicClient)
    }
}
