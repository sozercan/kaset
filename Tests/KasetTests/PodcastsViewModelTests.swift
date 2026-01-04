import Testing

@testable import Kaset

@Suite(.serialized)
@MainActor
struct PodcastsViewModelTests {
    private var mockClient: MockYTMusicClient
    private var viewModel: PodcastsViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.viewModel = PodcastsViewModel(ytMusicClient: self.mockClient)
    }

    // MARK: - Initial State

    @Test
    func initialStateIsIdleWithEmptySections() {
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.sections.isEmpty)
        #expect(self.viewModel.hasMoreSections == false)
    }

    // MARK: - Load

    @Test
    func loadSuccessSetsSections() async {
        let testSection = PodcastSection(
            title: "Test Podcasts",
            shows: [
                PodcastShow(
                    id: "MPSPP123",
                    title: "Test Show",
                    author: "Test Author",
                    description: nil,
                    thumbnailURL: nil
                ),
            ]
        )
        self.mockClient.podcastsSections = [testSection]

        await self.viewModel.load()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.count == 1)
        #expect(self.viewModel.sections.first?.title == "Test Podcasts")
        #expect(self.viewModel.sections.first?.shows.count == 1)
    }

    @Test
    func loadErrorSetsErrorState() async {
        self.mockClient.shouldThrowError = true

        await self.viewModel.load()

        if case .error = self.viewModel.loadingState {
            // Expected error state
        } else {
            Issue.record("Expected error state but got \(self.viewModel.loadingState)")
        }
    }

    @Test
    func loadDoesNotReloadWhenAlreadyLoaded() async {
        let testSection = PodcastSection(
            title: "Original",
            shows: []
        )
        self.mockClient.podcastsSections = [testSection]

        await self.viewModel.load()
        #expect(self.viewModel.sections.first?.title == "Original")

        // Change mock data
        self.mockClient.podcastsSections = [PodcastSection(title: "Changed", shows: [])]

        // Load again - should not reload since already loaded
        await self.viewModel.load()
        #expect(self.viewModel.sections.first?.title == "Original")
    }

    // MARK: - Refresh

    @Test
    func refreshClearsSectionsAndReloads() async {
        let initialSection = PodcastSection(
            title: "Initial",
            shows: []
        )
        self.mockClient.podcastsSections = [initialSection]

        await self.viewModel.load()
        #expect(self.viewModel.sections.first?.title == "Initial")

        // Update mock data
        let refreshedSection = PodcastSection(
            title: "Refreshed",
            shows: []
        )
        self.mockClient.podcastsSections = [refreshedSection]

        await self.viewModel.refresh()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.first?.title == "Refreshed")
    }

    // MARK: - Continuation Loading

    @Test
    func hasMoreSectionsReflectsClientState() async {
        let testSection = PodcastSection(title: "Main", shows: [])
        self.mockClient.podcastsSections = [testSection]
        self.mockClient.podcastsContinuationSections = [
            [PodcastSection(title: "Continuation 1", shows: [])],
        ]

        await self.viewModel.load()

        #expect(self.viewModel.hasMoreSections == true)
    }

    @Test
    func loadMoreSectionsAppendsContinuation() async {
        let mainSection = PodcastSection(title: "Main", shows: [])
        let continuationSection = PodcastSection(title: "Continuation", shows: [])

        self.mockClient.podcastsSections = [mainSection]
        self.mockClient.podcastsContinuationSections = [[continuationSection]]

        await self.viewModel.load()
        #expect(self.viewModel.sections.count == 1)
        #expect(self.viewModel.hasMoreSections == true)

        await self.viewModel.loadMoreSectionsIfNeeded()

        #expect(self.viewModel.sections.count == 2)
        #expect(self.viewModel.sections[1].title == "Continuation")
    }

    @Test
    func loadMoreSectionsDoesNothingWhenNoMore() async {
        let testSection = PodcastSection(title: "Only Section", shows: [])
        self.mockClient.podcastsSections = [testSection]
        // No continuation sections

        await self.viewModel.load()
        #expect(self.viewModel.hasMoreSections == false)

        await self.viewModel.loadMoreSectionsIfNeeded()

        #expect(self.viewModel.sections.count == 1)
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
