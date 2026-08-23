import XCTest
@testable import Kaset

/// Performance coverage for YouTube Home cold-load topic rail fanout.
final class YouTubeHomeFanoutPerformanceTests: XCTestCase {
    func testColdLoadWithEightTopicChipsPerformance() {
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        self.measure(metrics: [XCTClockMetric()], options: options) {
            self.waitForAsyncOnMainActor {
                let mockClient = MockYouTubeClient()
                mockClient.homeFeed = YouTubeFeed(
                    videos: MockYouTubeClient.makeVideos(count: 12),
                    continuation: nil
                )
                mockClient.homeChips = (0 ..< 8).map { index in
                    YouTubeHomeChip(title: "Topic \(index)", continuation: "tok-\(index)")
                }
                mockClient.homeTopicFeeds = Dictionary(uniqueKeysWithValues: (0 ..< 8).map { index in
                    (
                        "tok-\(index)",
                        YouTubeFeed(videos: MockYouTubeClient.makeVideos(count: 8), continuation: nil)
                    )
                })

                let sut = YouTubeHomeViewModel(client: mockClient)
                await sut.load()

                XCTAssertEqual(mockClient.homeFeedCallCount, 1)
                XCTAssertEqual(mockClient.requestedTopicContinuations.count, 2)
                XCTAssertEqual(Set(mockClient.requestedTopicContinuations), Set(["tok-0", "tok-1"]))
                XCTAssertTrue(sut.hasMoreTopicRails)
                XCTAssertFalse(sut.isLoadingTopicRails)
            }
        }
    }

    private func waitForAsyncOnMainActor(_ operation: @escaping @MainActor () async -> Void) {
        let expectation = self.expectation(description: "main actor async operation")
        Task { @MainActor in
            await operation()
            expectation.fulfill()
        }
        self.wait(for: [expectation], timeout: 10)
    }
}
