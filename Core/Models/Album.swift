import Foundation

// MARK: - Album

/// Represents an album from YouTube Music.
struct Album: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let artists: [Artist]?
    let thumbnailURL: URL?
    let year: String?
    let trackCount: Int?

    /// Display string for artists (comma-separated).
    var artistsDisplay: String {
        artists?.map(\.name).joined(separator: ", ") ?? ""
    }
}

extension Album {
    /// Creates an Album from YouTube Music API response data.
    init?(from data: [String: Any]) {
        // Album ID can come from different fields
        guard let albumId = data["browseId"] as? String ?? data["id"] as? String ?? data["albumId"] as? String else {
            // For inline album references (e.g., in song data), create a minimal album
            if let name = data["name"] as? String {
                id = UUID().uuidString
                title = name
                artists = nil
                thumbnailURL = nil
                year = nil
                trackCount = nil
                return
            }
            return nil
        }

        id = albumId
        title = (data["title"] as? String) ?? (data["name"] as? String) ?? "Unknown Album"

        // Parse artists
        if let artistsData = data["artists"] as? [[String: Any]] {
            artists = artistsData.compactMap { Artist(from: $0) }
        } else {
            artists = nil
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

        year = data["year"] as? String

        // Parse track count
        if let count = data["trackCount"] as? Int {
            trackCount = count
        } else {
            trackCount = nil
        }
    }
}
