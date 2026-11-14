import AppKit
import SwiftUI

// MARK: - EqualizerView

/// An animated equalizer view that shows audio levels, commonly used as a "now playing" indicator.
/// Displays animated bars that move up and down to simulate audio visualization.
///
/// The bars are layers driven by repeating Core Animation animations, so the render
/// server draws every frame. A SwiftUI `repeatForever` animation here made the app
/// re-render and hit-test its whole window on every display refresh for as long as
/// the playing row was on screen (40–80% CPU on a playlist page).
struct EqualizerView: NSViewRepresentable {
    /// Whether the equalizer is animating (playing state).
    var isAnimating: Bool

    /// Number of bars to display.
    var barCount: Int = 3

    /// Spacing between bars.
    var spacing: CGFloat = 2

    /// Bar width.
    var barWidth: CGFloat = 3

    /// Bar corner radius.
    var cornerRadius: CGFloat = 1.5

    /// Bar color.
    var color: Color = .red

    func makeNSView(context _: Context) -> EqualizerBarsView {
        EqualizerBarsView()
    }

    func updateNSView(_ view: EqualizerBarsView, context: Context) {
        view.configure(EqualizerBarsView.Configuration(
            isAnimating: self.isAnimating,
            reduceMotion: context.environment.accessibilityReduceMotion,
            barCount: self.barCount,
            spacing: self.spacing,
            barWidth: self.barWidth,
            cornerRadius: self.cornerRadius,
            color: NSColor(self.color)
        ))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: EqualizerBarsView, context _: Context) -> CGSize? {
        let count = CGFloat(max(self.barCount, 0))
        let width = count * self.barWidth + max(count - 1, 0) * self.spacing
        return CGSize(width: width, height: proposal.height ?? 10)
    }
}

// MARK: - EqualizerBarsView

/// Layer-backed bars for `EqualizerView`. Each bar grows from the view's bottom edge;
/// its height, not a scale, animates so the rounded ends stay round.
final class EqualizerBarsView: NSView {
    struct Configuration: Equatable {
        var isAnimating: Bool
        var reduceMotion: Bool
        var barCount: Int
        var spacing: CGFloat
        var barWidth: CGFloat
        var cornerRadius: CGFloat
        var color: NSColor
    }

    /// Timing and range for one bar, varied by index for a natural look.
    struct BarProfile: Equatable {
        let delay: TimeInterval
        let duration: TimeInterval
        let restingFraction: CGFloat
        let peakFraction: CGFloat

        /// Height fraction a bar animates up from, and holds during its staggered start.
        static let startFraction: CGFloat = 0.3

        /// Height fraction for every bar when Reduce Motion is on.
        static let reducedMotionFraction: CGFloat = 0.5

        init(index: Int) {
            self.delay = Double(index) * 0.15
            switch index % 3 {
            case 0:
                self.duration = 0.4
                self.restingFraction = 0.15
                self.peakFraction = 0.9
            case 1:
                self.duration = 0.5
                self.restingFraction = 0.2
                self.peakFraction = 1.0
            default:
                self.duration = 0.35
                self.restingFraction = 0.1
                self.peakFraction = 0.75
            }
        }
    }

    /// Everything the bars' heights and animations derive from.
    private struct AnimationState: Equatable {
        var isAnimating: Bool
        var reduceMotion: Bool
        var isInWindow: Bool
        var barCount: Int
        var height: CGFloat
    }

    static let animationKey = "equalizer"

    private(set) var configuration: Configuration?
    private(set) var barLayers: [CALayer] = []
    private var animationState: AnimationState?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
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

    /// Decorative: clicks and context menus belong to the row underneath.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    func configure(_ configuration: Configuration) {
        guard configuration != self.configuration else { return }
        self.configuration = configuration

