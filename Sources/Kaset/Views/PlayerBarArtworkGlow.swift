import AppKit
import SwiftUI

// MARK: - PlayerBarArtworkGlow

struct PlayerBarArtworkGlow: View {
    let sources: [URL]
    let identity: String?
    let targetSize: CGSize?
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    @State private var image: NSImage?
    @State private var isVisible = false

    var body: some View {
        Group {
            if self.reduceTransparency {
                Color.clear
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: self.width, height: self.height)
                    .clipShape(.rect(cornerRadius: self.cornerRadius, style: .continuous))
                    .compositingGroup()
                    .saturation(self.glowSaturation)
                    .brightness(self.glowBrightness)
                    .scaleEffect(self.glowScale)
                    .blur(radius: self.glowRadius)
                    .blendMode(self.glowBlendMode)
                    .opacity(self.isVisible ? self.glowOpacity : 0)
            } else {
                Color.clear
            }
        }
        .frame(width: self.width, height: self.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: self.loadKey) {
            await self.loadImage()
        }
    }

    private var loadKey: String {
        self.identity ?? "none"
    }

    private var glowOpacity: Double {
        self.colorScheme == .dark ? 0.40 : 0.50
    }

    private var glowRadius: CGFloat {
        min(max(self.width, self.height) * 0.18, 7)
    }

    private var glowScale: CGFloat {
        self.width > self.height ? 1.16 : 1.22
    }

    private var glowSaturation: Double {
        self.colorScheme == .dark ? 1.85 : 2.05
    }

    private var glowBrightness: Double {
        self.colorScheme == .dark ? 0 : 0.04
    }

    private var glowBlendMode: BlendMode {
        self.colorScheme == .dark ? .plusLighter : .multiply
    }

    @MainActor
    private func loadImage() async {
        let sources = self.sources

        await self.hideCurrentImage()

        guard !sources.isEmpty else {
            self.image = nil
            return
        }

        let loadedImage = await Self.loadFirstAvailableImage(from: sources, targetSize: self.targetSize)
        guard !Task.isCancelled else { return }

        self.image = loadedImage
        guard loadedImage != nil else { return }

        if self.reduceMotion {
            self.isVisible = true
        } else {
            withAnimation(.easeInOut(duration: 0.22)) {
                self.isVisible = true
            }
        }
    }

    @MainActor
    private func hideCurrentImage() async {
        guard self.image != nil else { return }

        if self.reduceMotion {
            self.isVisible = false
            return
        }

        withAnimation(.easeInOut(duration: 0.16)) {
            self.isVisible = false
        }

        try? await Task.sleep(nanoseconds: 160_000_000)
    }

    private static func loadFirstAvailableImage(from sources: [URL], targetSize: CGSize?) async -> NSImage? {
        for source in sources {
            if Task.isCancelled { return nil }
            if let image = await ImageCache.shared.image(for: source, targetSize: targetSize) {
                return image
            }
        }

        return nil
    }
}
