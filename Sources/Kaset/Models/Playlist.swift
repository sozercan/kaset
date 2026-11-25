import Foundation

struct Playlist: Identifiable, Codable, Hashable {
    static let uploadedSongsBrowseID = "FEmusic_library_privately_owned_tracks"

    let id: String
    let title: String
    let description: String?
    let thumbnailURL: URL?
    let trackCount: Int?
    let author: Artist?
    let canDelete: Bool
    let moodCategoryEndpoint: MoodCategoryEndpoint?
    let libraryTargetId: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case thumbnailURL
        case trackCount
        case author
        case canDelete
        case moodCategoryEndpoint
        case libraryTargetId
    }

    init(
        id: String,
        title: String,
        description: String?,
        thumbnailURL: URL?,
        trackCount: Int?,
        author: Artist? = nil,
        canDelete: Bool = false,
        moodCategoryEndpoint: MoodCategoryEndpoint? = nil,
        libraryTargetId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.thumbnailURL = thumbnailURL
        self.trackCount = trackCount
        self.author = author
        self.canDelete = canDelete
        self.moodCategoryEndpoint = moodCategoryEndpoint
        self.libraryTargetId = libraryTargetId
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
        self.moodCategoryEndpoint = try container.decodeIfPresent(
            MoodCategoryEndpoint.self,
            forKey: .moodCategoryEndpoint
        )
        self.libraryTargetId = try container.decodeIfPresent(String.self, forKey: .libraryTargetId)
    }

    var isAlbum: Bool {
        self.id.hasPrefix("OLAK") || self.id.hasPrefix("MPRE")
    }

    var isUploadedSongs: Bool {
        self.id == Self.uploadedSongsBrowseID
    }

    var supportsLibraryToggle: Bool {
        Self.supportsLibraryToggle(id: self.id)
    }

    static func supportsLibraryToggle(id: String) -> Bool {
        let key = LibraryContentIdentity.playlistKey(for: id)
        return ![LikedMusicPlaylist.id, "RDPN", "SE", Self.uploadedSongsBrowseID].contains(key)
    }

    var requiresPersonalAccountForContinuations: Bool {
        LikedMusicPlaylist.matches(id: self.id) || self.isUploadedSongs || self.canDelete
    }

    var trackCountDisplay: String {
        guard let count = trackCount else { return "" }
        return count == 1 ? "1 song" : "\(count) songs"
    }
}

extension Playlist {
    init?(from data: [String: Any]) {
        guard let playlistId = data["playlistId"] as? String ?? data["browseId"] as? String else {
            return nil
        }

        self.id = playlistId
        self.title = (data["title"] as? String) ?? "Unknown Playlist"
        self.description = data["description"] as? String

        if let thumbnails = data["thumbnails"] as? [[String: Any]],
           let lastThumbnail = thumbnails.last,
           let urlString = lastThumbnail["url"] as? String
        {
            self.thumbnailURL = URL(string: urlString)
        } else {
            self.thumbnailURL = nil
        }

        if let count = data["trackCount"] as? Int {
            self.trackCount = count
        } else if let countString = data["trackCount"] as? String,
                  let count = Int(countString.replacingOccurrences(of: ",", with: ""))
        {
            self.trackCount = count
        } else {
            self.trackCount = nil
        }

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
        self.moodCategoryEndpoint = nil
        self.libraryTargetId = data["libraryTargetId"] as? String
    }
}

struct AddToPlaylistMenu: Codable, Hashable {
    let title: String?
    let options: [AddToPlaylistOption]
    let canCreatePlaylist: Bool
}

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

enum PlaylistPrivacyStatus: String, Codable, Hashable, CaseIterable {
    case `public` = "PUBLIC"
    case unlisted = "UNLISTED"
    case `private` = "PRIVATE"
}

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
    let libraryTargetId: String?

    var isAlbum: Bool {
        self.id.hasPrefix("OLAK") || self.id.hasPrefix("MPRE")
    }

    var isUploadedSongs: Bool {
        self.id == Playlist.uploadedSongsBrowseID
    }

    var supportsLibraryToggle: Bool {
        Playlist.supportsLibraryToggle(id: self.id)
    }

    var requiresPersonalAccountForContinuations: Bool {
        LikedMusicPlaylist.matches(id: self.id) || self.isUploadedSongs || self.canDelete
    }

    init(
        playlist: Playlist,
        tracks: [Song],
        duration: String? = nil,
        libraryTargetId: String? = nil
    ) {
        self.id = playlist.id
        self.title = playlist.title
        self.description = playlist.description
        self.thumbnailURL = playlist.thumbnailURL
        self.author = playlist.author
        self.trackCount = playlist.trackCount
        self.canDelete = playlist.canDelete
        self.tracks = tracks
        self.duration = duration
        self.libraryTargetId = libraryTargetId ?? playlist.libraryTargetId
    }

    var resolvedTrackCount: Int {
        self.trackCount ?? self.tracks.count
    }

    var trackCountDisplay: String {
        let count = self.resolvedTrackCount
        return count == 1 ? "1 song" : "\(count.formatted()) songs"
    }
}

struct LikedSongsResponse {
    let songs: [Song]

    let continuationToken: String?

    var hasMore: Bool {
        self.continuationToken != nil
    }
}

struct PlaylistTracksResponse {
    let detail: PlaylistDetail

    let continuationToken: String?

    var hasMore: Bool {
        self.continuationToken != nil
    }
}

struct PlaylistContinuationResponse {
    let tracks: [Song]

    let continuationToken: String?

    var hasMore: Bool {
        self.continuationToken != nil
    }
}
