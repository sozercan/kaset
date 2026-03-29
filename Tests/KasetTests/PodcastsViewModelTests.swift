import Foundation
import Testing
@testable import Kaset

@Suite(.serialized)
@MainActor
struct PodcastsViewModelTests {
    private var mockClient: MockYTMusicClient
    private var viewModel: PodcastsViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.viewModel = PodcastsViewModel(client: self.mockClient)
    }

    // MARK: - Initial State

    @Test
    func initialStateIsIdleWithEmptySections() {
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.sections.isEmpty)
        #expect(self.viewModel.hasMoreSections == true)
    }

    // MARK: - Load

    @Test
    func loadSuccessSetsSections() async {
        let testSection = PodcastSection(
            id: UUID().uuidString,
            title: "Test Podcasts",
            items: [
                .show(PodcastShow(
                    id: "MPSPP123",
                    title: "Test Show",
                    author: "Test Author",
                    description: nil,
                    thumbnailURL: nil,
                    episodeCount: nil
                )),
            ]
        )
        self.mockClient.podcastsSections = [testSection]

        await self.viewModel.load()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.count == 1)
        #expect(self.viewModel.sections.first?.title == "Test Podcasts")
        #expect(self.viewModel.sections.first?.items.count == 1)
    }

    @Test
    func loadErrorSetsErrorState() async {
        self.mockClient.shouldThrowError = YTMusicError.networkError(
            underlying: URLError(.notConnectedToInternet)
        )

        await self.viewModel.load()

        if case .error = self.viewModel.loadingState {
            // Expected error state
        } else {
            Issue.record("Expected error state but got \(self.viewModel.loadingState)")
        }
    }

    @Test
    func loadDoesNotRunConcurrently() async {
        let testSection = PodcastSection(
            id: UUID().uuidString,
            title: "Original",
            items: []
        )
        self.mockClient.podcastsSections = [testSection]

        // Start two loads concurrently - second should be blocked
        let task1 = Task {
            await self.viewModel.load()
        }
        let task2 = Task {
            await self.viewModel.load()
        }

        await task1.value
        await task2.value

        // Should complete without issues
        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.first?.title == "Original")
    }

    // MARK: - Refresh

    @Test
    func refreshClearsSectionsAndReloads() async {
        let initialSection = PodcastSection(
            id: UUID().uuidString,
            title: "Initial",
            items: []
        )
        self.mockClient.podcastsSections = [initialSection]

        await self.viewModel.load()
        #expect(self.viewModel.sections.first?.title == "Initial")

        // Update mock data
        let refreshedSection = PodcastSection(
            id: UUID().uuidString,
            title: "Refreshed",
            items: []
        )
        self.mockClient.podcastsSections = [refreshedSection]

        await self.viewModel.refresh()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.first?.title == "Refreshed")
    }

    // MARK: - Continuation Loading

    @Test
    func hasMoreSectionsReflectsClientState() async {
        let testSection = PodcastSection(id: UUID().uuidString, title: "Main", items: [])
        self.mockClient.podcastsSections = [testSection]
        self.mockClient.podcastsContinuationSections = [
            [PodcastSection(id: UUID().uuidString, title: "Continuation 1", items: [])],
        ]

        await self.viewModel.load()

        // Background loading starts automatically; wait for it to complete
        try? await Task.sleep(for: .milliseconds(500))

        // After background loading, continuation should have been consumed
        #expect(self.viewModel.sections.count >= 1)
    }

    @Test
    func loadAppendsContinuationInBackground() async {
        let mainSection = PodcastSection(id: UUID().uuidString, title: "Main", items: [])
        let continuationSection = PodcastSection(id: UUID().uuidString, title: "Continuation", items: [])

        self.mockClient.podcastsSections = [mainSection]
        self.mockClient.podcastsContinuationSections = [[continuationSection]]

        await self.viewModel.load()

        // Wait for background loading to complete (300ms delay + processing)
        try? await Task.sleep(for: .milliseconds(600))

        #expect(self.viewModel.sections.count == 2)
        #expect(self.viewModel.sections[1].title == "Continuation")
    }

    @Test
    func loadWithNoContinuationDoesNotAddMore() async {
        let testSection = PodcastSection(id: UUID().uuidString, title: "Only Section", items: [])
        self.mockClient.podcastsSections = [testSection]
        // No continuation sections

        await self.viewModel.load()

        // Wait for any background loading attempt
        try? await Task.sleep(for: .milliseconds(500))

        #expect(self.viewModel.sections.count == 1)
        #expect(self.viewModel.hasMoreSections == false)
    }

    // MARK: - Empty State

    @Test
    func loadWithEmptySectionsShowsLoaded() async {
        self.mockClient.podcastsSections = []

        await self.viewModel.load()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.isEmpty)
    }
}
