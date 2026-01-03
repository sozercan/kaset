import Foundation

// MARK: - PodcastShow

/// Represents a podcast show from YouTube Music.
struct PodcastShow: Identifiable, Hashable, Sendable {
    let id: String // browseId (MPSPP...)
    let title: String
    let author: String?
    let description: String?
    let thumbnailURL: URL?
    let episodeCount: Int?

    /// Whether the show has a valid browse ID for navigation.
    /// Podcast show IDs start with "MPSPP" prefix.
    var hasNavigableId: Bool {
        self.id.hasPrefix("MPSPP")
    }
}

// MARK: - PodcastEpisode

/// Represents a podcast episode from YouTube Music.
struct PodcastEpisode: Identifiable, Hashable, Sendable {
    let id: String // videoId
    let title: String
    let showTitle: String? // secondTitle - the podcast show name
    let showBrowseId: String? // for navigation back to show
    let description: String?
    let thumbnailURL: URL?
    let publishedDate: String? // "3d ago", "Dec 28, 2025"
    let duration: String? // "36 min", "1:11:19"
    let durationSeconds: Int? // for progress calculation
    let playbackProgress: Double // 0.0-1.0
    let isPlayed: Bool
}

// MARK: - PodcastSection

/// Represents a section of podcast content on the discovery page.
struct PodcastSection: Identifiable, Sendable {
    let id: String
    let title: String
    let items: [PodcastSectionItem]
}

// MARK: - PodcastSectionItem

/// An item within a podcast section - either a show or an episode.
enum PodcastSectionItem: Sendable, Identifiable {
    case show(PodcastShow)
    case episode(PodcastEpisode)

    var id: String {
        switch self {
        case let .show(show):
            show.id
        case let .episode(episode):
            episode.id
        }
    }
}

// MARK: Hashable

extension PodcastSectionItem: Hashable {
    static func == (lhs: PodcastSectionItem, rhs: PodcastSectionItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
    }
}

// MARK: - PodcastShowDetail

/// Detailed information about a podcast show including its episodes.
struct PodcastShowDetail: Sendable {
    let show: PodcastShow
    let episodes: [PodcastEpisode]
    let continuationToken: String?

    var hasMore: Bool {
        self.continuationToken != nil
    }
}

// MARK: - PodcastEpisodesContinuation

/// Response from fetching more podcast episodes via continuation.
struct PodcastEpisodesContinuation: Sendable {
    let episodes: [PodcastEpisode]
    let continuationToken: String?

    var hasMore: Bool {
        self.continuationToken != nil
    }
}
