import SwiftUI

// MARK: - SongThumbnailSource

struct SongThumbnailSource: Equatable {
    struct PrimaryFailureKey: Equatable {
        let videoId: String
        let url: URL
    }

    let videoId: String
    let primaryURL: URL?
    let fallbackURL: URL?

    var primaryFailureKey: PrimaryFailureKey? {
        guard let primaryURL, let fallbackURL, primaryURL != fallbackURL else { return nil }
        return PrimaryFailureKey(videoId: self.videoId, url: primaryURL)
    }

    func activeURL(failedPrimaryKey: PrimaryFailureKey?) -> URL? {
        if failedPrimaryKey == self.primaryFailureKey {
            return self.fallbackURL
        }
        return self.primaryURL ?? self.fallbackURL
    }
}

// MARK: - SongThumbnailView

/// Displays a song's thumbnail with automatic YouTube fallback.
/// If the API-provided thumbnail URL fails to load, falls back to
/// YouTube's public video thumbnail (`i.ytimg.com`).
struct SongThumbnailView: View {
    let song: Song
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 6

    @State private var failedPrimaryKey: SongThumbnailSource.PrimaryFailureKey?

    /// Above this size the 226 px `highQualityThumbnailURL` is visibly soft on a Retina display.
    private static let sharpArtworkMinimumSize: CGFloat = 113

    /// Covers the largest artwork the app draws (560 pt at 2x).
    private static let sharpArtworkPixelSize = 1200

    /// The API-provided thumbnail URL at the size every list and bar uses.
    private var standardURL: URL? {
        self.song.thumbnailURL?.highQualityThumbnailURL
    }

    /// The API-provided thumbnail URL, at full resolution when the artwork is drawn large.
    private var primaryURL: URL? {
        guard self.size > Self.sharpArtworkMinimumSize else { return self.standardURL }
        return self.song.thumbnailURL?.artworkURL(pixelSize: Self.sharpArtworkPixelSize)
    }

    /// The standard thumbnail, shown under large artwork while its sharper version loads:
    /// it is usually cached already, so the artwork never drops back to the placeholder.
    private var underlayURL: URL? {
        guard let standardURL = self.standardURL, standardURL != self.activeURL else { return nil }
        return standardURL
    }

    /// YouTube's public video thumbnail as fallback.
    private var fallbackURL: URL? {
        self.song.fallbackThumbnailURL
    }

    private var thumbnailSource: SongThumbnailSource {
        SongThumbnailSource(
            videoId: self.song.videoId,
            primaryURL: self.primaryURL,
            fallbackURL: self.fallbackURL
        )
    }

    /// The URL to display: primary first, fallback only if that exact primary source failed.
    private var activeURL: URL? {
        self.thumbnailSource.activeURL(failedPrimaryKey: self.failedPrimaryKey)
    }

    private var failureHandler: (@MainActor () -> Void)? {
        let source = self.thumbnailSource

        guard self.activeURL == source.primaryURL,
              let primaryFailureKey = source.primaryFailureKey
        else {
            return nil
        }

        return {
            self.failedPrimaryKey = primaryFailureKey
        }
    }

    private var targetSize: CGSize {
        let dimension = max(self.size, 1)
        return CGSize(width: dimension, height: dimension)
    }

    var body: some View {
        ZStack {
            if let underlayURL = self.underlayURL {
                CachedAsyncImage(url: underlayURL, targetSize: self.targetSize) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    self.placeholder
                }
            }

            CachedAsyncImage(url: self.activeURL, targetSize: self.targetSize, onFailure: self.failureHandler) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                if self.underlayURL == nil {
                    self.placeholder
                }
            }
        }
        .frame(width: self.size, height: self.size)
        .clipShape(.rect(cornerRadius: self.cornerRadius))
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            }
    }
}
