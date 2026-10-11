import AppKit
import SwiftUI

// MARK: - PlayerBarMarqueeText

/// A single-line title that scrolls like a marquee when it overflows its width.
///
/// The scroll and the edge fades are Core Animation keyframe animations, so the render
/// server draws every frame. Animated SwiftUI state here made the app re-render its whole
/// window on every display refresh for as long as a long title scrolled (~20% CPU on any
/// page).
struct PlayerBarMarqueeText: View {
    let text: String
    let font: NSFont
    let color: NSColor
    let height: CGFloat
    let reduceMotion: Bool

    var body: some View {
        PlayerBarMarqueeLabel(text: self.text, font: self.font, color: self.color, reduceMotion: self.reduceMotion)
            .frame(height: self.height)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: self.text))
            // The hosted view has no role of its own; without this it reads as AXUnknown.
            .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - PlayerBarMarqueeLabel

private struct PlayerBarMarqueeLabel: NSViewRepresentable {
    let text: String
    let font: NSFont
    let color: NSColor
    let reduceMotion: Bool

    func makeNSView(context _: Context) -> PlayerBarMarqueeView {
        PlayerBarMarqueeView()
    }

    func updateNSView(_ view: PlayerBarMarqueeView, context: Context) {
        view.configure(PlayerBarMarqueeView.Configuration(
            text: self.text,
            font: self.font,
            color: self.color,
            reduceMotion: self.reduceMotion,
            isRightToLeft: context.environment.layoutDirection == .rightToLeft
        ))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: PlayerBarMarqueeView, context _: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

// MARK: - PlayerBarMarqueeCycle

/// One repetition of the marquee: rest, scroll one copy's width, then fade back to rest.
///
/// The cycle starts right after the previous scroll's reset fade, so a repeating
/// animation begun `resetFadeDuration` after the title appears waits the full
/// `initialDelay` before its first scroll, like every later one.
struct PlayerBarMarqueeCycle: Equatable {
    enum FadePhase: Equatable {
        case inactive
        case bothEdges
        case trailingOnly

        var showsLeadingFade: Bool {
            self == .bothEdges
        }

        var showsTrailingFade: Bool {
            self == .bothEdges || self == .trailingOnly
        }
    }

    struct Keyframe<Value: Equatable>: Equatable {
        let time: TimeInterval
        let value: Value
    }

    static let copyGap: CGFloat = 24
    static let initialDelay: TimeInterval = 1.4
    static let scrollSpeed: CGFloat = 18
    static let fadeDuration: TimeInterval = 0.18
    static let resetFadeDuration: TimeInterval = 0.2

    let travel: CGFloat
    let scrollDuration: TimeInterval
    let leadingFadeDuration: TimeInterval

    /// Nil when the text fits, or when Reduce Motion is on.
    init?(textWidth: CGFloat, containerWidth: CGFloat, reduceMotion: Bool) {
        guard !reduceMotion, containerWidth > 0, textWidth > containerWidth + 1 else { return nil }
        self.travel = textWidth + Self.copyGap
        self.scrollDuration = max(TimeInterval(self.travel / Self.scrollSpeed), 0.1)
        self.leadingFadeDuration = max(TimeInterval(textWidth / Self.scrollSpeed), 0.1)
    }

    var period: TimeInterval {
        Self.initialDelay + self.scrollDuration
    }

    private var restDuration: TimeInterval {
        Self.initialDelay - Self.resetFadeDuration
    }

    /// Distance scrolled toward the leading edge. Jumps back to 0 when the second copy
    /// reaches the first copy's starting position.
    var offsetKeyframes: [Keyframe<CGFloat>] {
        let scrollEnd = self.restDuration + self.scrollDuration
        return [
            Keyframe(time: 0, value: 0),
            Keyframe(time: self.restDuration, value: 0),
            Keyframe(time: scrollEnd, value: self.travel),
            Keyframe(time: scrollEnd, value: 0),
            Keyframe(time: self.period, value: 0),
        ]
    }

    /// Edge-fade phases; Core Animation eases between consecutive keyframes.
    var fadeKeyframes: [Keyframe<FadePhase>] {
        let leadingFadeEnd = self.restDuration + self.leadingFadeDuration
        let scrollEnd = self.restDuration + self.scrollDuration
        return [
            Keyframe(time: 0, value: .inactive),
            Keyframe(time: self.restDuration, value: .inactive),
            Keyframe(time: self.restDuration + Self.fadeDuration, value: .bothEdges),
            Keyframe(time: leadingFadeEnd, value: .bothEdges),
            Keyframe(time: leadingFadeEnd + Self.fadeDuration, value: .trailingOnly),
            Keyframe(time: scrollEnd, value: .trailingOnly),
            Keyframe(time: self.period, value: .inactive),
        ]
    }
}

// MARK: - PlayerBarMarqueeView

/// Layer-backed marquee label: two text copies on a scrolling layer, clipped and faded
/// by a gradient mask.
final class PlayerBarMarqueeView: NSView {
    struct Configuration: Equatable {
        var text: String
        var font: NSFont
        var color: NSColor
        var reduceMotion: Bool
        var isRightToLeft: Bool
    }

    static let scrollAnimationKey = "marqueeScroll"
    static let fadeAnimationKey = "marqueeFade"

    /// Room below the frame for descenders, which the title's line box overflows.
    private static let descenderAllowance: CGFloat = 3

    private let scrollLayer = CALayer()
    private let textLayers = [CATextLayer(), CATextLayer()]
    private let fadeMask = CAGradientLayer()
    private(set) var configuration: Configuration?
    private(set) var cycle: PlayerBarMarqueeCycle?
    /// Set when the scroll must start over from rest even if `cycle` is unchanged.
    private var needsCycleRestart = true
    private var textSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        for textLayer in self.textLayers {
            textLayer.anchorPoint = .zero
            textLayer.truncationMode = .none
            textLayer.isWrapped = false
            self.scrollLayer.addSublayer(textLayer)
        }
        self.scrollLayer.anchorPoint = .zero
        self.layer?.addSublayer(self.scrollLayer)
        self.fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        self.fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        self.applyFadePhase(.inactive)
        self.layer?.mask = self.fadeMask
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    /// Decorative: clicks and the context menu belong to the player bar underneath.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    func configure(_ configuration: Configuration) {
        guard configuration != self.configuration else { return }
        let previous = self.configuration
        self.configuration = configuration
        if previous?.text != configuration.text || previous?.font != configuration.font {
            let size = (configuration.text as NSString).size(withAttributes: [.font: configuration.font])
            self.textSize = CGSize(width: ceil(size.width), height: ceil(size.height))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for textLayer in self.textLayers {
                textLayer.string = configuration.text
                textLayer.font = configuration.font
                textLayer.fontSize = configuration.font.pointSize
            }
            CATransaction.commit()
            // Restart from rest for a new title.
            self.needsCycleRestart = true
        }
        self.needsLayout = true
        self.needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let configuration else { return }
        let width = self.bounds.width
        let textWidth = self.textSize.width
        let leadingX = configuration.isRightToLeft ? width - textWidth : 0
        // Second copy trails the first by one gap, on the side the text scrolls toward.
        let copyStep = (textWidth + PlayerBarMarqueeCycle.copyGap) * (configuration.isRightToLeft ? -1 : 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = self.window?.backingScaleFactor ?? 2
        for (index, textLayer) in self.textLayers.enumerated() {
            textLayer.bounds = CGRect(origin: .zero, size: self.textSize)
            textLayer.position = CGPoint(x: leadingX + CGFloat(index) * copyStep, y: 0)
            textLayer.contentsScale = scale
        }
        self.scrollLayer.frame = self.bounds
        self.fadeMask.frame = CGRect(x: 0, y: 0, width: width, height: self.bounds.height + Self.descenderAllowance)
        let (start, end) = configuration.isRightToLeft ? (CGFloat(1), CGFloat(0)) : (CGFloat(0), CGFloat(1))
        self.fadeMask.startPoint = CGPoint(x: start, y: 0.5)
        self.fadeMask.endPoint = CGPoint(x: end, y: 0.5)
        CATransaction.commit()

        self.updateCycle()
    }

    override func updateLayer() {
        guard let configuration else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = configuration.color.cgColor
            self.textLayers.forEach { $0.foregroundColor = color }
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The text color is dynamic; `updateLayer` re-resolves it.
        self.needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animations do nothing off-window; start the cycle fresh on attach.
        self.needsCycleRestart = true
        self.needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        self.needsLayout = true
    }

    /// Starts, restarts, or stops the repeating animations when their inputs change.
    private func updateCycle() {
        guard let configuration else { return }
        let cycle = PlayerBarMarqueeCycle(
            textWidth: self.textSize.width,
            containerWidth: self.bounds.width,
            reduceMotion: configuration.reduceMotion
        )
        guard self.needsCycleRestart || cycle != self.cycle else { return }
        self.needsCycleRestart = false
        self.cycle = cycle

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.scrollLayer.removeAnimation(forKey: Self.scrollAnimationKey)
        self.fadeMask.removeAnimation(forKey: Self.fadeAnimationKey)
        self.textLayers[1].isHidden = cycle == nil
        defer { CATransaction.commit() }
        guard let cycle, self.window != nil else { return }

        let direction: CGFloat = configuration.isRightToLeft ? 1 : -1
        let beginTime = CACurrentMediaTime() + PlayerBarMarqueeCycle.resetFadeDuration

        let scroll = CAKeyframeAnimation(keyPath: "transform.translation.x")
        scroll.values = cycle.offsetKeyframes.map { direction * $0.value }
        scroll.keyTimes = Self.keyTimes(cycle.offsetKeyframes, period: cycle.period)
        scroll.calculationMode = .linear
        Self.repeatForever(scroll, period: cycle.period, beginTime: self.scrollLayer.convertTime(beginTime, from: nil))
        self.scrollLayer.add(scroll, forKey: Self.scrollAnimationKey)

        let fadeKeyTimes = Self.keyTimes(cycle.fadeKeyframes, period: cycle.period)
        let easing = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: fadeKeyTimes.count - 1)
        let colors = CAKeyframeAnimation(keyPath: "colors")
        colors.values = cycle.fadeKeyframes.map { Self.maskColors(for: $0.value) }
        colors.keyTimes = fadeKeyTimes
        colors.timingFunctions = easing
        let locations = CAKeyframeAnimation(keyPath: "locations")
        locations.values = cycle.fadeKeyframes.map { Self.maskLocations(for: $0.value) }
        locations.keyTimes = fadeKeyTimes
        locations.timingFunctions = easing
        let fade = CAAnimationGroup()
        fade.animations = [colors, locations]
        Self.repeatForever(fade, period: cycle.period, beginTime: self.fadeMask.convertTime(beginTime, from: nil))
        self.fadeMask.add(fade, forKey: Self.fadeAnimationKey)
    }

    private func applyFadePhase(_ phase: PlayerBarMarqueeCycle.FadePhase) {
        self.fadeMask.colors = Self.maskColors(for: phase)
        self.fadeMask.locations = Self.maskLocations(for: phase)
    }

    private static func repeatForever(_ animation: CAAnimation, period: TimeInterval, beginTime: CFTimeInterval) {
        animation.duration = period
        animation.repeatCount = .infinity
        animation.beginTime = beginTime
        animation.fillMode = .backwards
    }

    private static func keyTimes(_ keyframes: [PlayerBarMarqueeCycle.Keyframe<some Equatable>], period: TimeInterval) -> [NSNumber] {
        keyframes.map { NSNumber(value: $0.time / period) }
    }

    private static func maskColors(for phase: PlayerBarMarqueeCycle.FadePhase) -> [CGColor] {
        let opaque = NSColor.black.cgColor
        let clear = NSColor.clear.cgColor
        return [phase.showsLeadingFade ? clear : opaque, opaque, opaque, phase.showsTrailingFade ? clear : opaque]
    }

    private static func maskLocations(for phase: PlayerBarMarqueeCycle.FadePhase) -> [NSNumber] {
        [0, phase.showsLeadingFade ? 0.18 : 0, phase.showsTrailingFade ? 0.82 : 1, 1]
    }
}
