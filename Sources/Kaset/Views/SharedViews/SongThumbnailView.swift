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
@available(macOS 26.0, *)
struct SongThumbnailView: View {
    let song: Song
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 6

    @State private var failedPrimaryKey: SongThumbnailSource.PrimaryFailureKey?

    /// The API-provided thumbnail URL.
    private var primaryURL: URL? {
        self.song.thumbnailURL?.highQualityThumbnailURL
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

    var body: some View {
        CachedAsyncImage(url: self.activeURL, onFailure: self.failureHandler) { image in
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
    }
}
