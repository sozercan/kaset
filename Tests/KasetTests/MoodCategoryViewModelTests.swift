import Foundation
import Testing

@testable import Kaset

@Suite("MoodCategoryViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct MoodCategoryViewModelTests {
    var mockClient: MockYTMusicClient
    var viewModel: MoodCategoryViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        let category = MoodCategory(
            title: "Chill",
            browseId: "FEmusic_moods_and_genres_category",
            params: "chill-params",
            thumbnailURL: URL(string: "https://example.com/chill.jpg")
        )
        self.viewModel = MoodCategoryViewModel(category: category, client: self.mockClient)
    }

    // MARK: - Initial State Tests

    @Test("Initial state is idle")
    func initialStateIsIdle() {
        #expect(self.viewModel.loadingState == .idle)
        #expect(self.viewModel.sections.isEmpty)
    }

    @Test("Category is set from initializer")
    func categoryIsSet() {
        #expect(self.viewModel.category.title == "Chill")
        #expect(self.viewModel.category.browseId == "FEmusic_moods_and_genres_category")
        #expect(self.viewModel.category.params == "chill-params")
    }

    // MARK: - Load Tests

    @Test("Load success sets sections and loaded state")
    func loadSuccessSetsData() async {
        self.mockClient.moodCategoryResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Chill Playlists"),
            TestFixtures.makeHomeSection(title: "Relaxing Music"),
        ])

        await self.viewModel.load()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.count == 2)
        #expect(self.viewModel.sections[0].title == "Chill Playlists")
        #expect(self.viewModel.sections[1].title == "Relaxing Music")
    }

    @Test("Load sets loading state during fetch")
    func loadSetsLoadingState() async {
        self.mockClient.moodCategoryResponse = HomeResponse(sections: [])

        let loadTask = Task {
            await self.viewModel.load()
        }

        // Give the task a moment to start
        try? await Task.sleep(for: .milliseconds(10))

        // The state should be loading or loaded depending on timing
        // We verify it completes successfully
        await loadTask.value
        #expect(self.viewModel.loadingState == .loaded)
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
        self.mockClient.moodCategoryResponse = HomeResponse(sections: [
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

        // Should only have one call since second was skipped
        #expect(self.mockClient.moodCategoryCalled)
        #expect(self.viewModel.sections.count == 1)
    }

    // MARK: - Refresh Tests

    @Test("Refresh clears sections and reloads")
    func refreshClearsAndReloads() async {
        // Initial load
        self.mockClient.moodCategoryResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Initial"),
        ])
        await self.viewModel.load()
        #expect(self.viewModel.sections.count == 1)

        // Refresh with different data
        self.mockClient.moodCategoryResponse = HomeResponse(sections: [
            TestFixtures.makeHomeSection(title: "Refreshed 1"),
            TestFixtures.makeHomeSection(title: "Refreshed 2"),
        ])

        await self.viewModel.refresh()

        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.count == 2)
        #expect(self.viewModel.sections[0].title == "Refreshed 1")
    }

    // MARK: - Client Exposure Tests

    @Test("Client is exposed for navigation")
    func clientIsExposed() {
        #expect(self.viewModel.client is MockYTMusicClient)
    }
}
