import SwiftUI

@MainActor
private enum AnimationCache {
    static var animatedItems: Set<String> = []

    private static let maxCacheSize = 500

    static func hasAnimated(_ id: String) -> Bool {
        self.animatedItems.contains(id)
    }

    static func markAnimated(_ id: String) {
        if self.animatedItems.count > self.maxCacheSize {
            self.animatedItems.removeAll()
        }
        self.animatedItems.insert(id)
    }

    static func reset() {
        self.animatedItems.removeAll()
    }
}

struct StaggeredAppearanceModifier: ViewModifier {
    let index: Int
    let animation: Animation
    var itemId: String?

    @State private var isVisible = false
    @State private var hasCheckedCache = false

    private var delay: Double {
        AppAnimation.stagger(for: self.index)
    }

    private var cacheKey: String {
        self.itemId ?? "stagger-\(self.index)"
    }

    func body(content: Content) -> some View {
        content
            .opacity(self.isVisible ? 1 : 0)
            .offset(y: self.isVisible ? 0 : 20)
            .onAppear {
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                    self.isVisible = true
                    return
                }

                if AnimationCache.hasAnimated(self.cacheKey) {
                    self.isVisible = true
                    return
                }

                withAnimation(self.animation.delay(self.delay)) {
                    self.isVisible = true
                }
                AnimationCache.markAnimated(self.cacheKey)
            }
    }
}

extension View {
    func staggeredAppearance(
        index: Int,
        animation: Animation = AppAnimation.smooth
    ) -> some View {
        modifier(StaggeredAppearanceModifier(index: index, animation: animation))
    }
}

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

extension View {
    func fadeIn(duration: Double = 0.3, delay: Double = 0) -> some View {
        modifier(FadeInModifier(duration: duration, delay: delay))
    }
}

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
                let scale = self.minScale + (self.maxScale - self.minScale) * (0.5 + 0.5 * sin(progress * 2 * .pi))
                content
                    .scaleEffect(scale)
            }
        } else {
            content
        }
    }
}

extension View {
    func pulse(
        minScale: CGFloat = 0.97,
        maxScale: CGFloat = 1.0,
        duration: Double = 1.0
    ) -> some View {
        modifier(PulseModifier(minScale: minScale, maxScale: maxScale, duration: duration))
    }
}

#Preview {
    VStack(spacing: 24) {
        VStack(alignment: .leading) {
            ForEach(0 ..< 3, id: \.self) { index in
                Text("Item \(index)")
                    .padding()
                    .background(.quaternary)
                    .clipShape(.rect(cornerRadius: 8))
                    .staggeredAppearance(index: index)
            }
        }

        Circle()
            .fill(.blue)
            .frame(width: 50, height: 50)
            .pulse()
    }
    .padding()
}
