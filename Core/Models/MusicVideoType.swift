import Foundation

// MARK: - MusicVideoType

/// Represents the type of music video content from YouTube Music.
///
/// This enum maps to the `musicVideoType` field in the YouTube Music API's
/// `player` and `next` endpoint responses. It helps distinguish between
/// actual music videos (with video content) and audio-only tracks.
///
/// - Note: Only `.omv` (Official Music Video) should display the video toggle
///   button, as other types have either static images or no meaningful video.
enum MusicVideoType: String, Codable, Sendable {
    /// Official Music Video - Full video content from the artist/label.
    /// These have actual video content and should show the video toggle.
    case omv = "MUSIC_VIDEO_TYPE_OMV"

    /// Audio Track Video - Static image or visualizer (audio only).
    /// These do NOT have meaningful video content.
    case atv = "MUSIC_VIDEO_TYPE_ATV"

    /// User Generated Content - Fan-made or unofficial videos.
    case ugc = "MUSIC_VIDEO_TYPE_UGC"

    /// Podcast Episode - Audio podcast content.
    case podcastEpisode = "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"

    /// Whether this video type has actual video content worth showing.
    /// Only Official Music Videos have meaningful video.
    var hasVideoContent: Bool {
        self == .omv
    }

    /// Human-readable description of the video type.
    var displayName: String {
        switch self {
        case .omv: "Official Music Video"
        case .atv: "Audio Track"
        case .ugc: "User Generated"
        case .podcastEpisode: "Podcast Episode"
        }
    }
}
