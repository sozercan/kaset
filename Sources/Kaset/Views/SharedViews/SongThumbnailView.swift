import SwiftUI

/// Displays a song's thumbnail with automatic YouTube fallback.
/// If the API-provided thumbnail URL fails to load, falls back to
/// YouTube's public video thumbnail (`i.ytimg.com`).
@available(macOS 26.0, *)
struct SongThumbnailView: View {
    let song: Song
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 6

    @State private var useFallback = false

    /// The API-provided thumbnail URL.
    private var primaryURL: URL? {
        self.song.thumbnailURL?.highQualityThumbnailURL
    }

    /// YouTube's public video thumbnail as fallback.
    private var fallbackURL: URL? {
        self.song.fallbackThumbnailURL
    }

    /// The URL to display: primary first, fallback if it failed.
    private var activeURL: URL? {
        if self.useFallback {
            return self.fallbackURL
        }
        return self.primaryURL ?? self.fallbackURL
    }

    var body: some View {
        CachedAsyncImage(url: self.activeURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: self.size, height: self.size)
        .clipShape(.rect(cornerRadius: self.cornerRadius))
        .task(id: self.song.videoId) {
            self.useFallback = false

            // If there's a primary URL, check if it actually loads
            guard let primaryURL, primaryURL != self.fallbackURL else { return }

            let image = await ImageCache.shared.image(
                for: primaryURL,
                targetSize: CGSize(width: self.size * 2, height: self.size * 2)
            )
            if image == nil {
                self.useFallback = true
            }
        }
    }
}
