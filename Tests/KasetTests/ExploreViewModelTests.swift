import XCTest
@testable import Kaset

/// Tests for ExploreViewModel using mock client.
@MainActor
final class ExploreViewModelTests: XCTestCase {
    private var mockClient: MockYTMusicClient!
    private var viewModel: ExploreViewModel!

    override func setUp() async throws {
        self.mockClient = MockYTMusicClient()
        self.viewModel = ExploreViewModel(client: self.mockClient)
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
            TestFixtures.makeHomeSection(title: "New releases"),
            TestFixtures.makeHomeSection(title: "Charts"),
            TestFixtures.makeHomeSection(title: "Moods & genres"),
        ]
        self.mockClient.exploreResponse = HomeResponse(sections: expectedSections)

        // When
        await self.viewModel.load()

        // Then
        XCTAssertTrue(self.mockClient.getExploreCalled)
        XCTAssertEqual(self.viewModel.loadingState, .loaded)
        XCTAssertEqual(self.viewModel.sections.count, 3)
        XCTAssertEqual(self.viewModel.sections[0].title, "New releases")
    }

    func testLoadError() async {
        // Given
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.timedOut))

        // When
        await self.viewModel.load()

        // Then
        XCTAssertTrue(self.mockClient.getExploreCalled)
        if case .error = self.viewModel.loadingState {
            // Expected
        } else {
            XCTFail("Expected error state")
        }
        XCTAssertTrue(self.viewModel.sections.isEmpty)
    }

    func testLoadDoesNotDuplicateWhenAlreadyLoading() async {
        // Given
        self.mockClient.exploreResponse = TestFixtures.makeHomeResponse(sectionCount: 1)

        // When - load twice sequentially (since we're on MainActor)
        await self.viewModel.load()
        await self.viewModel.load()

        // Then - second load should be called since state is loaded
        XCTAssertEqual(self.mockClient.getExploreCallCount, 2)
    }

    func testRefreshClearsSectionsAndReloads() async {
        // Given
        self.mockClient.exploreResponse = TestFixtures.makeHomeResponse(sectionCount: 2)
        await self.viewModel.load()
        XCTAssertEqual(self.viewModel.sections.count, 2)

        // When
        self.mockClient.exploreResponse = TestFixtures.makeHomeResponse(sectionCount: 4)
        await self.viewModel.refresh()

        // Then
        XCTAssertEqual(self.viewModel.sections.count, 4)
        XCTAssertEqual(self.mockClient.getExploreCallCount, 2)
    }
}
