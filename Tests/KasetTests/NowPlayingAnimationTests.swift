import AppKit
import Testing
@testable import Kaset

// MARK: - NowPlayingAnimationTests

/// The equalizer and the player bar marquee animate with Core Animation, so the
/// render server drives their frames; these tests pin the animation setup.
@Suite(.tags(.model))
@MainActor
struct NowPlayingAnimationTests {
    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private static func equalizerConfiguration(
        isAnimating: Bool = true,
        reduceMotion: Bool = false
    ) -> EqualizerBarsView.Configuration {
        EqualizerBarsView.Configuration(
            isAnimating: isAnimating,
            reduceMotion: reduceMotion,
            barCount: 3,
            spacing: 2,
            barWidth: 3,
            cornerRadius: 1.5,
            color: .systemRed
        )
    }

    private static func marqueeConfiguration(text: String, reduceMotion: Bool = false) -> PlayerBarMarqueeView.Configuration {
        PlayerBarMarqueeView.Configuration(
            text: text,
            font: .systemFont(ofSize: 13),
            color: .labelColor,
            reduceMotion: reduceMotion,
            isRightToLeft: false
        )
    }

    // MARK: Equalizer

    @Test("Playing bars repeat in Core Animation while in a window")
    func equalizerAnimatesInWindow() {
        let window = Self.makeWindow()
        defer { window.close() }
        let view = EqualizerBarsView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        view.configure(Self.equalizerConfiguration())
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()

        #expect(view.barLayers.count == 3)
        for bar in view.barLayers {
            let animation = bar.animation(forKey: EqualizerBarsView.animationKey) as? CABasicAnimation
            #expect(animation?.keyPath == "bounds.size.height")
            #expect(animation?.repeatCount == .infinity)
            #expect(animation?.autoreverses == true)
        }
    }

    @Test("Bars hold still off-window, under Reduce Motion, and when stopped")
    func equalizerHoldsStill() {
        let detached = EqualizerBarsView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        detached.configure(Self.equalizerConfiguration())
        detached.layoutSubtreeIfNeeded()
        #expect(detached.barLayers.allSatisfy { $0.animationKeys() == nil })

        let window = Self.makeWindow()
        defer { window.close() }
        let reduced = EqualizerBarsView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        reduced.configure(Self.equalizerConfiguration(reduceMotion: true))
        window.contentView?.addSubview(reduced)
        reduced.layoutSubtreeIfNeeded()
        #expect(reduced.barLayers.allSatisfy { $0.animationKeys() == nil })
        #expect(reduced.barLayers.allSatisfy { $0.bounds.height == 14 * EqualizerBarsView.BarProfile.reducedMotionFraction })

        let stopped = EqualizerBarsView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        stopped.configure(Self.equalizerConfiguration(isAnimating: false))
        window.contentView?.addSubview(stopped)
        stopped.layoutSubtreeIfNeeded()
        #expect(stopped.barLayers.allSatisfy { $0.animationKeys() == nil })
        let resting = stopped.barLayers.indices.map { 14 * EqualizerBarsView.BarProfile(index: $0).restingFraction }
        #expect(stopped.barLayers.map(\.bounds.height) == resting)
    }

    @Test("Equalizer never takes clicks from the row underneath")
    func equalizerIsTransparentToClicks() {
        let view = EqualizerBarsView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        #expect(view.hitTest(NSPoint(x: 7, y: 7)) == nil)
    }

    // MARK: Marquee cycle

    @Test("Titles that fit, or Reduce Motion, never scroll")
    func marqueeCycleOnlyForOverflow() {
        #expect(PlayerBarMarqueeCycle(textWidth: 100, containerWidth: 110, reduceMotion: false) == nil)
        #expect(PlayerBarMarqueeCycle(textWidth: 110.5, containerWidth: 110, reduceMotion: false) == nil)
        #expect(PlayerBarMarqueeCycle(textWidth: 200, containerWidth: 0, reduceMotion: false) == nil)
        #expect(PlayerBarMarqueeCycle(textWidth: 200, containerWidth: 110, reduceMotion: true) == nil)
        #expect(PlayerBarMarqueeCycle(textWidth: 200, containerWidth: 110, reduceMotion: false) != nil)
    }

