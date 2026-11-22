import AppKit
import CoreGraphics
import SwiftUI

struct AmbientVideoBackdrop: View {
    let videoId: String?
    let thumbnailURL: URL?
    let style: AmbientBackdropStyle
    var liveFraction: Double?
    var storyboardSpec: String?

    @State private var palette: ColorExtractor.ColorPalette = .default
    @State private var thumbnailSwatches: [Color] = []
    @State private var frameSwatches: [[Color]] = []
    @State private var loadedVideoId: String?
    @State private var lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    nonisolated static let animatedTimelineInterval: TimeInterval = 1.0 / 8.0

    var body: some View {
        let style = self.effectiveStyle
        Group {
            if style == .off {
                Color.clear
            } else if self.reduceTransparency {
                self.flatTint
            } else {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    self.ambientContent
                }
            }
        }
        .animation(.easeInOut(duration: 0.6), value: self.palette)
        .animation(.easeInOut(duration: 0.5), value: style)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
            self.lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .task(id: self.loadKey) {
            await self.load()
        }
    }

    private var loadKey: String {
        let style = self.effectiveStyle
        let hasStoryboardSpec = style == .live && self.storyboardSpec != nil
        return "\(self.videoId ?? "-")|\(style.rawValue)|\(hasStoryboardSpec)"
    }

    private var effectiveStyle: AmbientBackdropStyle {
        Self.effectiveStyle(
            requestedStyle: self.style,
            reduceMotion: self.reduceMotion,
            lowPowerModeEnabled: self.lowPowerModeEnabled
        )
    }

    nonisolated static func effectiveStyle(
        requestedStyle style: AmbientBackdropStyle,
        reduceMotion: Bool,
        lowPowerModeEnabled: Bool
    ) -> AmbientBackdropStyle {
        if style == .live, reduceMotion || lowPowerModeEnabled {
            return .soft
        }
        return style
    }

    private var ambientContent: some View {
        GeometryReader { geo in
            let style = self.effectiveStyle
            if style == .soft || self.reduceMotion {
                self.auroraLayer(size: geo.size, time: nil)
            } else {
                TimelineView(.periodic(from: .now, by: Self.animatedTimelineInterval)) { timeline in
                    self.auroraLayer(
                        size: geo.size,
                        time: timeline.date.timeIntervalSinceReferenceDate
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func auroraLayer(size: CGSize, time: TimeInterval?) -> some View {
        let frames = self.renderFrames
        let intensity: Double = self.effectiveStyle == .soft ? 0.7 : 1.0
        if frames.count <= 1 || self.reduceMotion {
            Self.aurora(
                colors: frames.first ?? self.fallbackColors,
                size: size,
                time: time,
                colorScheme: self.colorScheme,
                intensity: intensity
            )
        } else {
            let position = (self.liveFraction ?? 0) * Double(frames.count - 1)
            let lower = min(max(Int(position.rounded(.down)), 0), frames.count - 1)
            let upper = min(lower + 1, frames.count - 1)
            let blend = position - Double(lower)
            let lowerColors = frames[lower].isEmpty ? self.fallbackColors : frames[lower]
            let upperColors = frames[upper].isEmpty ? self.fallbackColors : frames[upper]
            ZStack {
                Self.aurora(colors: lowerColors, size: size, time: time, colorScheme: self.colorScheme, intensity: intensity)
                    .opacity(1 - blend)
                Self.aurora(colors: upperColors, size: size, time: time, colorScheme: self.colorScheme, intensity: intensity)
                    .opacity(blend)
            }
            .animation(.easeInOut(duration: 0.7), value: self.liveFraction)
        }
    }

    private var colorsAreCurrent: Bool {
        self.loadedVideoId == self.videoId
    }

    private var currentPalette: ColorExtractor.ColorPalette {
        self.colorsAreCurrent ? self.palette : .default
    }

    private var renderFrames: [[Color]] {
        switch self.effectiveStyle {
        case .live where self.colorsAreCurrent && !self.frameSwatches.isEmpty:
            self.frameSwatches
        default:
            [self.fallbackColors]
        }
    }

    private var fallbackColors: [Color] {
        if self.colorsAreCurrent, !self.thumbnailSwatches.isEmpty {
            return self.thumbnailSwatches
        }
        return [self.currentPalette.primary, self.currentPalette.secondary]
    }

    private static func aurora(
        colors: [Color],
        size: CGSize,
        time: TimeInterval?,
        colorScheme: ColorScheme,
        intensity: Double
    ) -> some View {
        let isDark = colorScheme == .dark
        let blend: BlendMode = isDark ? .plusLighter : .normal
        let coreOpacity: Double = (isDark ? 0.55 : 0.30) * intensity
        let elapsed = time ?? 0

        return ZStack {
            ForEach(Array(colors.prefix(Self.layout.count).enumerated()), id: \.offset) { index, color in
                let spot = Self.layout[index]
                let period = Self.periods[index]
                let phase = Self.phases[index]
                let driftX = time == nil ? 0 : 0.12 * size.width * sin(elapsed / period + phase)
                let driftY = time == nil ? 0 : 0.10 * size.height * cos(elapsed / (period + 6) + phase)
                let diameter = size.width

                RadialGradient(
                    colors: [color.opacity(coreOpacity), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter * 0.5
                )
                .frame(width: diameter, height: diameter)
                .position(
                    x: spot.x * size.width + driftX,
                    y: spot.y * size.height + driftY
                )
                .blendMode(blend)
            }
        }
        .compositingGroup()
        .blur(radius: 46)
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private static let layout: [(x: CGFloat, y: CGFloat)] = [
        (0.28, 0.24), (0.74, 0.20), (0.18, 0.58), (0.82, 0.64), (0.50, 0.42),
    ]

    private static let periods: [Double] = [19, 23, 29, 31, 37]
    private static let phases: [Double] = [0.0, 1.7, 3.1, 4.6, 5.9]

    private var flatTint: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [self.currentPalette.primary.opacity(0.14), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
    }

    private func load() async {
        let style = self.effectiveStyle
        guard style != .off else { return }

        let resolved: (palette: ColorExtractor.ColorPalette, swatches: [Color])? = if let url = self.thumbnailURL ?? self.fallbackThumbnailURL {
            await Self.loadPaletteAndSwatches(url: url, size: CGSize(width: 1280, height: 720))
        } else {
            nil
        }
        if Task.isCancelled {
            return
        }
        let isNewVideo = self.loadedVideoId != self.videoId
        self.palette = resolved?.palette ?? .default
        self.thumbnailSwatches = resolved?.swatches ?? []
        if isNewVideo {
            self.frameSwatches = []
        }
        self.loadedVideoId = self.videoId

        guard style == .live else {
            self.frameSwatches = []
            return
        }

        if let spec = self.storyboardSpec,
           let sheet = StoryboardSheet(spec: spec),
           let sets = await Self.loadStoryboardSwatches(sheet: sheet),
           !sets.isEmpty
        {
            if Task.isCancelled {
                return
            }
            self.frameSwatches = sets
            return
        }

        var sets: [[Color]] = []
        for url in self.storyboardFrameURLs() {
            if let swatches = await Self.loadSwatches(url: url, size: CGSize(width: 320, height: 180)),
               !swatches.isEmpty
            {
                sets.append(swatches)
            }
        }
        if Task.isCancelled {
            return
        }
        self.frameSwatches = sets
    }

    private var fallbackThumbnailURL: URL? {
        guard let videoId else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg")
    }

    private func storyboardFrameURLs() -> [URL] {
        guard let videoId else { return [] }
        return (1 ... 3).compactMap { URL(string: "https://i.ytimg.com/vi/\(videoId)/\($0).jpg") }
    }

    // swiftformat:disable modifierOrder
    nonisolated private static func loadPaletteAndSwatches(
        url: URL,
        size: CGSize
    ) async -> (palette: ColorExtractor.ColorPalette, swatches: [Color])? {
        guard let nsImage = await ImageCache.shared.image(for: url, targetSize: size) else {
            return nil
        }
        return (ColorExtractor.extractPalette(from: nsImage), Self.extractSwatches(from: nsImage))
    }

    nonisolated private static func loadSwatches(url: URL, size: CGSize) async -> [Color]? {
        guard let nsImage = await ImageCache.shared.image(for: url, targetSize: size) else {
            return nil
        }
        return Self.extractSwatches(from: nsImage)
    }

    nonisolated private static func loadStoryboardSwatches(sheet: StoryboardSheet) async -> [[Color]]? {
        var sets: [[Color]] = []
        var lastNonEmpty: [Color] = []
        for (sheetIndex, sheetURL) in sheet.sheetURLs.enumerated() {
            guard let nsImage = await ImageCache.shared.image(for: sheetURL, targetSize: nil),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                continue
            }
            let rects = sheet.cellRects(
                forSheetAt: sheetIndex,
                pixelWidth: cgImage.width,
                height: cgImage.height
            )
            for rect in rects {
                guard let cell = cgImage.cropping(to: rect) else { continue }
                let swatches = Self.extractSwatches(from: NSImage(cgImage: cell, size: .zero))
                if !swatches.isEmpty {
                    lastNonEmpty = swatches
                }
                sets.append(lastNonEmpty)
            }
        }
        let trimmed = sets.drop { $0.isEmpty }
        return trimmed.isEmpty ? nil : Array(trimmed)
    }

    nonisolated private static func extractSwatches(from image: NSImage, maxCount: Int = 5) -> [Color] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        let dimension = 24
        guard let context = CGContext(
            data: nil,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: dimension * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return []
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))

        guard let data = context.data else {
            return []
        }
        let pointer = data.bindMemory(to: UInt8.self, capacity: dimension * dimension * 4)

        let binCount = 12
        var weight = [Double](repeating: 0, count: binCount)
        var sumR = [Double](repeating: 0, count: binCount)
        var sumG = [Double](repeating: 0, count: binCount)
        var sumB = [Double](repeating: 0, count: binCount)

        for index in 0 ..< (dimension * dimension) {
            let offset = index * 4
            let red = Double(pointer[offset]) / 255
            let green = Double(pointer[offset + 1]) / 255
            let blue = Double(pointer[offset + 2]) / 255

            let maxC = max(red, green, blue)
            let minC = min(red, green, blue)
            let brightness = maxC
            let saturation = maxC > 0 ? (maxC - minC) / maxC : 0

            guard brightness > 0.12, brightness < 0.97, saturation > 0.18 else {
                continue
            }

            let hue = Self.hue(red: red, green: green, blue: blue, maxC: maxC, minC: minC)
            let bin = min(binCount - 1, Int(hue / 360 * Double(binCount)))
            let pixelWeight = saturation * brightness
            weight[bin] += pixelWeight
            sumR[bin] += red * pixelWeight
            sumG[bin] += green * pixelWeight
            sumB[bin] += blue * pixelWeight
        }

        let clusters = (0 ..< binCount)
            .filter { weight[$0] > 0 }
            .map { bin in
                (weight: weight[bin], color: Self.glowColor(
                    red: sumR[bin] / weight[bin],
                    green: sumG[bin] / weight[bin],
                    blue: sumB[bin] / weight[bin]
                ))
            }
            .sorted { $0.weight > $1.weight }
            .prefix(maxCount)
            .map(\.color)

        return Array(clusters)
    }

    nonisolated private static func hue(
        red: Double,
        green: Double,
        blue: Double,
        maxC: Double,
        minC: Double
    ) -> Double {
        let delta = maxC - minC
        guard delta > 0 else { return 0 }
        var hue: Double = if maxC == red {
            ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == green {
            (blue - red) / delta + 2
        } else {
            (red - green) / delta + 4
        }
        hue *= 60
        return hue < 0 ? hue + 360 : hue
    }

    nonisolated private static func glowColor(red: Double, green: Double, blue: Double) -> Color {
        let base = NSColor(red: red, green: green, blue: blue, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let boosted = NSColor(
            hue: hue,
            saturation: min(saturation * 1.35, 1),
            brightness: max(min(brightness * 1.1, 0.9), 0.55),
            alpha: 1
        )
        return Color(nsColor: boosted)
    }
    // swiftformat:enable modifierOrder
}

extension View {
    func ambientVideoBackdrop(
        videoId: String?,
        thumbnailURL: URL?,
        style: AmbientBackdropStyle,
        liveFraction: Double?,
        storyboardSpec: String?
    ) -> some View {
        self.background {
            AmbientVideoBackdrop(
                videoId: videoId,
                thumbnailURL: thumbnailURL,
                style: style,
                liveFraction: liveFraction,
                storyboardSpec: storyboardSpec
            )
            .ignoresSafeArea()
        }
    }
}

struct StoryboardSheet {
    let sheetURLs: [URL]
    private let cols: Int
    private let rows: Int
    private let frameCount: Int

    private static let maxGridDimension = 50
    private static let maxFrameCount = 10000
    private static let maxSheets = 8

    init?(spec: String) {
        let parts = spec.components(separatedBy: "|")
        guard parts.count >= 2 else { return nil }
        let base = parts[0]

        let levelIndex = 0
        let fields = parts[1].components(separatedBy: "#")
        guard fields.count >= 8,
              let cols = Int(fields[3]),
              let rows = Int(fields[4]),
              let frameCount = Int(fields[2]),
              cols > 0, cols <= Self.maxGridDimension,
              rows > 0, rows <= Self.maxGridDimension,
              frameCount > 0, frameCount <= Self.maxFrameCount
        else {
            return nil
        }
        let name = fields[6]
        let sigh = fields[7]

        let perSheet = cols * rows
        let sheetCount = min(
            Int((Double(frameCount) / Double(perSheet)).rounded(.up)),
            Self.maxSheets
        )
        guard sheetCount > 0 else { return nil }

        var urls: [URL] = []
        for sheet in 0 ..< sheetCount {
            let resolved = base
                .replacingOccurrences(of: "$L", with: String(levelIndex))
                .replacingOccurrences(of: "$N", with: name)
                .appending("&sigh=\(sigh)")
                .replacingOccurrences(of: "$M", with: String(sheet))
            if let url = URL(string: resolved), Self.isAllowedStoryboardURL(url) {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return nil }

        self.sheetURLs = urls
        self.cols = cols
        self.rows = rows
        self.frameCount = frameCount
    }

    func cellRects(forSheetAt sheetIndex: Int, pixelWidth width: Int, height: Int) -> [CGRect] {
        let cellW = width / self.cols
        let cellH = height / self.rows
        guard cellW > 0, cellH > 0 else { return [] }
        let perSheet = self.cols * self.rows
        let remaining = self.frameCount - sheetIndex * perSheet
        guard remaining > 0 else { return [] }
        let cellsOnThisSheet = min(perSheet, remaining)
        var rects: [CGRect] = []
        for cell in 0 ..< cellsOnThisSheet {
            let row = cell / self.cols
            let col = cell % self.cols
            rects.append(CGRect(
                x: col * cellW,
                y: row * cellH,
                width: cellW,
                height: cellH
            ))
        }
        return rects
    }

    private static func isAllowedStoryboardURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else {
            return false
        }
        return host == "ytimg.com" || host.hasSuffix(".ytimg.com")
    }
}
