import Foundation

// MARK: - Artist

/// Represents an artist from YouTube Music.
struct Artist: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let thumbnailURL: URL?

    init(id: String, name: String, thumbnailURL: URL? = nil) {
        self.id = id
        self.name = name
        self.thumbnailURL = thumbnailURL
    }

    /// Whether this artist has a valid navigable ID (not a generated UUID).
    /// YouTube Music artist IDs are channel IDs like "UCxxxxxxx" and don't contain hyphens.
    var hasNavigableId: Bool {
        !self.id.isEmpty && !self.id.contains("-")
    }
}

extension Artist {
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
