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

    @MainActor
    func testQueuePersistenceLargeQueuePerformance() {
        let player = PlayerService()
        let songs = (0 ..< 3000).map { index in
            TestFixtures.makeSong(id: "persist-video-\(index)", title: "Persist Song \(index)")
        }
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        defer { Self.clearSavedPlaybackSession() }

        self.measure(metrics: [XCTClockMetric()], options: options) {
            MainActor.assumeIsolated {
                Self.clearSavedPlaybackSession()
                player.setQueue(songs)
                player.currentIndex = songs.count / 2
                player.saveQueueForPersistence()
                XCTAssertNotNil(UserDefaults.standard.data(forKey: "kaset.saved.playbackSession"))
            }
        }
    }

    @MainActor
    func testBulkQueueRemovalPerformance() {
        let player = PlayerService()
        let entries = (0 ..< 3000).map { index in
            QueueEntry(
                id: UUID(),
                song: TestFixtures.makeSong(id: "remove-video-\(index)", title: "Remove Song \(index)")
            )
        }
        let entryIDsToRemove = Set(entries.enumerated().compactMap { index, entry in
            index.isMultiple(of: 2) ? entry.id : nil
        })
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        defer { Self.clearSavedPlaybackSession() }

        self.measure(metrics: [XCTClockMetric()], options: options) {
            MainActor.assumeIsolated {
                Self.clearSavedPlaybackSession()
                player.setQueue(entries: entries)
                player.currentIndex = entries.count - 1
                player.removeFromQueue(entryIDs: entryIDsToRemove)
                XCTAssertEqual(player.queueEntries.count, entries.count - entryIDsToRemove.count)
            }
        }
    }

    private static func clearSavedPlaybackSession() {
        UserDefaults.standard.removeObject(forKey: "kaset.saved.queue")
        UserDefaults.standard.removeObject(forKey: "kaset.saved.queueIndex")
        UserDefaults.standard.removeObject(forKey: "kaset.saved.playbackSession")
    }
}
