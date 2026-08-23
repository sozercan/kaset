import AppKit
import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
struct ImageCacheNetworkCoalescingTests {
    @Test("Same URL at different target sizes shares one cold download")
    func sameURLDifferentSizesShareOneColdDownload() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageData = try Self.makePNGData()
        let url = try #require(URL(string: "https://example.com/artwork.png"))
        let session = MockURLProtocol.makeMockSession()
        let requestCount = LockedCounter()
        MockURLProtocol.setRequestHandler(for: session) { request in
            if requestCount.increment() == 1 {
                Thread.sleep(forTimeInterval: 0.1)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )!
            return (response, imageData)
        }
        defer { MockURLProtocol.reset(session: session) }

        let cache = ImageCache(
            diskCacheURL: directory,
            startsEvictionTask: false,
            monitorsMemoryPressure: false,
            session: session
        )

        async let small = cache.image(for: url, targetSize: CGSize(width: 40, height: 40))
        async let large = cache.image(for: url, targetSize: CGSize(width: 320, height: 180))
        let images = await [small, large]

        #expect(images.allSatisfy { $0 != nil })
        #expect(requestCount.count == 1)
    }

    @Test("Failed raw download clears in-flight entry and retries later")
    func failedRawDownloadClearsInFlightAndRetries() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageData = try Self.makePNGData()
        let url = try #require(URL(string: "https://example.com/retry.png"))
        let session = MockURLProtocol.makeMockSession()
        let requestCount = LockedCounter()
        MockURLProtocol.setRequestHandler(for: session) { request in
            let statusCode = requestCount.increment() == 1 ? 500 : 200
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )!
            return (response, imageData)
        }
        defer { MockURLProtocol.reset(session: session) }

        let cache = ImageCache(
            diskCacheURL: directory,
            startsEvictionTask: false,
            monitorsMemoryPressure: false,
            session: session
        )

        let first = await cache.image(for: url, targetSize: CGSize(width: 40, height: 40))
        let second = await cache.image(for: url, targetSize: CGSize(width: 40, height: 40))

        #expect(first == nil)
        #expect(second != nil)
        #expect(requestCount.count == 2)
    }

    @Test("Warm disk data decodes multiple target sizes without network")
    func warmDiskDataDecodesMultipleTargetSizesWithoutNetwork() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageData = try Self.makePNGData()
        let url = try #require(URL(string: "https://example.com/warm.png"))
        let session = MockURLProtocol.makeMockSession()
        let requestCount = LockedCounter()
        MockURLProtocol.setRequestHandler(for: session) { request in
            requestCount.increment()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, imageData)
        }
        defer { MockURLProtocol.reset(session: session) }

        let cache = ImageCache(
            diskCacheURL: directory,
            startsEvictionTask: false,
            monitorsMemoryPressure: false,
            session: session
        )
        await cache.saveToDiskForTesting(url: url, data: imageData)

        let small = await cache.image(for: url, targetSize: CGSize(width: 40, height: 40))
        let large = await cache.image(for: url, targetSize: CGSize(width: 320, height: 180))

        #expect(small != nil)
        #expect(large != nil)
        #expect(requestCount.isEmpty)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageCacheNetworkCoalescingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func makePNGData() throws -> Data {
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
