import Foundation

struct PodcastShow: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let author: String?
    let description: String?
    let thumbnailURL: URL?
    let episodeCount: Int?

    var hasNavigableId: Bool {
        self.id.hasPrefix("MPSPP")
    }
}

struct PodcastEpisode: Identifiable, Hashable {
    let id: String
    let title: String
    let showTitle: String?
    let showBrowseId: String?
    let description: String?
    let thumbnailURL: URL?
    let publishedDate: String?
    let duration: String?
    let durationSeconds: Int?
    let playbackProgress: Double
    let isPlayed: Bool

    var formattedDuration: String? {
        if let seconds = durationSeconds {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            let secs = seconds % 60
            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, minutes, secs)
            } else {
                return String(format: "%d:%02d", minutes, secs)
            }
        }
        return self.duration
    }

    var playbackSong: Song {
        Song(
            id: self.id,
            title: self.title,
            artists: self.showTitle.map {
                [Artist.inline(name: $0, namespace: "podcast-show")]
            } ?? [],
            album: nil,
            duration: self.durationSeconds.map(TimeInterval.init),
            thumbnailURL: self.thumbnailURL,
            videoId: self.id,
            musicVideoType: .podcastEpisode
        )
    }
}

struct PodcastSection: Identifiable {
    let id: String
    let title: String
    let items: [PodcastSectionItem]
}

enum PodcastSectionItem: Identifiable {
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

extension PodcastSectionItem: Hashable {
    static func == (lhs: PodcastSectionItem, rhs: PodcastSectionItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
    }
}

struct PodcastShowDetail {
    let show: PodcastShow
    let episodes: [PodcastEpisode]
    let continuationToken: String?
    let isSubscribed: Bool

    var hasMore: Bool {
        self.continuationToken != nil
    }
}

struct PodcastEpisodesContinuation {
    let episodes: [PodcastEpisode]
    let continuationToken: String?

    var hasMore: Bool {
        self.continuationToken != nil
    }
}
