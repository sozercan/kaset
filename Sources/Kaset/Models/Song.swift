import CoreTransferable
import Foundation

struct Song: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artists: [Artist]
    let album: Album?
    let duration: TimeInterval?
    let thumbnailURL: URL?
    let videoId: String
    let isPlayable: Bool

    var hasVideo: Bool?

    var musicVideoType: MusicVideoType?

    var likeStatus: LikeStatus?

    var isInLibrary: Bool?

    var feedbackTokens: FeedbackTokens?

    var isExplicit: Bool?

    var playlistSetVideoId: String?

    var audioTrackVideoId: String?

    var preferredAudioVideoId: String {
        self.audioTrackVideoId ?? self.videoId
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case artists
        case album
        case duration
        case thumbnailURL
        case videoId
        case isPlayable
        case hasVideo
        case musicVideoType
        case likeStatus
        case isInLibrary
        case feedbackTokens
        case isExplicit
        case playlistSetVideoId
        case audioTrackVideoId
    }

    init(
        id: String,
        title: String,
        artists: [Artist],
        album: Album? = nil,
        duration: TimeInterval? = nil,
        thumbnailURL: URL? = nil,
        videoId: String,
        isPlayable: Bool = true,
        hasVideo: Bool? = nil,
        musicVideoType: MusicVideoType? = nil,
        likeStatus: LikeStatus? = nil,
        isInLibrary: Bool? = nil,
        feedbackTokens: FeedbackTokens? = nil,
        isExplicit: Bool? = nil,
        playlistSetVideoId: String? = nil,
        audioTrackVideoId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.album = album
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.videoId = videoId
        self.isPlayable = isPlayable
        self.hasVideo = hasVideo
        self.musicVideoType = musicVideoType
        self.likeStatus = likeStatus
        self.isInLibrary = isInLibrary
        self.feedbackTokens = feedbackTokens
        self.isExplicit = isExplicit
        self.playlistSetVideoId = playlistSetVideoId
        self.audioTrackVideoId = audioTrackVideoId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.artists = try container.decode([Artist].self, forKey: .artists)
        self.album = try container.decodeIfPresent(Album.self, forKey: .album)
        self.duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        self.thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        self.videoId = try container.decode(String.self, forKey: .videoId)
        self.isPlayable = try container.decodeIfPresent(Bool.self, forKey: .isPlayable) ?? true
        self.hasVideo = try container.decodeIfPresent(Bool.self, forKey: .hasVideo)
        self.musicVideoType = try container.decodeIfPresent(MusicVideoType.self, forKey: .musicVideoType)
        self.likeStatus = try container.decodeIfPresent(LikeStatus.self, forKey: .likeStatus)
        self.isInLibrary = try container.decodeIfPresent(Bool.self, forKey: .isInLibrary)
        self.feedbackTokens = try container.decodeIfPresent(FeedbackTokens.self, forKey: .feedbackTokens)
        self.isExplicit = try container.decodeIfPresent(Bool.self, forKey: .isExplicit)
        self.playlistSetVideoId = try container.decodeIfPresent(String.self, forKey: .playlistSetVideoId)
        self.audioTrackVideoId = try container.decodeIfPresent(String.self, forKey: .audioTrackVideoId)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.artists, forKey: .artists)
        try container.encodeIfPresent(self.album, forKey: .album)
        try container.encodeIfPresent(self.duration, forKey: .duration)
        try container.encodeIfPresent(self.thumbnailURL, forKey: .thumbnailURL)
        try container.encode(self.videoId, forKey: .videoId)
        try container.encode(self.isPlayable, forKey: .isPlayable)
        try container.encodeIfPresent(self.hasVideo, forKey: .hasVideo)
        try container.encodeIfPresent(self.musicVideoType, forKey: .musicVideoType)
        try container.encodeIfPresent(self.likeStatus, forKey: .likeStatus)
        try container.encodeIfPresent(self.isInLibrary, forKey: .isInLibrary)
        try container.encodeIfPresent(self.feedbackTokens, forKey: .feedbackTokens)
        try container.encodeIfPresent(self.isExplicit, forKey: .isExplicit)
        try container.encodeIfPresent(self.playlistSetVideoId, forKey: .playlistSetVideoId)
        try container.encodeIfPresent(self.audioTrackVideoId, forKey: .audioTrackVideoId)
    }

    func replacingDisplayMetadata(title: String, artists: [Artist], thumbnailURL: URL?) -> Song {
        Song(
            id: self.id,
            title: title,
            artists: artists,
            album: self.album,
            duration: self.duration,
            thumbnailURL: thumbnailURL,
            videoId: self.videoId,
            isPlayable: self.isPlayable,
            hasVideo: self.hasVideo,
            musicVideoType: self.musicVideoType,
            likeStatus: self.likeStatus,
            isInLibrary: self.isInLibrary,
            feedbackTokens: self.feedbackTokens,
            isExplicit: self.isExplicit,
            playlistSetVideoId: self.playlistSetVideoId,
            audioTrackVideoId: self.audioTrackVideoId
        )
    }

    static func placeholder(videoId: String) -> Song {
        Song(
            id: videoId,
            title: "Loading...",
            artists: [],
            videoId: videoId
        )
    }

    var artistsDisplay: String {
        self.artists.map(\.name).joined(separator: ", ")
    }

    var durationDisplay: String {
        guard let duration else { return "--:--" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var fallbackThumbnailURL: URL? {
        URL(string: "https://i.ytimg.com/vi/\(self.videoId)/hqdefault.jpg")
    }

    var wideHighQualityThumbnailURL: URL? {
        var components = URLComponents(string: "https://i.ytimg.com/vi/\(self.videoId)/hq720.jpg")
        components?.queryItems = [URLQueryItem(name: "kaset", value: "wide-v2")]
        return components?.url
    }
}

extension Song {
    init?(from data: [String: Any]) {
        guard let videoId = data["videoId"] as? String else { return nil }

        self.id = videoId
        self.videoId = videoId
        self.title = (data["title"] as? String) ?? "Unknown Title"

        if let artistsData = data["artists"] as? [[String: Any]] {
            self.artists = artistsData.compactMap { Artist(from: $0) }
        } else {
            self.artists = []
        }

        if let albumData = data["album"] as? [String: Any] {
            self.album = Album(from: albumData)
        } else {
            self.album = nil
        }

        if let durationSeconds = data["duration_seconds"] as? Double {
            self.duration = durationSeconds
        } else if let durationString = data["duration"] as? String {
            self.duration = Song.parseDuration(durationString)
        } else {
            self.duration = nil
        }

        if let thumbnails = data["thumbnails"] as? [[String: Any]],
           let lastThumbnail = thumbnails.last,
           let urlString = lastThumbnail["url"] as? String
        {
            self.thumbnailURL = URL(string: urlString)
        } else {
            self.thumbnailURL = nil
        }

        self.isPlayable = true
        self.isExplicit = ParsingHelpers.extractIsExplicit(from: data)
    }

    private static func parseDuration(_ string: String) -> TimeInterval? {
        let components = string.split(separator: ":").compactMap { Int($0) }
        guard components.count >= 2 else { return nil }

        if components.count == 2 {
            return TimeInterval(components[0] * 60 + components[1])
        } else if components.count == 3 {
            return TimeInterval(components[0] * 3600 + components[1] * 60 + components[2])
        }
        return nil
    }
}

extension Song {
    static func == (lhs: Song, rhs: Song) -> Bool {
        lhs.videoId == rhs.videoId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.videoId)
    }
}

extension Song: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(for: Song.self, contentType: .data)
    }
}
