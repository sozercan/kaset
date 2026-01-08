import SwiftUI

// MARK: - CachedAsyncImage

/// A cached version of AsyncImage that uses ImageCache.
/// Includes a smooth crossfade transition when the image loads.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    /// Target size for image downsampling. Images are downsampled to this size to reduce memory usage.
    /// Pass the actual display size of the image for optimal memory efficiency.
    var targetSize: CGSize = .init(width: 320, height: 320)
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: NSImage?
    @State private var isLoaded = false

    /// Whether to animate the image appearance.
    private var shouldAnimate: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        ZStack {
            if let image {
                self.content(Image(nsImage: image))
                    .opacity(self.isLoaded ? 1 : 0)
                    .animation(self.shouldAnimate ? .easeIn(duration: 0.25) : nil, value: self.isLoaded)
            } else {
                self.placeholder()
            }
        }
        .onChange(of: self.url) { _, _ in
            // Reset state when URL changes for proper UX
            self.image = nil
            self.isLoaded = false
        }
        .task(id: self.url) {
            guard let url else { return }
            let loadedImage = await ImageCache.shared.image(for: url, targetSize: self.targetSize)
            guard !Task.isCancelled else { return }
            self.image = loadedImage
            self.isLoaded = true
        }
    }
}

// MARK: - SizedProgressView

/// A simple ProgressView wrapper with proper sizing to avoid AppKit constraint warnings.
struct SizedProgressView: View {
    var body: some View {
        ProgressView()
            .controlSize(.regular)
            .frame(width: 20, height: 20)
    }
}

extension CachedAsyncImage where Placeholder == SizedProgressView {
    /// Convenience initializer with default ProgressView placeholder.
    init(url: URL?, @ViewBuilder content: @escaping (Image) -> Content) {
        self.url = url
        self.content = content
        self.placeholder = { SizedProgressView() }
    }
}
