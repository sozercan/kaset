import AppKit
import CoreGraphics
import SwiftUI

// MARK: - AmbientVideoBackdrop

/// PROTOTYPE — "live ambient" glow for the YouTube watch page.
///
/// We cannot sample the playing video's pixels (Widevine DRM black-frames every
/// capture path, and the surface is an opaque AppKit web view). Instead this
/// renders the effect itself: a drifting "aurora" of luminous color blobs pulled
/// from the video thumbnail — and, in `.live` mode, crossfading through the
/// colors of YouTube's non-DRM storyboard sprite-sheet cells keyed to playback
/// progress, so the color shifts as the video plays without ever touching a
/// protected frame. The page's existing Liquid Glass chrome tints over it as a
/// bonus, but the glow stands on its own.
///
/// Self-contained on purpose: it does NOT edit the shared `AccentBackground`
/// (used by the artist/playlist/podcast pages). Revert by deleting this file and
/// the `.ambientVideoBackdrop(...)` call in `YouTubeWatchView`.
struct AmbientVideoBackdrop: View {
    // MARK: Inputs

    let videoId: String?
    let thumbnailURL: URL?
    let style: AmbientBackdropStyle
    /// 0…1 playback position for `.live` crossfade; `nil` when this video is
    /// not the one actively playing (the parent guards `duration > 0`).
    var liveFraction: Double?
    /// YouTube storyboard spec for fine-grained `.live` color. When present,
    /// its sprite-sheet cells replace the coarse 3-still source. `nil` until the
    /// player publishes it (or unavailable).
    var storyboardSpec: String?

    // MARK: State

    @State private var palette: ColorExtractor.ColorPalette = .default
    /// Distinct vivid colors from the thumbnail (used by `.glow` and as the
    /// `.live` fallback when storyboard frames are unavailable).
    @State private var thumbnailSwatches: [Color] = []
    /// Per-storyboard-frame swatch sets for the `.live` crossfade.
    @State private var frameSwatches: [[Color]] = []
    /// The `videoId` the published colors belong to. The render path ignores
    /// any state whose tag doesn't match the current `videoId`, so a previous
    /// video's colors can never show through while a new load is in flight —
    /// regardless of how the async fetches interleave.
    @State private var loadedVideoId: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // MARK: Body

