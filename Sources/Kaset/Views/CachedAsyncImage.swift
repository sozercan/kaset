import SwiftUI

// MARK: - CachedAsyncImageRequest

private struct CachedAsyncImageRequest: Equatable {
    let url: URL?
    let targetSize: CGSize
}

// MARK: - CachedAsyncImage

/// A cached version of AsyncImage that uses ImageCache.
/// Includes a smooth crossfade transition when the image loads.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    /// Target size for image downsampling. Images are downsampled to this size to reduce memory usage.
    /// Pass the actual display size of the image for optimal memory efficiency.
    var targetSize: CGSize = .init(width: 320, height: 320)
    /// Optional callback invoked when an image load fails.
    var onFailure: (@MainActor () -> Void)?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var image: NSImage?
    @State private var isLoaded = false

    private var request: CachedAsyncImageRequest {
        CachedAsyncImageRequest(url: self.url, targetSize: self.targetSize)
    }

    /// Whether to animate the image appearance.
    private var shouldAnimate: Bool {
        !self.accessibilityReduceMotion
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
        .onChange(of: self.request) { _, _ in
            // Reset state when the underlying request changes for proper UX.
            // Include targetSize so a reused view does not keep a stale decode.
            self.image = nil
            self.isLoaded = false
        }
        .task(id: self.request) {
            let request = self.request
            guard let url = request.url else { return }
            let loadedImage = await ImageCache.shared.image(for: url, targetSize: request.targetSize)
            guard !Task.isCancelled, self.request == request else { return }

            guard let loadedImage else {
                self.image = nil
                self.isLoaded = false
                self.onFailure?()
                return
            }

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
    init(
        url: URL?,
        targetSize: CGSize = .init(width: 320, height: 320),
        onFailure: (@MainActor () -> Void)? = nil,
        @ViewBuilder content: @escaping (Image) -> Content
    ) {
        self.url = url
        self.targetSize = targetSize
        self.onFailure = onFailure
        self.content = content
        self.placeholder = { SizedProgressView() }
    }
}
