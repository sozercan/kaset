import AppIntents
import Foundation

struct SongEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Song"
    static let defaultQuery = SongEntityQuery()

    let id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Artist")
    var artist: String

    @Property(title: "Album")
    var album: String?

    let thumbnailURL: URL?
    let isPlayable: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(self.title)",
            subtitle: self.artist.isEmpty ? nil : "\(self.artist)",
            image: self.thumbnailURL.map { DisplayRepresentation.Image(url: $0) }
        )
    }

    init(song: Song) {
        self.id = song.videoId
        self.thumbnailURL = song.thumbnailURL
        self.isPlayable = song.isPlayable
        self.title = song.title
        self.artist = song.artistsDisplay
        self.album = song.album?.title
    }

    var song: Song {
        Song(
            id: self.id,
            title: self.title,
            artists: [],
            thumbnailURL: self.thumbnailURL,
            videoId: self.id,
            isPlayable: self.isPlayable
        )
    }
}

struct SongEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [SongEntity.ID]) async throws -> [SongEntity] {
        var entities: [SongEntity] = []
        for videoId in identifiers {
            let song = await AppIntentsBridge.shared.song(videoId: videoId) ?? Song.placeholder(videoId: videoId)
            entities.append(SongEntity(song: song))
        }
        return entities
    }

    @MainActor
    func entities(matching string: String) async throws -> [SongEntity] {
        try await AppIntentsBridge.shared.searchSongs(matching: string).map(SongEntity.init(song:))
    }

    @MainActor
    func suggestedEntities() async throws -> [SongEntity] {
        let queue = AppIntentsBridge.shared.playerService?.queue ?? []
        return Array(queue.filter(\.isPlayable).prefix(25)).map(SongEntity.init(song:))
    }
}

struct PlaylistEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static let defaultQuery = PlaylistEntityQuery()

    let id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Author")
    var author: String?

    let thumbnailURL: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(self.title)",
            subtitle: self.author.map { "\($0)" },
            image: self.thumbnailURL.map { DisplayRepresentation.Image(url: $0) }
        )
    }

    init(playlist: Playlist) {
        self.id = playlist.id
        self.thumbnailURL = playlist.thumbnailURL
        self.title = playlist.title
        self.author = playlist.author?.name
    }

    @MainActor
    var playlist: Playlist {
        AppIntentsBridge.shared.library.playlists.first { $0.id == self.id }
            ?? Playlist(
                id: self.id,
                title: self.title,
                description: nil,
                thumbnailURL: self.thumbnailURL,
                trackCount: nil
            )
    }
}

struct PlaylistEntityQuery: EntityStringQuery {
    @MainActor
    static var knownPlaylists: [Playlist] {
        let bridge = AppIntentsBridge.shared
        let library = bridge.library.playablePlaylists.filter { !LikedMusicPlaylist.matches(id: $0.id) }
        guard bridge.isSignedIn else { return library }
        return [LikedMusicPlaylist.playlist] + library
    }

    @MainActor
    func entities(for identifiers: [PlaylistEntity.ID]) async throws -> [PlaylistEntity] {
        let known = Self.knownPlaylists
        return identifiers.map { id in
            let playlist = known.first { $0.id == id }
                ?? Playlist(id: id, title: id, description: nil, thumbnailURL: nil, trackCount: nil)
            return PlaylistEntity(playlist: playlist)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [PlaylistEntity] {
        let libraryMatches = Self.knownPlaylists.filter { AppIntentsSearch.title($0.title, matches: string) }
        let searchResults = try await AppIntentsBridge.shared.searchPlaylists(matching: string)
        return AppIntentsSearch.merge(libraryMatches, searchResults, id: \.id).map(PlaylistEntity.init(playlist:))
    }

    @MainActor
    func suggestedEntities() async throws -> [PlaylistEntity] {
        Self.knownPlaylists.map(PlaylistEntity.init(playlist:))
    }
}

struct AlbumEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Album"
    static let defaultQuery = AlbumEntityQuery()

    let id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Artist")
    var artist: String

    let thumbnailURL: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(self.title)",
            subtitle: self.artist.isEmpty ? nil : "\(self.artist)",
            image: self.thumbnailURL.map { DisplayRepresentation.Image(url: $0) }
        )
    }

    init(album: Album) {
        self.id = album.id
        self.thumbnailURL = album.thumbnailURL
        self.title = album.title
        self.artist = album.artistsDisplay
    }

    @MainActor
    var album: Album {
        AppIntentsBridge.shared.library.albums.first { $0.id == self.id }
            ?? Album(
                id: self.id,
                title: self.title,
                artists: nil,
                thumbnailURL: self.thumbnailURL,
                year: nil,
                trackCount: nil
            )
    }
}

struct AlbumEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [AlbumEntity.ID]) async throws -> [AlbumEntity] {
        let library = AppIntentsBridge.shared.library.playableAlbums
        return identifiers.map { id in
            let album = library.first { $0.id == id }
                ?? Album(id: id, title: id, artists: nil, thumbnailURL: nil, year: nil, trackCount: nil)
            return AlbumEntity(album: album)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [AlbumEntity] {
        let libraryMatches = AppIntentsBridge.shared.library.playableAlbums.filter {
            AppIntentsSearch.title($0.title, matches: string)
                || AppIntentsSearch.title($0.artistsDisplay, matches: string)
        }
        let searchResults = try await AppIntentsBridge.shared.searchAlbums(matching: string)
        return AppIntentsSearch.merge(libraryMatches, searchResults, id: \.id).map(AlbumEntity.init(album:))
    }

    @MainActor
    func suggestedEntities() async throws -> [AlbumEntity] {
        AppIntentsBridge.shared.library.playableAlbums.map(AlbumEntity.init(album:))
    }
}

enum AppIntentsSearch {
    static func title(_ title: String, matches query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }
        return title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    static func merge<Item>(_ preferred: [Item], _ others: [Item], id: (Item) -> String) -> [Item] {
        var seen = Set(preferred.map(id))
        var merged = preferred
        for item in others where seen.insert(id(item)).inserted {
            merged.append(item)
        }
        return merged
    }
}
