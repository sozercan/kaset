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

    /// Whether this is an album (vs a playlist).
    /// Albums have IDs starting with "OLAK" or "MPRE".
    var isAlbum: Bool {
        self.id.hasPrefix("OLAK") || self.id.hasPrefix("MPRE")
    }

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

        self.id = playlistId
        self.title = (data["title"] as? String) ?? "Unknown Playlist"
        self.description = data["description"] as? String

        // Parse thumbnail
        if let thumbnails = data["thumbnails"] as? [[String: Any]],
           let lastThumbnail = thumbnails.last,
           let urlString = lastThumbnail["url"] as? String
        {
            self.thumbnailURL = URL(string: urlString)
        } else {
            self.thumbnailURL = nil
        }

        // Parse track count
        if let count = data["trackCount"] as? Int {
            self.trackCount = count
        } else if let countString = data["trackCount"] as? String,
                  let count = Int(countString.replacingOccurrences(of: ",", with: ""))
        {
            self.trackCount = count
        } else {
            self.trackCount = nil
        }

        // Parse author
        if let authors = data["authors"] as? [[String: Any]],
           let firstAuthor = authors.first
        {
            self.author = firstAuthor["name"] as? String
        } else {
            self.author = data["author"] as? String
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

    /// Whether this is an album (vs a playlist).
    /// Albums have IDs starting with "OLAK" or "MPRE".
    var isAlbum: Bool {
        self.id.hasPrefix("OLAK") || self.id.hasPrefix("MPRE")
    }

    init(playlist: Playlist, tracks: [Song], duration: String? = nil) {
        self.id = playlist.id
        self.title = playlist.title
        self.description = playlist.description
        self.thumbnailURL = playlist.thumbnailURL
        self.author = playlist.author
        self.tracks = tracks
        self.duration = duration
    }
}

// MARK: - LikedSongsResponse

/// Response from the liked songs API, including pagination support.
struct LikedSongsResponse: Sendable {
    /// The liked songs returned in this response.
    let songs: [Song]

    /// Continuation token for fetching more songs, if available.
    let continuationToken: String?

    /// Whether more songs are available to load.
    var hasMore: Bool {
        self.continuationToken != nil
    }
}

// MARK: - PlaylistTracksResponse

/// Response from the playlist tracks API, including pagination support.
struct PlaylistTracksResponse: Sendable {
    /// The playlist detail with header info and initial tracks.
    let detail: PlaylistDetail

    /// Continuation token for fetching more tracks, if available.
    let continuationToken: String?

    /// Whether more tracks are available to load.
    var hasMore: Bool {
        self.continuationToken != nil
    }
}

// MARK: - PlaylistContinuationResponse

/// Response from a playlist continuation request.
struct PlaylistContinuationResponse: Sendable {
    /// The additional tracks from this continuation.
    let tracks: [Song]

    /// Continuation token for fetching more tracks, if available.
    let continuationToken: String?

    /// Whether more tracks are available to load.
    var hasMore: Bool {
        self.continuationToken != nil
    }
}
