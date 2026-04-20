import Foundation

// MARK: - ArtistEpisode

/// A video-backed item from an artist page's "Latest episodes" shelf.
///
/// These are channel uploads — often live radio streams for channel-style
/// artists like Lofi Girl — not formal podcast episodes (`PodcastEpisode`).
/// Playback is via `videoId` through the standard WebView path; live items
/// have no duration and should bypass queue/seek/scrobble behavior.
struct ArtistEpisode: Identifiable, Hashable {
    /// Stable identifier (mirrors `videoId`).
    let id: String
    /// Video ID used for playback via the singleton WebView.
    let videoId: String
    let title: String
    /// Typically a relative date like "5d ago" or a short date like "Apr 9".
    let subtitle: String?
    /// Long-form description shown under the title.
    let description: String?
    let thumbnailURL: URL?
    /// `true` when the shelf item carries a `liveBadgeRenderer`.
    let isLive: Bool

    init(
        videoId: String,
        title: String,
        subtitle: String? = nil,
        description: String? = nil,
        thumbnailURL: URL? = nil,
        isLive: Bool = false
    ) {
        self.id = videoId
        self.videoId = videoId
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.thumbnailURL = thumbnailURL
        self.isLive = isLive
    }
}