    @Test("One cycle rests, scrolls one copy at 18 pt/s, then resets")
    func marqueeCycleTimeline() throws {
        let cycle = try #require(PlayerBarMarqueeCycle(textWidth: 200, containerWidth: 110, reduceMotion: false))
        #expect(cycle.travel == 224)
        #expect(abs(cycle.scrollDuration - 224.0 / 18) < 0.0001)
        #expect(abs(cycle.period - (1.4 + 224.0 / 18)) < 0.0001)

        let offsets = cycle.offsetKeyframes
        #expect(offsets.map(\.value) == [0, 0, 224, 0, 0])
        #expect(offsets.first?.time == 0)
        #expect(offsets.last?.time == cycle.period)
        #expect(abs(offsets[1].time - 1.2) < 0.0001)
        // Scrolling ends one reset fade before the period does, and jumps back at once.
        #expect(abs(offsets[2].time - (cycle.period - PlayerBarMarqueeCycle.resetFadeDuration)) < 0.0001)
        #expect(offsets[2].time == offsets[3].time)

        let fades = cycle.fadeKeyframes
        #expect(fades.map(\.value) == [.inactive, .inactive, .bothEdges, .bothEdges, .trailingOnly, .trailingOnly, .inactive])
        #expect(fades.last?.time == cycle.period)
        for keyframes in [offsets.map(\.time), fades.map(\.time)] {
            #expect(zip(keyframes, keyframes.dropFirst()).allSatisfy { $0 <= $1 })
        }
    }

    // MARK: Marquee view

    @Test("Overflowing titles scroll in Core Animation; fitting titles stay put")
    func marqueeViewAnimatesOnlyOverflow() throws {
        let window = Self.makeWindow()
        defer { window.close() }
        let view = PlayerBarMarqueeView(frame: NSRect(x: 0, y: 0, width: 110, height: 13))
        window.contentView?.addSubview(view)

        view.configure(Self.marqueeConfiguration(text: "A title that is much too long for the player bar"))
        view.layoutSubtreeIfNeeded()
        let period = try #require(view.cycle?.period)
        let scroll = view.layer?.sublayers?.first?.animation(forKey: PlayerBarMarqueeView.scrollAnimationKey)
        #expect(scroll?.duration == period)
        #expect(scroll?.repeatCount == .infinity)
        // The fade tracks leave `duration` at 0; adding the group gives them its duration,
        // so they span the whole cycle rather than the 0.25 s animation default.
        let fade = try #require(view.layer?.mask?.animation(forKey: PlayerBarMarqueeView.fadeAnimationKey) as? CAAnimationGroup)
        #expect(fade.duration == period)
        #expect(fade.repeatCount == .infinity)
        #expect(fade.animations?.count == 2)
        #expect(fade.animations?.allSatisfy { $0.duration == period } == true)

        view.configure(Self.marqueeConfiguration(text: "Short"))
        view.layoutSubtreeIfNeeded()
        #expect(view.cycle == nil)
        #expect(view.layer?.sublayers?.first?.animationKeys() == nil)
        #expect(view.layer?.mask?.animationKeys() == nil)

        view.configure(Self.marqueeConfiguration(text: "A title that is much too long for the player bar", reduceMotion: true))
        view.layoutSubtreeIfNeeded()
        #expect(view.cycle == nil)
        #expect(view.layer?.sublayers?.first?.animationKeys() == nil)
    }

    @Test("Marquee never takes clicks or the context menu from the player bar")
    func marqueeIsTransparentToClicks() {
        let view = PlayerBarMarqueeView(frame: NSRect(x: 0, y: 0, width: 110, height: 13))
        #expect(view.hitTest(NSPoint(x: 10, y: 5)) == nil)
    }
}
