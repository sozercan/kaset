import SwiftUI

// MARK: - ArtworkViewer

/// A full-screen sheet that displays album artwork at high resolution.
///
/// Shows the image centered with a dark background. The viewer can be dismissed
/// by tapping anywhere, pressing Escape, or clicking the close button in the top-right corner.
struct ArtworkViewer: View {
    /// The high-quality thumbnail URL to display.
    let artworkURL: URL?

    /// Called when the viewer should be dismissed.
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Dark background
            self.backgroundLayer
                .ignoresSafeArea()

            // Centered artwork
            if let url = self.artworkURL {
                CachedAsyncImage(url: url, targetSize: CGSize(width: 800, height: 800)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(60)
                .accessibilityLabel(Text(String(localized: "Album Artwork")))
            } else {
                Spacer()
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    // MARK: - Subviews

    private var backgroundLayer: some View {
        Color.black.opacity(0.85)
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
