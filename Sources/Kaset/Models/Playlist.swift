import Foundation

// MARK: - Playlist

/// Represents a playlist from YouTube Music.
struct Playlist: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let description: String?
    let thumbnailURL: URL?
    let trackCount: Int?
    let author: Artist?
    let canDelete: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case thumbnailURL
        case trackCount
        case author
        case canDelete
    }

    init(
        id: String,
        title: String,
        description: String?,
        thumbnailURL: URL?,
        trackCount: Int?,
        author: Artist? = nil,
        canDelete: Bool = false
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.thumbnailURL = thumbnailURL
        self.trackCount = trackCount
        self.author = author
        self.canDelete = canDelete
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        self.trackCount = try container.decodeIfPresent(Int.self, forKey: .trackCount)

        if let legacyAuthor = try? container.decode(String.self, forKey: .author) {
            self.author = Artist.inline(name: legacyAuthor, namespace: "playlist-author")
        } else if let author = try? container.decode(Artist.self, forKey: .author) {
            self.author = author
        } else {
            self.author = nil
        }

        self.canDelete = (try? container.decode(Bool.self, forKey: .canDelete)) ?? false
    }

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
            if let artist = Artist(from: firstAuthor) {
                self.author = artist
            } else if let name = firstAuthor["name"] as? String {
                self.author = Artist.inline(name: name, namespace: "playlist-author")
            } else {
                self.author = nil
            }
        } else if let authorName = data["author"] as? String {
            self.author = Artist.inline(name: authorName, namespace: "playlist-author")
        } else {
            self.author = nil
        }

        self.canDelete = data["canDelete"] as? Bool ?? false
    }
}

// MARK: - AddToPlaylistMenu

/// Menu data returned by YouTube Music for adding a song to playlists.
struct AddToPlaylistMenu: Codable, Hashable {
    let title: String?
    let options: [AddToPlaylistOption]
    let canCreatePlaylist: Bool
}

// MARK: - AddToPlaylistOption

/// A playlist option in the add-to-playlist menu.
struct AddToPlaylistOption: Identifiable, Codable, Hashable {
    let playlistId: String
    let title: String
    let subtitle: String?
    let thumbnailURL: URL?
    let isSelected: Bool
    let privacyStatus: PlaylistPrivacyStatus?

    var id: String {
        self.playlistId
    }
}

// MARK: - PlaylistPrivacyStatus

/// YouTube playlist privacy values used when creating/editing playlists.
enum PlaylistPrivacyStatus: String, Codable, Hashable, CaseIterable {
    case `public` = "PUBLIC"
    case unlisted = "UNLISTED"
    case `private` = "PRIVATE"
}

// MARK: - PlaylistDetail

/// Detailed playlist information including tracks.
struct PlaylistDetail: Identifiable {
    let id: String
    let title: String
    let description: String?
    let thumbnailURL: URL?
    let author: Artist?
    let trackCount: Int?
    let canDelete: Bool
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
        self.trackCount = playlist.trackCount
        self.canDelete = playlist.canDelete
        self.tracks = tracks
        self.duration = duration
    }

    /// Track count to show in the UI, preferring the API-reported total over the loaded row count.
    var resolvedTrackCount: Int {
        self.trackCount ?? self.tracks.count
    }

    /// Display string for the resolved track count.
    var trackCountDisplay: String {
        let count = self.resolvedTrackCount
        return count == 1 ? "1 song" : "\(count.formatted()) songs"
    }
}

// MARK: - LikedSongsResponse

/// Response from the liked songs API, including pagination support.
struct LikedSongsResponse {
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
struct PlaylistTracksResponse {
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
struct PlaylistContinuationResponse {
    /// The additional tracks from this continuation.
    let tracks: [Song]

    /// Continuation token for fetching more tracks, if available.
    let continuationToken: String?

    /// Whether more tracks are available to load.
    var hasMore: Bool {
        self.continuationToken != nil
    }
}
