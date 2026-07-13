import AppKit
import Foundation
import Testing
@testable import Kaset

@Suite("ColorExtractor")
struct ColorExtractorTests {
    @Test("Concurrent cached palette requests coalesce the image download")
    func concurrentCachedPaletteRequestsCoalesceDownload() async throws {
        let harness = try Self.makeHarness(path: "coalesce.png")
        defer { harness.cleanup() }
        let requestCount = LockedCounter()
        MockURLProtocol.setRequestHandler(for: harness.session) { request in
            if requestCount.increment() == 1 {
                Thread.sleep(forTimeInterval: 0.05)
            }
            return try Self.response(url: #require(request.url), data: harness.data)
        }

        async let first = harness.paletteCache.palette(for: harness.url, targetSize: CGSize(width: 32, height: 32))
        async let second = harness.paletteCache.palette(for: harness.url, targetSize: CGSize(width: 32, height: 32))
        let palettes = await [first, second]

        #expect(palettes == [harness.directPalette, harness.directPalette])
        #expect(requestCount.count == 1)
    }

    @Test("Warm cached palette request does not hit the image loader again")
    func warmCachedPaletteRequestAvoidsImageReload() async throws {
        let harness = try Self.makeHarness(path: "warm.png")
        defer { harness.cleanup() }
        let requestCount = LockedCounter()
        MockURLProtocol.setRequestHandler(for: harness.session) { request in
            requestCount.increment()
            return try Self.response(url: #require(request.url), data: harness.data)
        }

        let first = await harness.paletteCache.palette(for: harness.url, targetSize: CGSize(width: 32, height: 32))
        let second = await harness.paletteCache.palette(for: harness.url, targetSize: CGSize(width: 32, height: 32))

        #expect(first == harness.directPalette)
        #expect(second == first)
        #expect(requestCount.count == 1)
    }

    @Test("Failed palette image load retries instead of caching default")
    func failedPaletteImageLoadRetries() async throws {
        let harness = try Self.makeHarness(path: "retry.png")
        defer { harness.cleanup() }
        let requestCount = LockedCounter()
        MockURLProtocol.setRequestHandler(for: harness.session) { request in
            let statusCode = requestCount.increment() == 1 ? 500 : 200
            return try Self.response(url: #require(request.url), data: harness.data, statusCode: statusCode)
        }

        let first = await harness.paletteCache.palette(for: harness.url, targetSize: CGSize(width: 32, height: 32))
        let second = await harness.paletteCache.palette(for: harness.url, targetSize: CGSize(width: 32, height: 32))

        #expect(first == .default)
        #expect(second == harness.directPalette)
        #expect(requestCount.count == 2)
    }

    @Test("Palette cache evicts least recently used entries at its count limit")
    func paletteCacheEvictsLeastRecentlyUsedEntriesAtCountLimit() async throws {
        let harness = try Self.makeHarness(path: "evict-a.png", maximumPaletteCount: 2)
        defer { harness.cleanup() }
        let responses = try [
            #require(URL(string: "https://example.com/evict-a.png")): harness.data,
            #require(URL(string: "https://example.com/evict-b.png")): Self.pngData(color: NSColor(calibratedRed: 0.10, green: 0.70, blue: 0.20, alpha: 1)),
            #require(URL(string: "https://example.com/evict-c.png")): Self.pngData(color: NSColor(calibratedRed: 0.20, green: 0.30, blue: 0.80, alpha: 1)),
        ]
        MockURLProtocol.setRequestHandler(for: harness.session) { request in
            let url = try #require(request.url)
            return try Self.response(url: url, data: #require(responses[url]))
        }

        let secondURL = try #require(URL(string: "https://example.com/evict-b.png"))
        let thirdURL = try #require(URL(string: "https://example.com/evict-c.png"))

        _ = await harness.paletteCache.palette(for: harness.url, targetSize: CGSize(width: 32, height: 32))
        _ = await harness.paletteCache.palette(for: secondURL, targetSize: CGSize(width: 32, height: 32))
        _ = await harness.paletteCache.palette(for: harness.url, targetSize: CGSize(width: 32, height: 32))
        _ = await harness.paletteCache.palette(for: thirdURL, targetSize: CGSize(width: 32, height: 32))

        #expect(await harness.paletteCache.cachedPaletteCountForTesting == 2)
    }

    private struct Harness {
        let data: Data
        let directPalette: ColorExtractor.ColorPalette
        let url: URL
        let session: URLSession
        let paletteCache: ColorPaletteCache
        let directory: URL

        func cleanup() {
            MockURLProtocol.reset(session: self.session)
            try? FileManager.default.removeItem(at: self.directory)
        }
    }

    private static func makeHarness(path: String, maximumPaletteCount: Int = 200) throws -> Harness {
        let data = try Self.pngData(color: NSColor(calibratedRed: 0.78, green: 0.20, blue: 0.12, alpha: 1))
        let image = try #require(NSImage(data: data))
        let directPalette = ColorExtractor.extractPalette(from: image)
        let url = try #require(URL(string: "https://example.com/\(path)"))
        let session = MockURLProtocol.makeMockSession()
        let directory = try Self.makeTemporaryDirectory()
        let imageCache = ImageCache(
            diskCacheURL: directory,
            startsEvictionTask: false,
            monitorsMemoryPressure: false,
            session: session
        )
        return Harness(
            data: data,
            directPalette: directPalette,
            url: url,
            session: session,
            paletteCache: ColorPaletteCache(imageCache: imageCache, maximumPaletteCount: maximumPaletteCount),
            directory: directory
        )
    }

    private static func response(url: URL, data: Data, statusCode: Int = 200) throws -> (HTTPURLResponse, Data) {
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
        ))
        return (response, data)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColorExtractorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func pngData(color: NSColor) throws -> Data {
        let size = 16
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: size * 4,
            bitsPerPixel: 32
        ) else {
            throw TestError.imageCreationFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw TestError.imageEncodingFailed
        }
        return data
    }

    private enum TestError: Error {
        case imageCreationFailed
        case imageEncodingFailed
    }
}
