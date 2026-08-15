import SwiftUI

// MARK: - ArtworkViewerSource

/// Resolves which artwork URL the viewer should display.
///
/// The API-provided artwork is preferred, falling back to YouTube's public video
/// thumbnail when that source fails, mirroring `SongThumbnailView`.
struct ArtworkViewerSource: Equatable {
    let primaryURL: URL?
    let fallbackURL: URL?

    var hasArtwork: Bool {
        self.primaryURL != nil || self.fallbackURL != nil
    }

    /// The distinct fallback, if the primary is worth retrying past.
    var retryableFallbackURL: URL? {
        guard let fallbackURL, fallbackURL != self.primaryURL else { return nil }
        return fallbackURL
    }

    func activeURL(didFailPrimary: Bool) -> URL? {
        if didFailPrimary, let retryableFallbackURL {
            return retryableFallbackURL
        }
        return self.primaryURL ?? self.fallbackURL
    }
}

// MARK: - ArtworkViewer

/// A sheet that displays album artwork at high resolution.
///
/// Shows the image centered with a dark background. The viewer can be dismissed
/// by tapping anywhere, pressing Escape, or clicking the close button in the top-right corner.
struct ArtworkViewer: View {
    /// Album artwork is square, so the viewer is square too. Scaled against the active
    /// screen so it stays generous on large displays without overflowing small ones.
    private static var viewerSide: CGFloat {
        guard let visibleFrame = NSScreen.main?.visibleFrame else { return 560 }
        let side = min(visibleFrame.width, visibleFrame.height) * 0.62
        return min(700, max(380, side.rounded()))
    }

    /// Source artwork is requested well above the display size so the image stays crisp
    /// on Retina displays; hosts cap the response at the original resolution.
    private static let requestedArtworkPixels = 1200

    /// The high-quality thumbnail URL to display.
    let artworkURL: URL?

    /// Public video thumbnail used when `artworkURL` fails to load.
    var fallbackArtworkURL: URL?

    /// Called when the viewer should be dismissed.
    let onDismiss: () -> Void

    @State private var didFailPrimary = false
    @State private var didFailArtwork = false

    private var source: ArtworkViewerSource {
        ArtworkViewerSource(primaryURL: self.artworkURL, fallbackURL: self.fallbackArtworkURL)
    }

    /// The chosen source before any size upgrade; failure handling is keyed on this.
    private var activeSourceURL: URL? {
        self.source.activeURL(didFailPrimary: self.didFailPrimary)
    }

    private func displayURL(for sourceURL: URL) -> URL {
        sourceURL.artworkURL(side: Self.requestedArtworkPixels) ?? sourceURL
    }

    var body: some View {
        ZStack {
            self.backgroundLayer

            if let sourceURL = self.activeSourceURL, !self.didFailArtwork {
                CachedAsyncImage(
                    url: self.displayURL(for: sourceURL),
                    targetSize: CGSize(width: Self.viewerSide, height: Self.viewerSide),
                    onFailure: { self.handleFailure(of: sourceURL) },
                    content: { image in
                        image
                            .resizable()
                            .scaledToFit()
                    }
                )
                .id(sourceURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
                .accessibilityLabel(Text(String(localized: "Album Artwork")))
            } else {
                self.unavailableArtwork
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            self.onDismiss()
        }
        .overlay(alignment: .topTrailing) {
            self.closeButton
                .padding(20)
        }
        .frame(width: Self.viewerSide, height: Self.viewerSide)
        .background(Color.black)
    }

    // MARK: - Actions

    private func handleFailure(of url: URL) {
        if url == self.source.primaryURL, self.source.retryableFallbackURL != nil {
            self.didFailPrimary = true
            return
        }
        self.didFailArtwork = true
    }

    // MARK: - Subviews

    private var backgroundLayer: some View {
        Color.black.opacity(0.85)
    }

    private var unavailableArtwork: some View {
        ContentUnavailableView {
            Label(String(localized: "Artwork Unavailable"), systemImage: "photo")
        } description: {
            Text(String(localized: "This track has no artwork available."))
        }
        .foregroundStyle(.white.opacity(0.7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var closeButton: some View {
        Button {
            self.onDismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "Close")))
    }
}
