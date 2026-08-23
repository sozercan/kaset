import AppKit
import XCTest
@testable import Kaset

/// Performance tests for image color extraction paths used by accent backgrounds.
final class ColorExtractorPerformanceTests: XCTestCase {
    func testCachedPaletteRepeatAccessPerformance() throws {
        let url = try Self.writePNG(color: NSColor(calibratedRed: 0.72, green: 0.18, blue: 0.11, alpha: 1))
        defer { try? FileManager.default.removeItem(at: url) }

        // Warm the ImageCache + palette cache once; the measured path represents
        // repeated accent backgrounds for the same artwork during navigation.
        self.waitForAsync { _ = await ColorExtractor.cachedPalette(for: url, targetSize: CGSize(width: 32, height: 32)) }

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        self.measure(metrics: [XCTClockMetric()], options: options) {
            self.waitForAsync {
                for _ in 0 ..< 2000 {
                    _ = await ColorExtractor.cachedPalette(for: url, targetSize: CGSize(width: 32, height: 32))
                }
            }
        }
    }

    private func waitForAsync(_ operation: @escaping @Sendable () async -> Void) {
        let expectation = self.expectation(description: "async palette operation")
        Task {
            await operation()
            expectation.fulfill()
        }
        self.wait(for: [expectation], timeout: 10)
    }

    private static func writePNG(color: NSColor) throws -> URL {
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

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaset-color-extractor-perf-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try data.write(to: url)
        return url
    }

    private enum TestError: Error {
        case imageCreationFailed
        case imageEncodingFailed
    }
}
