import SwiftUI

// MARK: - AnimationCache

/// Tracks which items have already been animated to avoid re-triggering on view reappear.
/// Uses a global set since @State resets when the view is recreated.
@MainActor
private enum AnimationCache {
    /// Set of item identifiers that have already been animated.
    /// Uses a weak reference pattern via object identifiers.
    static var animatedItems: Set<String> = []

    /// Maximum cache size before cleanup.
    private static let maxCacheSize = 500

    static func hasAnimated(_ id: String) -> Bool {
        self.animatedItems.contains(id)
    }

    static func markAnimated(_ id: String) {
        // Cleanup if cache gets too large (prevents unbounded growth)
        if self.animatedItems.count > self.maxCacheSize {
            self.animatedItems.removeAll()
        }
        self.animatedItems.insert(id)
    }

    /// Clears the animation cache. Call when navigating to a completely new context.
    static func reset() {
        self.animatedItems.removeAll()
    }
}

// MARK: - StaggeredAppearanceModifier

/// A view modifier that animates content appearance with a staggered delay.
/// Tracks already-animated items to avoid re-triggering animations on reappear.
@available(macOS 26.0, *)
struct StaggeredAppearanceModifier: ViewModifier {
    let index: Int
    let animation: Animation
    /// Unique identifier for this item (defaults to index-based).
    var itemId: String?

    @State private var isVisible = false
    @State private var hasCheckedCache = false

    private var delay: Double {
        AppAnimation.stagger(for: self.index)
    }

    /// The cache key for this item.
    private var cacheKey: String {
        self.itemId ?? "stagger-\(self.index)"
    }

    func body(content: Content) -> some View {
        content
            .opacity(self.isVisible ? 1 : 0)
            .offset(y: self.isVisible ? 0 : 20)
            .onAppear {
                // Skip animation if reduce motion is enabled
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                    self.isVisible = true
                    return
                }

                // Check if already animated (e.g., returning from detail view)
                if AnimationCache.hasAnimated(self.cacheKey) {
                    self.isVisible = true
                    return
                }

                // First-time appearance: animate and cache
                withAnimation(self.animation.delay(self.delay)) {
                    self.isVisible = true
                }
                AnimationCache.markAnimated(self.cacheKey)
            }
    }
}

@available(macOS 26.0, *)
extension View {
    /// Applies a staggered appearance animation based on item index.
    /// - Parameters:
    ///   - index: The index of this item in the list.
    ///   - animation: The animation to use (default: smooth).
    /// - Returns: A view with staggered appearance animation.
    func staggeredAppearance(
        index: Int,
        animation: Animation = AppAnimation.smooth
    ) -> some View {
        modifier(StaggeredAppearanceModifier(index: index, animation: animation))
    }
}

// MARK: - FadeInModifier

/// A view modifier for smooth fade-in transitions.
@available(macOS 26.0, *)
struct FadeInModifier: ViewModifier {
    @State private var opacity: Double = 0

    let duration: Double
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(self.opacity)
            .onAppear {
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                    self.opacity = 1
                    return
                }
                withAnimation(.easeIn(duration: self.duration).delay(self.delay)) {
                    self.opacity = 1
                }
            }
    }
}

@available(macOS 26.0, *)
extension View {
    /// Fades in the view when it appears.
    /// - Parameters:
    ///   - duration: The fade duration (default: 0.3).
    ///   - delay: Delay before starting the fade (default: 0).
    /// - Returns: A view with fade-in animation.
    func fadeIn(duration: Double = 0.3, delay: Double = 0) -> some View {
        modifier(FadeInModifier(duration: duration, delay: delay))
    }
}

// MARK: - PulseModifier

/// A view modifier that applies a pulsing scale animation.
/// Uses TimelineView for smooth, stutter-free continuous animation.
@available(macOS 26.0, *)
struct PulseModifier: ViewModifier {
    var minScale: CGFloat = 0.97
    var maxScale: CGFloat = 1.0
    var duration: Double = 1.0

    private var shouldAnimate: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func body(content: Content) -> some View {
        if self.shouldAnimate {
            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let phase = elapsed.truncatingRemainder(dividingBy: self.duration * 2)
                let progress = phase / (self.duration * 2)
                // Smooth sinusoidal oscillation between minScale and maxScale
                let scale = self.minScale + (self.maxScale - self.minScale) * (0.5 + 0.5 * sin(progress * 2 * .pi))
                content
                    .scaleEffect(scale)
            }
        } else {
            content
        }
    }
}

@available(macOS 26.0, *)
extension View {
    /// Applies a subtle pulsing animation.
    /// - Parameters:
    ///   - minScale: Minimum scale during pulse.
    ///   - maxScale: Maximum scale during pulse.
    ///   - duration: Duration of one pulse cycle.
    /// - Returns: A view with pulsing animation.
    func pulse(
        minScale: CGFloat = 0.97,
        maxScale: CGFloat = 1.0,
        duration: Double = 1.0
    ) -> some View {
        modifier(PulseModifier(minScale: minScale, maxScale: maxScale, duration: duration))
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview {
    VStack(spacing: 24) {
        // Staggered appearance
        VStack(alignment: .leading) {
            ForEach(0 ..< 3, id: \.self) { index in
                Text("Item \(index)")
                    .padding()
                    .background(.quaternary)
                    .clipShape(.rect(cornerRadius: 8))
                    .staggeredAppearance(index: index)
            }
        }

        // Pulse
        Circle()
            .fill(.blue)
            .frame(width: 50, height: 50)
            .pulse()
    }
    .padding()
}
