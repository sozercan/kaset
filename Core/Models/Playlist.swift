import Foundation

// MARK: - Playlist

/// Represents a playlist from YouTube Music.
struct Playlist: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let description: String?
    let thumbnailURL: URL?
    let trackCount: Int?
    let author: String?

    /// Display string for track count.
    var trackCountDisplay: String {
        guard let count = trackCount else { return "" }
        return count == 1 ? "1 song" : "\(count) songs"
    }
}

extension Playlist {
    /// Creates a Playlist from YouTube Music API response data.
    init?(from data: [String: Any]) {
        guard let playlistId = data["playlistId"] as? String ?? data["browseId"] as? String else {
            return nil
        }

        id = playlistId
        title = (data["title"] as? String) ?? "Unknown Playlist"
        description = data["description"] as? String

        // Parse thumbnail
        if let thumbnails = data["thumbnails"] as? [[String: Any]],
           let lastThumbnail = thumbnails.last,
           let urlString = lastThumbnail["url"] as? String
        {
            thumbnailURL = URL(string: urlString)
        } else {
            thumbnailURL = nil
        }

        // Parse track count
        if let count = data["trackCount"] as? Int {
            trackCount = count
        } else if let countString = data["trackCount"] as? String,
                  let count = Int(countString.replacingOccurrences(of: ",", with: ""))
        {
            trackCount = count
        } else {
            trackCount = nil
        }

        // Parse author
        if let authors = data["authors"] as? [[String: Any]],
           let firstAuthor = authors.first
        {
            author = firstAuthor["name"] as? String
        } else {
            author = data["author"] as? String
        }
    }
}

// MARK: - PlaylistDetail

/// Detailed playlist information including tracks.
struct PlaylistDetail: Identifiable, Sendable {
    let id: String
    let title: String
    let description: String?
    let thumbnailURL: URL?
    let author: String?
    let tracks: [Song]
    let duration: String?

    init(playlist: Playlist, tracks: [Song], duration: String? = nil) {
        id = playlist.id
        title = playlist.title
        description = playlist.description
        thumbnailURL = playlist.thumbnailURL
        author = playlist.author
        self.tracks = tracks
        self.duration = duration
    }
}
