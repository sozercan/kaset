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
        HistoryViewModel.playbackRefreshDelay = .seconds(3)
        HistoryViewModel.playbackRefreshRetryDelay = .seconds(2)
    }

    private func waitForBackgroundLoading(
        timeout: Duration = .seconds(3),
        until condition: @escaping () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while clock.now < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        Issue.record("Timed out waiting for background history loading")
    }

    private func waitForHistoryRefresh(
        timeout: Duration = .seconds(3),
        until condition: @escaping () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while clock.now < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        Issue.record("Timed out waiting for playback-triggered history refresh")
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

    @Test("Refresh preserves already loaded paginated sections when first page is unchanged")
    func refreshPreservesPaginatedSectionsWhenFirstPageIsUnchanged() async {
        let initialSection = TestFixtures.makeHomeSection(id: "today", title: "Today")
        let paginatedSection = TestFixtures.makeHomeSection(id: "yesterday", title: "Yesterday")
        self.mockClient.historyResponse = HomeResponse(sections: [initialSection])
        self.mockClient.historyContinuationSections = [[paginatedSection]]

        await self.viewModel.load()
        await self.waitForBackgroundLoading {
            self.viewModel.sections.map(\.title) == ["Today", "Yesterday"] &&
                self.viewModel.hasMoreSections == false
        }

        #expect(self.viewModel.sections.map(\.title) == ["Today", "Yesterday"])
        #expect(self.viewModel.hasMoreSections == false)

        let changed = await self.viewModel.refresh()

        #expect(changed == false)
        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.map(\.title) == ["Today", "Yesterday"])
    }

    @Test("Refresh restarts background pagination after history cursor rewind")
    func refreshRestartsBackgroundPaginationAfterCursorRewind() async {
        let initialSection = TestFixtures.makeHomeSection(id: "today", title: "Today")
        let paginatedSection = TestFixtures.makeHomeSection(id: "yesterday", title: "Yesterday")
        self.mockClient.historyResponse = HomeResponse(sections: [initialSection])
        self.mockClient.historyContinuationSections = [[paginatedSection]]

        await self.viewModel.load()
        await self.waitForBackgroundLoading {
            self.viewModel.sections.map(\.title) == ["Today", "Yesterday"] &&
                self.viewModel.hasMoreSections == false
        }

        #expect(self.viewModel.hasMoreSections == false)

        let changed = await self.viewModel.refresh()

        #expect(changed == false)
        #expect(self.viewModel.hasMoreSections == true)
        #expect(self.viewModel.sections.map(\.title) == ["Today", "Yesterday"])

        await self.waitForBackgroundLoading {
            self.viewModel.hasMoreSections == false &&
                self.viewModel.sections.map(\.title) == ["Today", "Yesterday"]
        }

        #expect(self.viewModel.hasMoreSections == false)
        #expect(self.viewModel.sections.map(\.title) == ["Today", "Yesterday"])
    }

    @Test("Empty history retry leaves loading state loaded")
    func emptyHistoryRetryLeavesLoadedState() async {
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.viewModel.load()

        if case .error = self.viewModel.loadingState {
            // Expected initial error state before retrying.
        } else {
            Issue.record("Expected error state after failed load")
        }

        self.mockClient.shouldThrowError = nil
        self.mockClient.historyResponse = HomeResponse(sections: [])

        let changed = await self.viewModel.refresh()

        #expect(changed == false)
        #expect(self.viewModel.loadingState == .loaded)
        #expect(self.viewModel.sections.isEmpty)
        #expect(self.viewModel.hasMoreSections == false)
    }

    @Test("Playback-triggered refresh updates history once per new video ID")
    func playbackTriggeredRefreshUpdatesHistoryOncePerNewVideoId() async {
        let initialSection = TestFixtures.makeHomeSection(id: "today", title: "Today")
        let refreshedSection = TestFixtures.makeHomeSection(id: "today-2", title: "Today")
        self.mockClient.historyResponse = HomeResponse(sections: [initialSection])

        await self.viewModel.load()
        self.viewModel.syncObservedPlayback(videoId: "video-1")

        HistoryViewModel.playbackRefreshDelay = .milliseconds(1)
        HistoryViewModel.playbackRefreshRetryDelay = .milliseconds(1)
        self.mockClient.historyResponseSequence = [HomeResponse(sections: [refreshedSection])]

        self.viewModel.schedulePlaybackRefreshIfNeeded(for: "video-1")
        self.viewModel.schedulePlaybackRefreshIfNeeded(for: "video-2")
        self.viewModel.schedulePlaybackRefreshIfNeeded(for: "video-2")

        await self.waitForHistoryRefresh {
            self.mockClient.getHistoryCallCount == 2 &&
                self.viewModel.sections.map(\.id) == ["today-2"]
        }

        #expect(self.mockClient.getHistoryCallCount == 2)
        #expect(self.viewModel.sections.map(\.id) == ["today-2"])
    }

    @Test("Playback-triggered refresh retries when the first page is unchanged")
    func playbackTriggeredRefreshRetriesWhenFirstPageIsUnchanged() async {
        let initialSection = TestFixtures.makeHomeSection(id: "today", title: "Today")
        let refreshedSection = TestFixtures.makeHomeSection(id: "today-2", title: "Today")
        self.mockClient.historyResponse = HomeResponse(sections: [initialSection])

        await self.viewModel.load()
        self.viewModel.syncObservedPlayback(videoId: "video-1")

        HistoryViewModel.playbackRefreshDelay = .milliseconds(1)
        HistoryViewModel.playbackRefreshRetryDelay = .milliseconds(1)
        self.mockClient.historyResponseSequence = [
            HomeResponse(sections: [initialSection]),
            HomeResponse(sections: [refreshedSection]),
        ]

        self.viewModel.schedulePlaybackRefreshIfNeeded(for: "video-2")

        await self.waitForHistoryRefresh {
            self.mockClient.getHistoryCallCount == 3 &&
                self.viewModel.sections.map(\.id) == ["today-2"]
        }

        #expect(self.mockClient.getHistoryCallCount == 3)
        #expect(self.viewModel.sections.map(\.id) == ["today-2"])
    }
}
