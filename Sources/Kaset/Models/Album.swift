import Foundation

struct Album: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artists: [Artist]?
    let thumbnailURL: URL?
    let year: String?
    let trackCount: Int?
    let libraryTargetId: String?

    init(
        id: String,
        title: String,
        artists: [Artist]?,
        thumbnailURL: URL?,
        year: String?,
        trackCount: Int?,
        libraryTargetId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.thumbnailURL = thumbnailURL
        self.year = year
        self.trackCount = trackCount
        self.libraryTargetId = libraryTargetId
    }

    var artistsDisplay: String {
        self.artists?.map(\.name).joined(separator: ", ") ?? ""
    }

    var hasNavigableId: Bool {
        !self.id.contains("-") && (self.id.hasPrefix("MPRE") || self.id.hasPrefix("OLAK"))
    }
}

extension Album {
    init?(from data: [String: Any]) {
        guard let albumId = data["browseId"] as? String ?? data["id"] as? String ?? data["albumId"] as? String else {
            if let name = data["name"] as? String {
                self.id = UUID().uuidString
                self.title = name
                self.artists = nil
                self.thumbnailURL = nil
                self.year = nil
                self.trackCount = nil
                self.libraryTargetId = nil
                return
            }
            return nil
        }

        self.id = albumId
        self.title = (data["title"] as? String) ?? (data["name"] as? String) ?? "Unknown Album"

        if let artistsData = data["artists"] as? [[String: Any]] {
            self.artists = artistsData.compactMap { Artist(from: $0) }
        } else {
            self.artists = nil
        }

        if let thumbnails = data["thumbnails"] as? [[String: Any]],
           let lastThumbnail = thumbnails.last,
           let urlString = lastThumbnail["url"] as? String
        {
            self.thumbnailURL = URL(string: urlString)
        } else {
            self.thumbnailURL = nil
        }

        self.year = data["year"] as? String

        if let count = data["trackCount"] as? Int {
            self.trackCount = count
        } else {
            self.trackCount = nil
        }

        self.libraryTargetId = data["playlistId"] as? String
    }
}
