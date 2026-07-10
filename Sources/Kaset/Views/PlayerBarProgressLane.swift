import SwiftUI

// MARK: - PlayerBarProgressLane

struct PlayerBarProgressLane: View {
    let fraction: Double
    let accent: Color
    let elapsedText: String
    let remainingText: String
    let markers: [PlayerBarProgressMarker]
    let segments: [PlayerBarProgressSegment]
    let isLive: Bool
    let canSeek: Bool
    let isLoading: Bool
    let onScrub: (Double) -> Void
    let onCommit: () -> Void
    let onMarkerPreviewChange: (PlayerBarProgressMarker?) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragging = false
    @State private var isHovering = false
    @State private var dragFraction: Double?
    @State private var previewChapterMarker: PlayerBarProgressMarker?
    @State private var hoveredSegment: PlayerBarProgressSegment?
    @State private var tooltipSize: CGSize = .zero

    private var clampedFraction: CGFloat {
        CGFloat(min(max(0, self.fraction), 1))
    }

    init(
        fraction: Double,
        accent: Color,
        elapsedText: String,
        remainingText: String,
        markers: [PlayerBarProgressMarker] = [],
        segments: [PlayerBarProgressSegment] = [],
        isLive: Bool,
        canSeek: Bool,
        isLoading: Bool,
        onScrub: @escaping (Double) -> Void,
        onCommit: @escaping () -> Void,
        onMarkerPreviewChange: @escaping (PlayerBarProgressMarker?) -> Void = { _ in }
    ) {
        self.fraction = fraction
        self.accent = accent
        self.elapsedText = elapsedText
        self.remainingText = remainingText
        self.markers = markers
        self.segments = segments
        self.isLive = isLive
        self.canSeek = canSeek
        self.isLoading = isLoading
        self.onScrub = onScrub
        self.onCommit = onCommit
        self.onMarkerPreviewChange = onMarkerPreviewChange
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(self.isLive ? String(localized: "LIVE") : self.elapsedText)
                    .foregroundStyle(self.isLive ? .red : .secondary)

                Spacer(minLength: 8)

                Text(self.isLive ? "" : self.remainingText)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .lineLimit(1)
            .frame(height: 12)

            self.progressBar
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Playback position"))
        .accessibilityValue(self.isLive ? String(localized: "Live stream") : "\(self.elapsedText), \(self.remainingText)")
        .accessibilityAdjustableAction { direction in
            guard self.canSeek else { return }
            switch direction {
            case .increment:
                self.nudge(by: 0.02)
            case .decrement:
                self.nudge(by: -0.02)
            @unknown default:
                break
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fillWidth = width * self.clampedFraction
            let thumbDiameter = PlayerBarSliderVisuals.thumbDiameter(
                isHovering: self.isHovering,
                isDragging: self.isDragging
            )
            let fillColor = self.isLoading ? self.loadingFillColor : self.accent
            let thumbColor = self.isLoading ? self.loadingThumbColor : self.accent
            let previewMarker = self.previewChapterMarker

            ZStack(alignment: .topLeading) {
                if self.segments.isEmpty {
                    Capsule()
                        .fill(self.trackColor)
                        .frame(height: PlayerBarSliderVisuals.trackThickness)

                    UnevenRoundedRectangle(
                        topLeadingRadius: 999,
                        bottomLeadingRadius: 999
                    )
                    .fill(fillColor)
                    .frame(width: fillWidth, height: PlayerBarSliderVisuals.trackThickness)
                    .opacity(self.isLive ? 0 : 1)
                } else {
                    self.segmentedTrack(width: width, fillColor: fillColor)
                }

                if self.isLoading {
                    PlayerBarSliderLoadingShimmer(
                        colorScheme: self.colorScheme,
                        reduceMotion: self.reduceMotion
                    )
                    .frame(height: PlayerBarSliderVisuals.trackThickness)
                    .transition(.opacity)
                }

                if self.segments.isEmpty {
                    ForEach(self.markers) { marker in
                        let isHighlighted = marker.id == previewMarker?.id
                        self.markerView(marker, isHighlighted: isHighlighted)
                            .offset(
                                x: self.markerX(marker, trackWidth: width, isHighlighted: isHighlighted),
                                y: -3
                            )
                            .opacity(self.isLive || self.isLoading ? 0 : 1)
                            .accessibilityHidden(true)
                    }
                }

                Circle()
                    .fill(thumbColor)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .offset(
                        x: min(max(0, fillWidth - thumbDiameter / 2), max(0, width - thumbDiameter)),
                        y: PlayerBarSliderVisuals.trackThickness / 2 - thumbDiameter / 2
                    )
                    .opacity(self.canSeek ? 1 : 0)

                if let segment = self.hoveredSegment, !self.isLoading, !self.isLive {
                    self.segmentTooltip(segment)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { self.tooltipSize = $0 }
                        .offset(
                            x: self.tooltipLeadingX(segment, width: width),
                            y: -(self.tooltipSize.height + 10)
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(PlayerBarSliderVisuals.trackAnimation, value: self.isHovering)
            .animation(PlayerBarSliderVisuals.thumbAnimation, value: self.isDragging)
            .animation(PlayerBarSliderVisuals.thumbAnimation, value: self.isHovering)
            .animation(.easeInOut(duration: 0.18), value: self.isLoading)
            .animation(.easeOut(duration: 0.14), value: self.hoveredSegment)
            .padding(PlayerBarSliderVisuals.hitOutset)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard self.canSeek, width > 0 else { return }
                        self.isDragging = true
                        let x = value.location.x - PlayerBarSliderVisuals.hitOutset
                        let fraction = Double(min(max(0, x / width), 1))
                        self.dragFraction = fraction
                        self.updatePreviewMarker(self.nearestMarker(to: fraction, width: width))
                        self.onScrub(fraction)
                    }
                    .onEnded { value in
                        defer {
                            self.dragFraction = nil
                            self.updatePreviewMarker(nil)
                            self.isDragging = false
                        }
                        guard self.canSeek, width > 0 else { return }
                        let x = value.location.x - PlayerBarSliderVisuals.hitOutset
                        let fraction = Double(min(max(0, x / width), 1))
                        let targetFraction = self.snappedFraction(fraction, width: width)
                        self.onScrub(targetFraction)
                        self.onCommit()
                    }
            )
            .onContinuousHover { phase in
                guard width > 0 else { return }
                switch phase {
                case let .active(location):
                    let x = location.x - PlayerBarSliderVisuals.hitOutset
                    let fraction = Double(min(max(0, x / width), 1))
                    if self.dragFraction == nil {
                        self.updatePreviewMarker(self.nearestMarker(to: fraction, width: width))
                        self.updateHoveredSegment(self.segment(at: fraction))
                    }
                case .ended:
                    if self.dragFraction == nil {
                        self.updatePreviewMarker(nil)
                        self.updateHoveredSegment(nil)
                    }
                }
            }
            .padding(-PlayerBarSliderVisuals.hitOutset)
            .onHover { hovering in
                self.isHovering = hovering
                if !hovering, self.dragFraction == nil {
                    self.updatePreviewMarker(nil)
                    self.updateHoveredSegment(nil)
                }
            }
        }
        .frame(height: 12)
    }

    private func updatePreviewMarker(_ marker: PlayerBarProgressMarker?) {
        guard self.previewChapterMarker != marker else { return }
        self.previewChapterMarker = marker
        self.onMarkerPreviewChange(marker)
    }

    private func updateHoveredSegment(_ segment: PlayerBarProgressSegment?) {
        guard self.hoveredSegment != segment else { return }
        self.hoveredSegment = segment
    }

    /// The segment whose span contains the given progress fraction (last one starting at or before it).
    private func segment(at fraction: Double) -> PlayerBarProgressSegment? {
        self.segments.last { $0.start <= fraction }
    }

    // MARK: - Segmented Track

    /// Gap between adjacent segment pieces, in points. Split across the shared edge.
    private static let segmentGap: CGFloat = 3

    @ViewBuilder
    private func segmentedTrack(width: CGFloat, fillColor: Color) -> some View {
        let gap = Self.segmentGap
        ZStack(alignment: .topLeading) {
            ForEach(self.segments) { segment in
                let rawX = CGFloat(segment.start) * width
                let rawWidth = CGFloat(segment.end - segment.start) * width
                let leftGap: CGFloat = segment.index == 0 ? 0 : gap / 2
                let rightGap: CGFloat = segment.index == segment.count - 1 ? 0 : gap / 2
                let pieceWidth = max(1, rawWidth - leftGap - rightGap)
                let within = self.playedFraction(within: segment)
                let isHovered = segment.id == self.hoveredSegment?.id

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(isHovered ? self.hoveredSegmentTrackColor : self.trackColor)
                        .frame(width: pieceWidth, height: PlayerBarSliderVisuals.trackThickness)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(fillColor)
                        .frame(width: pieceWidth * within, height: PlayerBarSliderVisuals.trackThickness)
                        .opacity(self.isLive ? 0 : 1)
                }
                .frame(width: pieceWidth, alignment: .leading)
                .scaleEffect(y: isHovered ? 2.0 : 1, anchor: .center)
                .offset(x: rawX + leftGap)
                .animation(PlayerBarSliderVisuals.thumbAnimation, value: isHovered)
            }
        }
    }

    /// How far playback has progressed through a segment, 0...1.
    private func playedFraction(within segment: PlayerBarProgressSegment) -> CGFloat {
        let span = segment.end - segment.start
        guard span > 0 else { return 0 }
        let progressed = (Double(self.clampedFraction) - segment.start) / span
        return CGFloat(min(max(0, progressed), 1))
    }

    private var hoveredSegmentTrackColor: Color {
        self.colorScheme == .dark ? .white.opacity(0.34) : .black.opacity(0.30)
    }

    // MARK: - Segment Tooltip

    private func segmentTooltip(_ segment: PlayerBarProgressSegment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(segment.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let subtitle = segment.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text("\(String(localized: "Track")) \(segment.index + 1)/\(segment.count)  ·  \(segment.rangeText)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.primary.opacity(self.colorScheme == .dark ? 0.16 : 0.10), lineWidth: 0.6)
                }
                .shadow(color: .black.opacity(self.colorScheme == .dark ? 0.5 : 0.22), radius: 10, y: 4)
        }
    }

    /// Leading edge for the tooltip so its centre tracks the segment, clamped inside the track.
    private func tooltipLeadingX(_ segment: PlayerBarProgressSegment, width: CGFloat) -> CGFloat {
        let center = CGFloat((segment.start + segment.end) / 2) * width
        let leading = center - self.tooltipSize.width / 2
        return min(max(0, leading), max(0, width - self.tooltipSize.width))
    }

    private func markerX(_ marker: PlayerBarProgressMarker, trackWidth: CGFloat, isHighlighted: Bool) -> CGFloat {
        // Marker and thumb offsets are inside the visual-track ZStack. Gesture
        // locations subtract `hitOutset` because the gesture is attached after
        // padding expands the hit target; visual offsets do not include it.
        let markerWidth = self.markerWidth(isHighlighted: isHighlighted)
        return min(
            max(0, trackWidth * CGFloat(marker.fraction) - markerWidth / 2),
            max(0, trackWidth - markerWidth)
        )
    }

    private func markerView(_: PlayerBarProgressMarker, isHighlighted: Bool) -> some View {
        Capsule()
            .fill(self.markerFallbackFill(isHighlighted: isHighlighted))
            .frame(
                width: self.markerWidth(isHighlighted: isHighlighted),
                height: self.markerHeight(isHighlighted: isHighlighted)
            )
            .compatGlass(
                interactive: isHighlighted,
                tint: self.markerGlassTint(isHighlighted: isHighlighted),
                in: .capsule
            )
            .overlay {
                Capsule()
                    .strokeBorder(self.markerRimColor(isHighlighted: isHighlighted), lineWidth: 0.6)
            }
            .shadow(
                color: self.markerShadowColor(isHighlighted: isHighlighted),
                radius: isHighlighted ? 5 : 1.5,
                y: isHighlighted ? 2 : 0.5
            )
            .animation(PlayerBarSliderVisuals.thumbAnimation, value: isHighlighted)
    }

    private func markerWidth(isHighlighted: Bool) -> CGFloat {
        isHighlighted ? 8 : 4
    }

    private func markerHeight(isHighlighted: Bool) -> CGFloat {
        PlayerBarSliderVisuals.trackThickness + (isHighlighted ? 10 : 7)
    }

    private func snappedFraction(_ fraction: Double, width: CGFloat) -> Double {
        self.nearestMarker(to: fraction, width: width)?.fraction ?? fraction
    }

    private func nearestMarker(to fraction: Double, width: CGFloat) -> PlayerBarProgressMarker? {
        guard !self.markers.isEmpty, width > 0 else { return nil }
        let threshold = max(0.006, min(0.025, 14 / Double(width)))
        return self.markers
            .map { marker in (marker: marker, distance: abs(marker.fraction - fraction)) }
            .filter { $0.distance <= threshold }
            .min { lhs, rhs in lhs.distance < rhs.distance }?
            .marker
    }

    private func nudge(by delta: Double) {
        self.onScrub(min(1, max(0, self.fraction + delta)))
        self.onCommit()
    }

    private var trackColor: Color {
        PlayerBarSliderVisuals.trackColor(
            colorScheme: self.colorScheme,
            isActive: !self.isLoading && (self.isHovering || self.isDragging)
        )
    }

    private var loadingFillColor: Color {
        PlayerBarSliderVisuals.loadingFillColor(colorScheme: self.colorScheme)
    }

    private var loadingThumbColor: Color {
        PlayerBarSliderVisuals.loadingThumbColor(colorScheme: self.colorScheme)
    }

    private func markerGlassTint(isHighlighted: Bool) -> Color {
        if isHighlighted {
            return self.accent.opacity(self.colorScheme == .dark ? 0.48 : 0.34)
        }
        return self.colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.06)
    }

