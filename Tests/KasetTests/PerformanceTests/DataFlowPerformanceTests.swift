import XCTest
@testable import Kaset

/// Performance tests for app data-flow helpers that are hot during large library/playlist loads.
final class DataFlowPerformanceTests: XCTestCase {
    @MainActor
    func testLikeStatusSingleWritePerformance() {
        let manager = SongLikeStatusManager.shared
        let videoIds = (0 ..< 10000).map { "liked-video-\($0)" }
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        self.measure(metrics: [XCTClockMetric()], options: options) {
            MainActor.assumeIsolated {
                manager.clearCache()
                for videoId in videoIds {
                    manager.setStatus(.like, for: videoId)
                }
                XCTAssertEqual(manager.status(for: videoIds[9999]), .like)
            }
        }
    }
}
