import Foundation

enum MusicVideoType: String, Codable {
    case omv = "MUSIC_VIDEO_TYPE_OMV"

    case atv = "MUSIC_VIDEO_TYPE_ATV"

    case ugc = "MUSIC_VIDEO_TYPE_UGC"

    case officialSourceMusic = "MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC"

    case podcastEpisode = "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"

    var hasVideoContent: Bool {
        self == .omv
    }

    var isSearchVideo: Bool {
        switch self {
        case .omv, .ugc, .officialSourceMusic:
            true
        case .atv, .podcastEpisode:
            false
        }
    }

    var displayName: String {
        switch self {
        case .omv: "Official Music Video"
        case .atv: "Audio Track"
        case .ugc: "User Generated"
        case .officialSourceMusic: "Official Source Music"
        case .podcastEpisode: "Podcast Episode"
        }
    }
}
