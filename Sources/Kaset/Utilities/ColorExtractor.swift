import AppKit
import CoreGraphics
import SwiftUI

enum ColorExtractor {
    private struct WeightedColor {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let weight: CGFloat
    }

    struct ColorPalette: Equatable {
        let primary: Color
        let secondary: Color
        let lightTint: Color

        static let `default` = ColorPalette(
            primary: Color(nsColor: NSColor(white: 0.15, alpha: 1)),
            secondary: Color(nsColor: NSColor(white: 0.08, alpha: 1)),
            lightTint: Color(nsColor: NSColor.controlAccentColor).opacity(0.3)
        )
    }

    static func cachedPalette(
        for url: URL,
        targetSize: CGSize = CGSize(width: 64, height: 64)
    ) async -> ColorPalette {
        await ColorPaletteCache.shared.palette(for: url, targetSize: targetSize)
    }

    static func extractPalette(from image: NSImage) -> ColorPalette {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .default
        }

        let sampleSize = 8
        guard let context = createBitmapContext(width: sampleSize, height: sampleSize) else {
            return .default
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        guard let data = context.data else {
            return .default
        }

        let pointer = data.bindMemory(to: UInt8.self, capacity: sampleSize * sampleSize * 4)
        var colors: [WeightedColor] = []

        for yCoord in 0 ..< sampleSize {
            for xCoord in 0 ..< sampleSize {
                let offset = (yCoord * sampleSize + xCoord) * 4
                let red = CGFloat(pointer[offset]) / 255.0
                let green = CGFloat(pointer[offset + 1]) / 255.0
                let blue = CGFloat(pointer[offset + 2]) / 255.0

                let maxC = max(red, green, blue)
                let minC = min(red, green, blue)
                let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
                let brightness = maxC

                if brightness > 0.1, brightness < 0.95 {
                    let weight = saturation * 0.7 + 0.3
                    colors.append(WeightedColor(red: red, green: green, blue: blue, weight: weight))
                }
            }
        }

        guard !colors.isEmpty else {
            return .default
        }

        let totalWeight = colors.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else {
            return .default
        }

        let avgR = colors.reduce(0) { $0 + $1.red * $1.weight } / totalWeight
        let avgG = colors.reduce(0) { $0 + $1.green * $1.weight } / totalWeight
        let avgB = colors.reduce(0) { $0 + $1.blue * $1.weight } / totalWeight

        let primary = self.adjustColorForDarkMode(r: avgR, g: avgG, b: avgB, darken: 0.4)

        let secondary = self.adjustColorForDarkMode(r: avgR, g: avgG, b: avgB, darken: 0.7)

        let lightTint = self.adjustColorForLightMode(r: avgR, g: avgG, b: avgB)

        return ColorPalette(
            primary: Color(nsColor: primary),
            secondary: Color(nsColor: secondary),
            lightTint: Color(nsColor: lightTint)
        )
    }

    static func extractPalette(from data: Data) async -> ColorPalette {
        await Task(priority: .userInitiated) {
            guard let image = NSImage(data: data) else {
                return ColorPalette.default
            }
            return Self.extractPalette(from: image)
        }.value
    }

    private static func createBitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func adjustColorForDarkMode(
        r: CGFloat,
        g: CGFloat,
        b: CGFloat,
        darken: CGFloat
    ) -> NSColor {
        let nsColor = NSColor(red: r, green: g, blue: b, alpha: 1.0)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let adjustedSaturation = min(saturation * 1.2, 1.0)
        let adjustedBrightness = brightness * (1 - darken)

        return NSColor(
            hue: hue,
            saturation: adjustedSaturation,
            brightness: max(adjustedBrightness, 0.05),
            alpha: 1.0
        )
    }

    private static func adjustColorForLightMode(
        r: CGFloat,
        g: CGFloat,
        b: CGFloat
    ) -> NSColor {
        let nsColor = NSColor(red: r, green: g, blue: b, alpha: 1.0)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let adjustedSaturation = saturation * 0.4
        let adjustedBrightness = min(brightness * 1.3 + 0.4, 1.0)

        return NSColor(
            hue: hue,
            saturation: adjustedSaturation,
            brightness: adjustedBrightness,
            alpha: 1.0
        )
    }
}

actor ColorPaletteCache {
    static let shared = ColorPaletteCache()

    private let imageCache: ImageCache
    private let maximumPaletteCount: Int
    private var palettes: [String: ColorExtractor.ColorPalette] = [:]
    private var mostRecentlyUsedKeys: [String] = []
    private var inFlight: [String: Task<ColorExtractor.ColorPalette?, Never>] = [:]

    init(
        imageCache: ImageCache = ImageCache.shared,
        maximumPaletteCount: Int = 200
    ) {
        self.imageCache = imageCache
        self.maximumPaletteCount = max(1, maximumPaletteCount)
    }

    func palette(for url: URL, targetSize: CGSize) async -> ColorExtractor.ColorPalette {
        let key = self.cacheKey(for: url, targetSize: targetSize)
        if let cached = self.palettes[key] {
            self.markPaletteUsed(for: key)
            return cached
        }
        if let existing = self.inFlight[key] {
            return await existing.value ?? .default
        }

        let imageCache = self.imageCache
        let task = Task<ColorExtractor.ColorPalette?, Never>(priority: .utility) {
            guard let image = await imageCache.image(for: url, targetSize: targetSize) else {
                return nil
            }
            return ColorExtractor.extractPalette(from: image)
        }

        self.inFlight[key] = task
        let palette = await task.value
        self.inFlight[key] = nil

        guard let palette else {
            return .default
        }
        self.storePalette(palette, for: key)
        return palette
    }

    private func storePalette(_ palette: ColorExtractor.ColorPalette, for key: String) {
        self.palettes[key] = palette
        self.markPaletteUsed(for: key)
        self.evictLeastRecentlyUsedPalettesIfNeeded()
    }

    private func markPaletteUsed(for key: String) {
        self.mostRecentlyUsedKeys.removeAll { $0 == key }
        self.mostRecentlyUsedKeys.append(key)
    }

    private func evictLeastRecentlyUsedPalettesIfNeeded() {
        while self.palettes.count > self.maximumPaletteCount,
              let evictedKey = self.mostRecentlyUsedKeys.first
        {
            self.mostRecentlyUsedKeys.removeFirst()
            self.palettes.removeValue(forKey: evictedKey)
        }
    }

    #if DEBUG
        var cachedPaletteCountForTesting: Int {
            self.palettes.count
        }
    #endif

    private func cacheKey(for url: URL, targetSize: CGSize) -> String {
        "\(url.absoluteString)@\(Int(targetSize.width))x\(Int(targetSize.height))"
    }
}