        if configuration.barCount != self.barLayers.count {
            self.barLayers.forEach { $0.removeFromSuperlayer() }
            self.barLayers = (0 ..< max(configuration.barCount, 0)).map { _ in
                let bar = CALayer()
                // Grow from the bottom edge (the view is flipped).
                bar.anchorPoint = CGPoint(x: 0.5, y: 1)
                self.layer?.addSublayer(bar)
                return bar
            }
        }
        self.needsLayout = true
        self.needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let configuration else { return }
        let contentWidth = CGFloat(self.barLayers.count) * configuration.barWidth
            + CGFloat(max(self.barLayers.count - 1, 0)) * configuration.spacing
        let originX = (self.bounds.width - contentWidth) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in self.barLayers.enumerated() {
            let x = originX + CGFloat(index) * (configuration.barWidth + configuration.spacing)
            bar.bounds.size.width = configuration.barWidth
            bar.position = CGPoint(x: x + configuration.barWidth / 2, y: self.bounds.height)
            bar.cornerRadius = configuration.cornerRadius
        }
        CATransaction.commit()
        self.updateAnimations()
    }

    override func updateLayer() {
        guard let configuration else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = configuration.color.cgColor
            self.barLayers.forEach { $0.backgroundColor = color }
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The bar color is dynamic; `updateLayer` re-resolves it.
        self.needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animations do nothing off-window; start each bar's cycle fresh on attach.
        self.animationState = nil
        self.needsLayout = true
    }

    /// Sets each bar's resting height and (re)starts its animation when an input changed.
    private func updateAnimations() {
        guard let configuration else { return }
        let state = AnimationState(
            isAnimating: configuration.isAnimating,
            reduceMotion: configuration.reduceMotion,
            isInWindow: self.window != nil,
            barCount: self.barLayers.count,
            height: self.bounds.height
        )
        guard state != self.animationState else { return }
        self.animationState = state

        let isMoving = state.isAnimating && !state.reduceMotion && state.isInWindow
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in self.barLayers.enumerated() {
            let profile = BarProfile(index: index)
            bar.removeAnimation(forKey: Self.animationKey)
            let fraction: CGFloat = if !state.isAnimating {
                profile.restingFraction
            } else if state.reduceMotion {
                BarProfile.reducedMotionFraction
            } else {
                BarProfile.startFraction
            }
            bar.bounds.size.height = state.height * fraction

            guard isMoving else { continue }
            let animation = CABasicAnimation(keyPath: "bounds.size.height")
            animation.fromValue = state.height * BarProfile.startFraction
            animation.toValue = state.height * profile.peakFraction
            animation.duration = profile.duration
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.beginTime = bar.convertTime(CACurrentMediaTime(), from: nil) + profile.delay
            animation.fillMode = .backwards
            bar.add(animation, forKey: Self.animationKey)
        }
        CATransaction.commit()
    }
}

// MARK: - NowPlayingIndicator

/// A compact now-playing indicator that shows equalizer when playing, or a static icon when paused.
struct NowPlayingIndicator: View {
    var isPlaying: Bool
    var size: CGFloat = 16

    var body: some View {
        Group {
            if self.isPlaying {
                EqualizerView(
                    isAnimating: true,
                    barCount: 3,
                    spacing: 2,
                    barWidth: 3,
                    cornerRadius: 1.5,
                    color: .red
                )
            } else {
                Image(systemName: "speaker.fill")
                    .font(.system(size: self.size * 0.7))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: self.size, height: self.size)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 24) {
        // Playing state
        HStack(spacing: 24) {
            Text(String(localized: "Playing:"))
            EqualizerView(isAnimating: true)
                .frame(width: 20, height: 20)
        }

        // Paused state
        HStack(spacing: 24) {
            Text(String(localized: "Paused:"))
            EqualizerView(isAnimating: false)
                .frame(width: 20, height: 20)
        }

        // Now Playing Indicator
        HStack(spacing: 24) {
            NowPlayingIndicator(isPlaying: true)
            NowPlayingIndicator(isPlaying: false)
        }

        // Larger version
        EqualizerView(isAnimating: true, barCount: 5, spacing: 3, barWidth: 4)
            .frame(width: 40, height: 30)
    }
    .padding()
}
