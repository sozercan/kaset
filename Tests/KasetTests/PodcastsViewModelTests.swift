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

    @Test
    func initialStateIsIdleWithEmptySections() {
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.sections.isEmpty)
        #expect(self.viewModel.hasMoreSections == true)
    }

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

        let task1 = Task {
            await self.viewModel.load()
        }
        let task2 = Task {
            await self.viewModel.load()
        }

        await task1.value
        await task2.value

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.first?.title == "Original")
    }

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

    @Test
    func initialLoadDoesNotDrainContinuations() async {
        let testSection = PodcastSection(id: UUID().uuidString, title: "Main", items: [])
        self.mockClient.podcastsSections = [testSection]
        self.mockClient.podcastsContinuationSections = [
            [PodcastSection(id: UUID().uuidString, title: "Continuation 1", items: [])],
        ]

        await self.viewModel.load()

        #expect(self.viewModel.sections.map(\.title) == ["Main"])
        #expect(self.viewModel.hasMoreSections == true)
        #expect(self.mockClient.getPodcastsContinuationCallCount == 0)
    }

    @Test
    func loadMoreAppendsOneContinuationPerDemand() async {
        let mainSection = PodcastSection(id: UUID().uuidString, title: "Main", items: [])
        let firstContinuation = PodcastSection(id: UUID().uuidString, title: "Continuation 1", items: [])
        let secondContinuation = PodcastSection(id: UUID().uuidString, title: "Continuation 2", items: [])

        self.mockClient.podcastsSections = [mainSection]
        self.mockClient.podcastsContinuationSections = [[firstContinuation], [secondContinuation]]

        await self.viewModel.load()
        await self.viewModel.loadMore()

        #expect(self.viewModel.sections.map(\.title) == ["Main", "Continuation 1"])
        #expect(self.viewModel.hasMoreSections == true)
        #expect(self.mockClient.getPodcastsContinuationCallCount == 1)

        await self.viewModel.loadMore()

        #expect(self.viewModel.sections.map(\.title) == ["Main", "Continuation 1", "Continuation 2"])
        #expect(self.viewModel.hasMoreSections == false)
        #expect(self.mockClient.getPodcastsContinuationCallCount == 2)
    }

    @Test
    func loadWithNoContinuationDoesNotAddMore() async {
        let testSection = PodcastSection(id: UUID().uuidString, title: "Only Section", items: [])
        self.mockClient.podcastsSections = [testSection]

        await self.viewModel.load()

        #expect(self.viewModel.sections.count == 1)
        #expect(self.viewModel.hasMoreSections == false)
        #expect(self.mockClient.getPodcastsContinuationCallCount == 0)
    }

    @Test
    func loadWithEmptySectionsShowsLoaded() async {
        self.mockClient.podcastsSections = []

        await self.viewModel.load()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.isEmpty)
    }

    @Test
    func loadHTTP404MarksAvailabilityUnavailableAndLandsLoaded() async {
        let availability = PodcastsAvailabilityService()
        self.viewModel.configure(availabilityService: availability, accountId: "primary")
        self.mockClient.shouldThrowError = YTMusicError.apiError(message: "HTTP 404", code: 404)

        await self.viewModel.load()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.isEmpty)
        #expect(availability.availability == .unavailable)
    }

    @Test
    func configureForNewAccountResetsLoadedEmptyUnavailableState() async {
        let availability = PodcastsAvailabilityService()
        self.viewModel.configure(availabilityService: availability, accountId: "account-a")
        self.mockClient.shouldThrowError = YTMusicError.apiError(message: "HTTP 404", code: 404)

        await self.viewModel.load()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.isEmpty)
        #expect(availability.availability == .unavailable)

        self.viewModel.configure(availabilityService: availability, accountId: "account-b")

        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.sections.isEmpty)
        #expect(self.viewModel.hasMoreSections == true)
    }

    @Test
    func loadEmptyPayloadMarksAvailabilityUnavailable() async {
        let availability = PodcastsAvailabilityService()
        self.viewModel.configure(availabilityService: availability, accountId: "primary")
        self.mockClient.podcastsSections = []

        await self.viewModel.load()

        #expect(availability.availability == .unavailable)
    }

    @Test
    func loadNonEmptyPayloadMarksAvailabilityAvailable() async {
        let availability = PodcastsAvailabilityService()
        self.viewModel.configure(availabilityService: availability, accountId: "primary")
        self.mockClient.podcastsSections = [
            PodcastSection(id: UUID().uuidString, title: "Top Shows", items: []),
        ]

        await self.viewModel.load()

        #expect(availability.availability == .available)
    }

    @Test
    func loadNetworkErrorDoesNotMutateAvailability() async {
        let availability = PodcastsAvailabilityService()
        availability.markAvailable(for: "primary")
        self.viewModel.configure(availabilityService: availability, accountId: "primary")
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.timedOut))

        await self.viewModel.load()

        #expect(availability.availability == .available)
        if case .error = self.viewModel.loadingState {
        } else {
            Issue.record("Expected error state but got \(self.viewModel.loadingState)")
        }
    }
}
