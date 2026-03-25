import Foundation

// MARK: - Artist

/// Represents an artist from YouTube Music.
struct Artist: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let thumbnailURL: URL?

    init(id: String, name: String, thumbnailURL: URL? = nil) {
        self.id = id
        self.name = name
        self.thumbnailURL = thumbnailURL
    }

    /// Whether this artist has a valid navigable ID.
    /// Valid artist IDs are YouTube channel IDs ("UC...") and library artist browse IDs ("MPLAUC...").
    /// Generated IDs (UUIDs with hyphens, SHA256 hashes) are not navigable.
    var hasNavigableId: Bool {
        Self.isNavigableId(self.id)
    }

    /// The public channel ID for this artist, if one can be derived.
    var publicChannelId: String? {
        Self.publicChannelId(for: self.id)
    }
}

extension Artist {
    static let channelIdPrefix = "UC"
    static let libraryArtistBrowseIdPrefix = "MPLAUC"

    static func isChannelId(_ id: String) -> Bool {
        id.hasPrefix(self.channelIdPrefix)
    }

    static func isLibraryArtistBrowseId(_ id: String) -> Bool {
        id.hasPrefix(self.libraryArtistBrowseIdPrefix)
    }

    static func isNavigableId(_ id: String) -> Bool {
        self.isChannelId(id) || self.isLibraryArtistBrowseId(id)
    }

    /// Converts a navigable artist ID into the public artist channel ID used by share URLs and subscriptions.
    static func publicChannelId(for id: String) -> String? {
        if self.isChannelId(id) {
            return id
        }

        if self.isLibraryArtistBrowseId(id) {
            return String(id.dropFirst("MPLA".count))
        }

        return nil
    }

    /// Creates an Artist from YouTube Music API response data.
    init?(from data: [String: Any]) {
        let name = (data["name"] as? String) ?? "Unknown Artist"

        // Artist ID is optional for inline references
        let artistId = (data["id"] as? String) ?? (data["browseId"] as? String) ?? UUID().uuidString

        self.id = artistId
        self.name = name

        // Parse thumbnail
        if let thumbnails = data["thumbnails"] as? [[String: Any]],
           let lastThumbnail = thumbnails.last,
           let urlString = lastThumbnail["url"] as? String
        {
            self.thumbnailURL = URL(string: urlString)
        } else {
            self.thumbnailURL = nil
        }
    }
}