    var body: some View {
        Group {
            if self.style == .off {
                Color.clear
            } else if self.reduceTransparency {
                // Reduce Transparency: flatten to a near-solid low tint, no glow.
                self.flatTint
            } else {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    self.ambientContent
                }
            }
        }
        .animation(.easeInOut(duration: 0.6), value: self.palette)
        .animation(.easeInOut(duration: 0.5), value: self.style)
        .task(id: self.loadKey) {
            await self.load()
        }
    }

    /// Re-runs the loader when the video, style, or storyboard availability
    /// changes (the spec arrives a beat after playback starts).
    private var loadKey: String {
        "\(self.videoId ?? "-")|\(self.style.rawValue)|\(self.storyboardSpec != nil)"
    }

    // MARK: Ambient composition

    /// Branch on Reduce Motion rather than pausing the `TimelineView`, mirroring
    /// the repo's `PulseModifier` pattern. `.soft` is intentionally steady (no
    /// drift) so it reads as a calm version of the same glow.
    private var ambientContent: some View {
        GeometryReader { geo in
            if self.style == .soft || self.reduceMotion {
                self.auroraLayer(size: geo.size, time: nil)
            } else {
                TimelineView(.animation) { timeline in
                    self.auroraLayer(
                        size: geo.size,
                        time: timeline.date.timeIntervalSinceReferenceDate
                    )
                }
            }
        }
    }

    /// The hero: one drifting aurora, or two crossfading by playback position in
    /// `.live` mode. Both sub-layers keep orbiting so motion never stops.
    @ViewBuilder
    private func auroraLayer(size: CGSize, time: TimeInterval?) -> some View {
        let frames = self.renderFrames
        // `.soft` is the calm style: same colors, dimmer than the drifting glow.
        let intensity: Double = self.style == .soft ? 0.7 : 1.0
        // Under Reduce Motion, collapse `.live` to a single static frame: the
        // blobs already stop drifting (time: nil) and the colors must not
        // cross-fade as playback advances either.
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

    /// Whether the published color state belongs to the current video. Stale
    /// state (from a prior video, mid-transition) is treated as not-yet-loaded.
    private var colorsAreCurrent: Bool {
        self.loadedVideoId == self.videoId
    }

    /// The palette to render: the loaded one only when it belongs to the current
    /// video, otherwise the neutral default. Every palette read goes through
    /// this so no render path can show a prior video's colors mid-transition.
    private var currentPalette: ColorExtractor.ColorPalette {
        self.colorsAreCurrent ? self.palette : .default
    }

    /// The swatch set(s) feeding the aurora for the current style.
    private var renderFrames: [[Color]] {
        switch self.style {
        case .live where self.colorsAreCurrent && !self.frameSwatches.isEmpty:
            self.frameSwatches
        default:
            [self.fallbackColors]
        }
    }

    /// Thumbnail swatches, or palette-derived colors if extraction found none.
    /// Falls back to the neutral default palette until the current video's
    /// colors have actually loaded.
    private var fallbackColors: [Color] {
        if self.colorsAreCurrent, !self.thumbnailSwatches.isEmpty {
            return self.thumbnailSwatches
        }
        return [self.currentPalette.primary, self.currentPalette.secondary]
    }

    /// A single drifting field of additively-blended color blobs. Static when
    /// `time` is nil (Reduce Motion or the `.soft` style). `intensity` scales
    /// the overall brightness so `.soft` reads dimmer than the drifting glow.
    private static func aurora(
        colors: [Color],
        size: CGSize,
        time: TimeInterval?,
        colorScheme: ColorScheme,
        intensity: Double
    ) -> some View {
        let isDark = colorScheme == .dark
        // Additive light reads as "glow" on a dark base; on a light base it
        // blows out to white, so fall back to a softer source-over tint.
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

    /// Resting positions (unit coords) for up to five blobs — spread across the
    /// upper-mid field with one low so color still reaches the player bar.
    private static let layout: [(x: CGFloat, y: CGFloat)] = [
        (0.28, 0.24), (0.74, 0.20), (0.18, 0.58), (0.82, 0.64), (0.50, 0.42),
    ]

    /// Mutually-prime orbit periods (seconds) so the drift never visibly loops.
    private static let periods: [Double] = [19, 23, 29, 31, 37]
    private static let phases: [Double] = [0.0, 1.7, 3.1, 4.6, 5.9]

    /// Reduce Transparency fallback: a flat, low-opacity tint, no motion.
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

    // MARK: Loading

    private func load() async {
        guard self.style != .off else { return }

        // Resolve thumbnail colors, then publish — assigning defaults on
        // failure too, so a new video whose thumbnail is missing/fails can't
        // keep showing the previous video's colors (e.g. after SPA drift, when
        // this view instance is reused). Guarded by cancellation so a superseded
        // load never clobbers the current one.
        let resolved: (palette: ColorExtractor.ColorPalette, swatches: [Color])? = if let url = self.thumbnailURL ?? self.fallbackThumbnailURL {
            // Same URL + size the watch poster already fetches → warm cache hit,
            // no second network download.
            await Self.loadPaletteAndSwatches(url: url, size: CGSize(width: 1280, height: 720))
        } else {
            nil
        }
        if Task.isCancelled { return }
        let isNewVideo = self.loadedVideoId != self.videoId
        self.palette = resolved?.palette ?? .default
        self.thumbnailSwatches = resolved?.swatches ?? []
        // Drop the prior video's storyboard frames so `.live` falls back to the
        // (current) thumbnail colors until fresh frames load, rather than
        // briefly crossfading the old video's frames.
        if isNewVideo {
            self.frameSwatches = []
        }
        // Tag the published colors with this video. Until this runs for the
        // current `videoId`, the render path shows the neutral default rather
        // than a prior video's colors.
        self.loadedVideoId = self.videoId

        guard self.style == .live else {
            self.frameSwatches = []
            return
        }

        // Prefer the storyboard sprite sheet (dozens of timeline cells from a
        // single fetch) for moment-to-moment color; fall back to the 3 sampled
        // stills when no spec is available (live streams, age-gated, etc.).
        if let spec = self.storyboardSpec,
           let sheet = StoryboardSheet(spec: spec),
           let sets = await Self.loadStoryboardSwatches(sheet: sheet),
           !sets.isEmpty
        {
            if Task.isCancelled { return }
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
        if Task.isCancelled { return }
        self.frameSwatches = sets
    }

    /// `mqdefault.jpg` is the 16:9, no-letterbox thumbnail when the model has no
    /// `thumbnailURL`.
    private var fallbackThumbnailURL: URL? {
        guard let videoId else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg")
    }

    /// YouTube's three evenly-sampled storyboard stills (start/mid/end) — the
    /// `.live` fallback when no full storyboard spec is available.
    private func storyboardFrameURLs() -> [URL] {
        guard let videoId else { return [] }
        return (1 ... 3).compactMap { URL(string: "https://i.ytimg.com/vi/\(videoId)/\($0).jpg") }
    }

    // MARK: Off-main extraction

    //
    // `nonisolated` so the CPU-bound pixel work runs off the main actor and the
    // non-Sendable `NSImage` never escapes into MainActor state — only the
    // Sendable `[Color]` / `ColorPalette` cross back.

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

    /// Fetches the storyboard sheet(s) and extracts one swatch set per cell, in
    /// timeline order, so the existing `liveFraction` crossfade walks them as
    /// the video plays. Dark cells (no vivid color) carry the previous cell's
    /// swatches forward so the glow never drops to black mid-timeline.
    nonisolated private static func loadStoryboardSwatches(sheet: StoryboardSheet) async -> [[Color]]? {
        var sets: [[Color]] = []
        var lastNonEmpty: [Color] = []
        for (sheetIndex, sheetURL) in sheet.sheetURLs.enumerated() {
            // Fetch at full size (nil) — downsampling a multi-cell sheet would
            // corrupt the per-cell crops.
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
        // Drop any leading empties (dark cells before the first vivid one) so
        // the crossfade starts on real color.
        let trimmed = sets.drop { $0.isEmpty }
        return trimmed.isEmpty ? nil : Array(trimmed)
    }

    /// Pulls up to five distinct, vivid colors from an image by binning pixels
    /// by hue and keeping the most saturated-and-bright clusters. Unlike
    /// `ColorExtractor`'s single weighted average, this preserves multiple hues
    /// so the aurora has real color variety to move between.
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

            // Skip near-black, near-white, and washed-out pixels.
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

    /// HSB hue in degrees from RGB extremes.
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

    /// Boosts a cluster's saturation and normalizes brightness so it reads as
    /// emitted light in the aurora rather than a muddy average.
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

// MARK: - View modifier

extension View {
    /// Applies the prototype ambient glow full-bleed behind the content.
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

// MARK: - StoryboardSheet

/// Parses a YouTube storyboard spec string into fetchable sprite-sheet URLs and
/// per-cell crop rects. Format confirmed against yt-dlp / NewPipe and a live
/// video: `base|level0|level1|…`, where `base` is a URL template with `$L`/`$N`
/// placeholders and each level is `width#height#frameCount#cols#rows#interval#N#sigh`.
///
/// Prefers Level 0 (typically a single `default.jpg` of ~100 cells), so one HTTP
/// fetch yields dozens of evenly-spaced timeline samples — ideal for ambient
/// color. All grid values are parsed from the live spec, never hardcoded.
struct StoryboardSheet {
    let sheetURLs: [URL]
    private let cols: Int
    private let rows: Int
    private let frameCount: Int

    /// Sanity caps on values parsed from the (untrusted) WebView spec, so a
    /// malformed or hostile spec can't overflow the arithmetic or trigger a
    /// flood of image fetches. A real Level-0 sheet is ~10×10 = 100 cells in a
    /// single image; these ceilings sit comfortably above that and fail closed.
    private static let maxGridDimension = 50
    private static let maxFrameCount = 10000
    private static let maxSheets = 8

    init?(spec: String) {
        let parts = spec.components(separatedBy: "|")
        guard parts.count >= 2 else { return nil }
        let base = parts[0]

        // Pick Level 0 — the densest single sheet (one fetch, most cells).
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
            // The spec comes from the WebView; only fetch it natively when it
            // resolves to an https YouTube image host, so a hostile/mutated
            // spec can't point native requests at private/non-YouTube hosts.
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

    /// Row-major crop rects (top-left origin, matching `CGImage.cropping`) for
    /// the real frames on the sheet at `sheetIndex`, derived from the actual
    /// fetched sheet pixel dimensions so we don't trust the spec's nominal cell
    /// size. The last sheet is capped to the remaining frames so padding cells
    /// (when `frameCount` isn't an exact multiple of the grid) aren't sampled —
    /// otherwise the tail color would stick across the padded cells.
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

    /// Whether a resolved storyboard URL is safe to fetch natively: `https`
    /// scheme on a YouTube image host. Guards the WebView→native trust boundary.
    private static func isAllowedStoryboardURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else {
            return false
        }
        return host == "ytimg.com" || host.hasSuffix(".ytimg.com")
    }
}
