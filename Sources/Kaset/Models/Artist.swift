import Foundation

// MARK: - ArtistProfileKind

enum ArtistProfileKind: String, Codable, Hashable {
    case artist
    case profile
    case unknown
}

// MARK: - Artist

/// Represents an artist from YouTube Music.
struct Artist: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let thumbnailURL: URL?
    let subtitle: String?
    let profileKind: ArtistProfileKind

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case thumbnailURL
        case subtitle
        case profileKind
    }

    init(
        id: String,
        name: String,
        thumbnailURL: URL? = nil,
        subtitle: String? = nil,
        profileKind: ArtistProfileKind = .unknown
    ) {
        self.id = id
        self.name = name
        self.thumbnailURL = thumbnailURL
        self.subtitle = subtitle
        self.profileKind = profileKind
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        self.subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)

        let rawProfileKind = try container.decodeIfPresent(String.self, forKey: .profileKind)
        self.profileKind = rawProfileKind.flatMap(ArtistProfileKind.init(rawValue:)) ?? .unknown
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
    private static let inlineIdPrefix = "inline"

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

    static func inline(name: String, thumbnailURL: URL? = nil, subtitle: String? = nil, namespace: String = "artist") -> Artist {
        Artist(
            id: self.inlineId(for: name, namespace: namespace),
            name: name,
            thumbnailURL: thumbnailURL,
            subtitle: subtitle,
            profileKind: .unknown
        )
    }

    static func inlineId(for name: String, namespace: String = "artist") -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = trimmedName.isEmpty ? "unknown" : trimmedName
        return "\(self.inlineIdPrefix):\(namespace):\(normalizedName)"
    }

    static func profileKind(forPageType pageType: String?) -> ArtistProfileKind {
        switch pageType {
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_LIBRARY_ARTIST":
            .artist
        case "MUSIC_PAGE_TYPE_USER_CHANNEL":
            .profile
        default:
            .unknown
        }
    }

    private static func extractPageType(from data: [String: Any]) -> String? {
        if let pageType = data["pageType"] as? String {
            return pageType
        }

        if let contextConfigs = data["browseEndpointContextSupportedConfigs"] as? [String: Any],
           let musicConfig = contextConfigs["browseEndpointContextMusicConfig"] as? [String: Any],
           let pageType = musicConfig["pageType"] as? String
        {
            return pageType
        }

        return nil
    }

    /// Creates an Artist from YouTube Music API response data.
    init?(from data: [String: Any]) {
        let name = (data["name"] as? String) ?? "Unknown Artist"

        // Artist ID is optional for inline references
        let artistId = (data["id"] as? String) ?? (data["browseId"] as? String) ?? Self.inlineId(for: name)

        self.id = artistId
        self.name = name
        self.subtitle = data["subtitle"] as? String
        self.profileKind = Self.profileKind(forPageType: Self.extractPageType(from: data))

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
