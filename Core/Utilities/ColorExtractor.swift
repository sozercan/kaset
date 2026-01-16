import AppKit
import CoreGraphics
import SwiftUI

/// Extracts dominant colors from images for UI accent backgrounds.
enum ColorExtractor {
    /// Represents a weighted color sample for averaging.
    private struct WeightedColor {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let weight: CGFloat
    }

    /// Represents extracted color palette from an image.
    struct ColorPalette: Equatable, Sendable {
        /// Dark mode primary color (darker, saturated).
        let primary: Color
        /// Dark mode secondary color (even darker).
        let secondary: Color
        /// Light mode tint color (lighter, pastel).
        let lightTint: Color

        /// Default adaptive palette when no image is available.
        static let `default` = ColorPalette(
            primary: Color(nsColor: NSColor(white: 0.15, alpha: 1)),
            secondary: Color(nsColor: NSColor(white: 0.08, alpha: 1)),
            lightTint: Color(nsColor: NSColor.controlAccentColor).opacity(0.3)
        )
    }

    /// Extracts a color palette from an NSImage.
    /// Uses k-means clustering on downsampled image for performance.
    /// - Parameter image: The source image.
    /// - Returns: A ColorPalette with primary and secondary colors.
    static func extractPalette(from image: NSImage) -> ColorPalette {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .default
        }

        // Downsample for performance (8x8 is enough for dominant color)
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

        // Sample pixels
        for yCoord in 0 ..< sampleSize {
            for xCoord in 0 ..< sampleSize {
                let offset = (yCoord * sampleSize + xCoord) * 4
                let red = CGFloat(pointer[offset]) / 255.0
                let green = CGFloat(pointer[offset + 1]) / 255.0
                let blue = CGFloat(pointer[offset + 2]) / 255.0

                // Weight by saturation and avoid near-black/white pixels
                let maxC = max(red, green, blue)
                let minC = min(red, green, blue)
                let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
                let brightness = maxC

                // Skip very dark or very light pixels
                if brightness > 0.1, brightness < 0.95 {
                    let weight = saturation * 0.7 + 0.3
                    colors.append(WeightedColor(red: red, green: green, blue: blue, weight: weight))
                }
            }
        }

        // Find dominant color using weighted average
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

        // Create primary color (saturated and darker for dark mode background)
        let primary = self.adjustColorForDarkMode(r: avgR, g: avgG, b: avgB, darken: 0.4)

        // Create secondary color (even darker for gradient end)
        let secondary = self.adjustColorForDarkMode(r: avgR, g: avgG, b: avgB, darken: 0.7)

        // Create light tint (brighter, less saturated for light mode)
        let lightTint = self.adjustColorForLightMode(r: avgR, g: avgG, b: avgB)

        return ColorPalette(
            primary: Color(nsColor: primary),
            secondary: Color(nsColor: secondary),
            lightTint: Color(nsColor: lightTint)
        )
    }

    /// Extracts palette from image data off the main actor.
    /// - Parameter data: Raw image data.
    /// - Returns: Extracted color palette.
    static func extractPalette(from data: Data) async -> ColorPalette {
        // Perform CPU-intensive color extraction off the main actor.
        // This prevents UI jank during image processing.
        await Task(priority: .userInitiated) {
            guard let image = NSImage(data: data) else {
                return ColorPalette.default
            }
            return Self.extractPalette(from: image)
        }.value
    }

    // MARK: - Private Helpers

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
        // Convert to HSB for easier manipulation
        let nsColor = NSColor(red: r, green: g, blue: b, alpha: 1.0)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // Increase saturation slightly and darken significantly
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
        // Convert to HSB for easier manipulation
        let nsColor = NSColor(red: r, green: g, blue: b, alpha: 1.0)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // Create a lighter, less saturated pastel version
        // Reduce saturation significantly and increase brightness
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
