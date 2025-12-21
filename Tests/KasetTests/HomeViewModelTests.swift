import XCTest
@testable import Kaset

/// Tests for HomeViewModel using mock client.
@MainActor
final class HomeViewModelTests: XCTestCase {
    private var mockClient: MockYTMusicClient!
    private var viewModel: HomeViewModel!

    override func setUp() async throws {
        self.mockClient = MockYTMusicClient()
        self.viewModel = HomeViewModel(client: self.mockClient)
    }

    override func tearDown() async throws {
        self.mockClient = nil
        self.viewModel = nil
    }

    func testInitialState() {
        XCTAssertEqual(self.viewModel.loadingState, .idle)
        XCTAssertTrue(self.viewModel.sections.isEmpty)
    }

    func testLoadSuccess() async {
        // Given
        let expectedSections = [
            TestFixtures.makeHomeSection(title: "Quick picks"),
            TestFixtures.makeHomeSection(title: "Recommended"),
        ]
        self.mockClient.homeResponse = HomeResponse(sections: expectedSections)

        // When
        await self.viewModel.load()

        // Then
        XCTAssertTrue(self.mockClient.getHomeCalled)
        XCTAssertEqual(self.viewModel.loadingState, .loaded)
        XCTAssertEqual(self.viewModel.sections.count, 2)
        XCTAssertEqual(self.viewModel.sections[0].title, "Quick picks")
        XCTAssertEqual(self.viewModel.sections[1].title, "Recommended")
    }

    func testLoadError() async {
        // Given
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        // When
        await self.viewModel.load()

        // Then
        XCTAssertTrue(self.mockClient.getHomeCalled)
        if case let .error(message) = viewModel.loadingState {
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("Expected error state")
        }
        XCTAssertTrue(self.viewModel.sections.isEmpty)
    }

    func testLoadDoesNotDuplicateWhenAlreadyLoading() async {
        // Given
        self.mockClient.homeResponse = TestFixtures.makeHomeResponse(sectionCount: 1)

        // When - load twice sequentially (since we're on MainActor)
        await self.viewModel.load()
        await self.viewModel.load()

        // Then - second load should be skipped when already loaded
        XCTAssertEqual(self.mockClient.getHomeCallCount, 2)
    }

    func testRefreshClearsSectionsAndReloads() async {
        // Given - load initial data
        self.mockClient.homeResponse = TestFixtures.makeHomeResponse(sectionCount: 2)
        await self.viewModel.load()
        XCTAssertEqual(self.viewModel.sections.count, 2)

        // When - refresh with new data
        self.mockClient.homeResponse = TestFixtures.makeHomeResponse(sectionCount: 3)
        await self.viewModel.refresh()

        // Then
        XCTAssertEqual(self.viewModel.sections.count, 3)
        XCTAssertEqual(self.mockClient.getHomeCallCount, 2)
    }
}
