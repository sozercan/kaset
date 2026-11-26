import AppKit
import SwiftUI

struct EqualizerView: NSViewRepresentable {
    var isAnimating: Bool

    var barCount: Int = 3

    var spacing: CGFloat = 2

    var barWidth: CGFloat = 3

    var cornerRadius: CGFloat = 1.5

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

    struct BarProfile: Equatable {
        let delay: TimeInterval
        let duration: TimeInterval
        let restingFraction: CGFloat
        let peakFraction: CGFloat

        static let startFraction: CGFloat = 0.3

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
        self.needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.animationState = nil
        self.needsLayout = true
    }

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

#Preview {
    VStack(spacing: 24) {
        HStack(spacing: 24) {
            Text(String(localized: "Playing:"))
            EqualizerView(isAnimating: true)
                .frame(width: 20, height: 20)
        }

        HStack(spacing: 24) {
            Text(String(localized: "Paused:"))
            EqualizerView(isAnimating: false)
                .frame(width: 20, height: 20)
        }

        HStack(spacing: 24) {
            NowPlayingIndicator(isPlaying: true)
            NowPlayingIndicator(isPlaying: false)
        }

        EqualizerView(isAnimating: true, barCount: 5, spacing: 3, barWidth: 4)
            .frame(width: 40, height: 30)
    }
    .padding()
}