    private func markerFallbackFill(isHighlighted: Bool) -> Color {
        if isHighlighted {
            return self.accent.opacity(self.colorScheme == .dark ? 0.50 : 0.34)
        }
        return self.colorScheme == .dark ? .white.opacity(0.20) : .black.opacity(0.14)
    }

    private func markerRimColor(isHighlighted: Bool) -> Color {
        if isHighlighted {
            return self.colorScheme == .dark ? .white.opacity(0.42) : .white.opacity(0.72)
        }
        return self.colorScheme == .dark ? .white.opacity(0.26) : .white.opacity(0.58)
    }

    private func markerShadowColor(isHighlighted: Bool) -> Color {
        if isHighlighted {
            return self.accent.opacity(self.colorScheme == .dark ? 0.36 : 0.22)
        }
        return .black.opacity(self.colorScheme == .dark ? 0.18 : 0.08)
    }
}

// MARK: - PlayerBarProgressMarker

struct PlayerBarProgressMarker: Identifiable, Hashable {
    let id: String
    let fraction: Double
    let title: String?
    let subtitle: String?

    init(id: String, fraction: Double, title: String? = nil, subtitle: String? = nil) {
        self.id = id
        self.fraction = min(max(0, fraction), 1)
        self.title = title
        self.subtitle = subtitle
    }
}

// MARK: - PlayerBarProgressSegment

/// A contiguous span of the seek bar corresponding to one sub-track of a mix. When a lane is given
/// segments it renders a YouTube-style gapped track (one piece per segment) instead of the single
/// continuous bar, and reveals the segment's label on hover.
struct PlayerBarProgressSegment: Identifiable, Hashable {
    let id: String
    let start: Double
    let end: Double
    let index: Int
    let count: Int
    let title: String
    let subtitle: String?
    let rangeText: String

    init(
        id: String,
        start: Double,
        end: Double,
        index: Int,
        count: Int,
        title: String,
        subtitle: String? = nil,
        rangeText: String = ""
    ) {
        self.id = id
        self.start = min(max(0, start), 1)
        self.end = min(max(0, end), 1)
        self.index = index
        self.count = count
        self.title = title
        self.subtitle = subtitle
        self.rangeText = rangeText
    }

    /// Whether the given progress fraction falls within this segment.
    func contains(_ fraction: Double) -> Bool {
        fraction >= self.start && fraction < self.end
    }
}
