import Foundation

// MARK: - Song

/// Represents a song/track from YouTube Music.
struct Song: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let artists: [Artist]
    let album: Album?
    let duration: TimeInterval?
    let thumbnailURL: URL?
    let videoId: String

    /// Display string for artists (comma-separated).
    var artistsDisplay: String {
        artists.map(\.name).joined(separator: ", ")
    }

    /// Formatted duration string (e.g., "3:45").
    var durationDisplay: String {
        guard let duration else { return "--:--" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension Song {
    /// Creates a Song from YouTube Music API response data.
    init?(from data: [String: Any]) {
        guard let videoId = data["videoId"] as? String else { return nil }

        id = videoId
        self.videoId = videoId
        title = (data["title"] as? String) ?? "Unknown Title"

        // Parse artists
        if let artistsData = data["artists"] as? [[String: Any]] {
            artists = artistsData.compactMap { Artist(from: $0) }
        } else {
            artists = []
        }

        // Parse album
        if let albumData = data["album"] as? [String: Any] {
            album = Album(from: albumData)
        } else {
            album = nil
        }

        // Parse duration (in seconds)
        if let durationSeconds = data["duration_seconds"] as? Double {
            duration = durationSeconds
        } else if let durationString = data["duration"] as? String {
            duration = Song.parseDuration(durationString)
        } else {
            duration = nil
        }

        // Parse thumbnail
        if let thumbnails = data["thumbnails"] as? [[String: Any]],
           let lastThumbnail = thumbnails.last,
           let urlString = lastThumbnail["url"] as? String
        {
            thumbnailURL = URL(string: urlString)
        } else {
            thumbnailURL = nil
        }
    }

    /// Parses duration string like "3:45" to TimeInterval.
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
