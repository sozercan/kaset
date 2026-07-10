import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
struct ImageCacheDiskEvictionTests {
    @Test("Under-limit disk writes update estimate without rescanning directory")
    func underLimitWritesAvoidFullScans() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageCache(
            diskCacheURL: directory,
            maxDiskCacheSize: 10000,
            initialEstimatedDiskCacheSize: 0,
            diskEvictionWriteThreshold: 100,
            startsEvictionTask: false,
            monitorsMemoryPressure: false
        )
        let initialScans = await cache.diskCacheSizeScanCountForTesting

        for index in 0 ..< 5 {
            try await cache.saveToDiskForTesting(
                url: #require(URL(string: "https://example.com/image-\(index).jpg")),
                data: Data(repeating: UInt8(index), count: 100)
            )
        }

        #expect(await cache.diskCacheSizeScanCountForTesting == initialScans)
        #expect(await cache.estimatedDiskCacheSizeForTesting() == 500)
    }

    @Test("Write threshold periodically reconciles estimated disk size")
    func writeThresholdReconcilesEstimate() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageCache(
            diskCacheURL: directory,
            maxDiskCacheSize: 10000,
            initialEstimatedDiskCacheSize: 0,
            diskEvictionWriteThreshold: 3,
            startsEvictionTask: false,
            monitorsMemoryPressure: false
        )
        let initialScans = await cache.diskCacheSizeScanCountForTesting

        for index in 0 ..< 3 {
            try await cache.saveToDiskForTesting(
                url: #require(URL(string: "https://example.com/reconcile-\(index).jpg")),
                data: Data(repeating: UInt8(index), count: 100)
            )
        }
        await cache.waitForScheduledDiskEvictionForTesting()

        #expect(await cache.diskCacheSizeScanCountForTesting == initialScans + 1)
        #expect(await cache.estimatedDiskCacheSizeForTesting() == 300)
    }

    @Test("Forced eviction updates estimate and removes oldest files over limit")
    func forcedEvictionRemovesOldestFiles() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageCache(
            diskCacheURL: directory,
            maxDiskCacheSize: 250,
            initialEstimatedDiskCacheSize: 0,
            diskEvictionWriteThreshold: 100,
            startsEvictionTask: false,
            monitorsMemoryPressure: false
        )
        let urls = try (0 ..< 4).map { index in
            try #require(URL(string: "https://example.com/evict-\(index).jpg"))
        }

        for (index, url) in urls.enumerated() {
            let path = await cache.diskCachePathForTesting(url: url)
            try Data(repeating: UInt8(index), count: 100).write(to: path, options: .atomic)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                ofItemAtPath: path.path
            )
        }

        await cache.evictDiskCacheIfNeededForTesting(force: true)

        let finalSize = await cache.diskCacheSize()
        let firstPath = await cache.diskCachePathForTesting(url: urls[0])
        let secondPath = await cache.diskCachePathForTesting(url: urls[1])
        #expect(finalSize <= 250)
        #expect(await cache.estimatedDiskCacheSizeForTesting() == finalSize)
        #expect(!FileManager.default.fileExists(atPath: firstPath.path))
        #expect(!FileManager.default.fileExists(atPath: secondPath.path))
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageCacheDiskEvictionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
