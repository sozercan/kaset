import SwiftUI

private struct CachedAsyncImageRequest: Equatable {
    let url: URL?
    let targetSize: CGSize
}

private struct CachedAsyncImageTaskID: Equatable {
    let request: CachedAsyncImageRequest
    let isMemoryHit: Bool
}

struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    var targetSize: CGSize = .init(width: 320, height: 320)
    var onFailure: (@MainActor () -> Void)?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var image: NSImage?
    @State private var isLoaded = false

    private var request: CachedAsyncImageRequest {
        CachedAsyncImageRequest(url: self.url, targetSize: self.targetSize)
    }

    private var shouldAnimate: Bool {
        !self.accessibilityReduceMotion
    }

    private var memoryCachedImage: NSImage? {
        guard self.image == nil, let url = self.url else { return nil }
        return ImageCache.shared.cachedImage(for: url, targetSize: self.targetSize)
    }

    var body: some View {
        let cached = self.memoryCachedImage
        let isMemoryHit = cached != nil
        ZStack {
            if let image = self.image ?? cached {
                self.content(Image(nsImage: image))
                    .opacity(self.isLoaded || isMemoryHit ? 1 : 0)
                    .animation(self.shouldAnimate ? .easeIn(duration: 0.25) : nil, value: self.isLoaded)
            } else {
                self.placeholder()
            }
        }
        .onChange(of: self.request) { _, _ in
            self.image = nil
            self.isLoaded = false
        }
        .task(id: CachedAsyncImageTaskID(request: self.request, isMemoryHit: isMemoryHit)) {
            let request = self.request
            guard !isMemoryHit, let url = request.url else { return }
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

struct SizedProgressView: View {
    var body: some View {
        ProgressView()
            .controlSize(.regular)
            .frame(width: 20, height: 20)
    }
}

extension CachedAsyncImage where Placeholder == SizedProgressView {
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
