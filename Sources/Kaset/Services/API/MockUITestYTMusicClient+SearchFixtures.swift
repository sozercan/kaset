import Foundation

// MARK: - Mock UI-Test Search Fixtures

extension MockUITestYTMusicClient {
    static func parseSearchResults() -> SearchResponse? {
        guard let jsonString = UITestConfig.environmentValue(for: UITestConfig.mockSearchResultsKey),
              let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let continuationToken = dict["continuationToken"] as? String

        if let itemDictionaries = dict["items"] as? [[String: Any]] {
            return SearchResponse(
                items: itemDictionaries.compactMap(Self.parseSearchItem),
                continuationToken: continuationToken
            )
        }

        return SearchResponse(
            songs: Self.parseSearchArray(dict["songs"]) {
                Self.parseSearchSong($0)
            },
            videos: Self.parseSearchArray(dict["videos"]) {
                Self.parseSearchSong($0, defaultMusicVideoType: .omv)
            },
            albums: Self.parseSearchArray(dict["albums"], using: Self.parseSearchAlbum),
            audiobooks: Self.parseSearchArray(dict["audiobooks"], using: Self.parseSearchAlbum),
            artists: Self.parseSearchArray(dict["artists"]) {
                Self.parseSearchArtist($0, profileKind: .artist)
            },
            profiles: Self.parseSearchArray(dict["profiles"]) {
                Self.parseSearchArtist($0, profileKind: .profile)
            },
            playlists: Self.parseSearchArray(dict["playlists"], using: Self.parseSearchPlaylist),
            podcastShows: Self.parseSearchArray(dict["podcastShows"], using: Self.parseSearchPodcastShow),
            podcastEpisodes: Self.parseSearchArray(dict["podcastEpisodes"], using: Self.parseSearchPodcastEpisode),
            continuationToken: continuationToken
        )
    }

    static func parseSearchArray<Value>(
        _ value: Any?,
        using transform: ([String: Any]) -> Value?
    ) -> [Value] {
        (value as? [[String: Any]])?.compactMap(transform) ?? []
    }

    static func parseSearchItem(_ dict: [String: Any]) -> SearchResultItem? {
        guard let rawType = dict["type"] as? String else {
            return nil
        }

        let type = rawType.lowercased().filter { $0.isLetter || $0.isNumber }
        switch type {
        case "song", "songs":
            return Self.parseSearchSong(dict).map(SearchResultItem.song)
        case "video", "videos":
            return Self.parseSearchSong(dict, defaultMusicVideoType: .omv).map(SearchResultItem.video)
        case "album", "albums":
            return Self.parseSearchAlbum(dict).map(SearchResultItem.album)
        case "audiobook", "audiobooks":
            return Self.parseSearchAlbum(dict).map(SearchResultItem.audiobook)
        case "artist", "artists":
            return Self.parseSearchArtist(dict, profileKind: .artist).map(SearchResultItem.artist)
        case "profile", "profiles":
            return Self.parseSearchArtist(dict, profileKind: .profile).map(SearchResultItem.profile)
        case "playlist", "playlists":
            return Self.parseSearchPlaylist(dict).map(SearchResultItem.playlist)
        case "podcast", "podcastshow", "podcastshows", "show":
            return Self.parseSearchPodcastShow(dict).map(SearchResultItem.podcastShow)
        case "episode", "podcastepisode", "podcastepisodes":
            return Self.parseSearchPodcastEpisode(dict).map(SearchResultItem.podcastEpisode)
        default:
            return nil
        }
    }

    static func parseSearchSong(
        _ dict: [String: Any],
        defaultMusicVideoType: MusicVideoType? = nil
    ) -> Song? {
        guard let id = dict["id"] as? String,
              let title = dict["title"] as? String,
              let videoId = dict["videoId"] as? String
        else {
            return nil
        }

        let artistNames = Self.parseArtistNames(from: dict)
        let artists = artistNames.enumerated().map { index, name in
            Artist(id: "mock-search-artist-\(index)", name: name)
        }
        let primaryArtist = artistNames.first ?? "Unknown"
        let album: Album? = if let albumDict = dict["album"] as? [String: Any] {
            Self.parseSearchAlbum(albumDict)
        } else if let albumId = dict["albumId"] as? String,
                  let albumTitle = dict["albumTitle"] as? String
        {
            Album(
                id: albumId,
                title: albumTitle,
                artists: [Artist.inline(name: primaryArtist, namespace: "mock-search-album")],
                thumbnailURL: nil,
                year: nil,
                trackCount: nil
            )
        } else {
            nil
        }
        let musicVideoType = (dict["musicVideoType"] as? String).flatMap(MusicVideoType.init(rawValue:))
            ?? defaultMusicVideoType

        return Song(
            id: id,
            title: title,
            artists: artists.isEmpty ? [Artist(id: "mock", name: "Unknown")] : artists,
            album: album,
            duration: Self.parseTimeInterval(dict["duration"]),
            thumbnailURL: Self.parseURL(dict["thumbnailURL"]),
            videoId: videoId,
            isPlayable: dict["isPlayable"] as? Bool ?? true,
            hasVideo: dict["hasVideo"] as? Bool ?? defaultMusicVideoType.map { _ in true },
            musicVideoType: musicVideoType,
            isExplicit: dict["isExplicit"] as? Bool
        )
    }

    static func parseSearchAlbum(_ dict: [String: Any]) -> Album? {
        guard let id = dict["id"] as? String,
              let title = dict["title"] as? String
        else {
            return nil
        }

        let artistNames = Self.parseArtistNames(from: dict)
        let artists = artistNames.isEmpty ? nil : artistNames.map {
            Artist.inline(name: $0, namespace: "mock-search-album")
        }

        return Album(
            id: id,
            title: title,
            artists: artists,
            thumbnailURL: Self.parseURL(dict["thumbnailURL"]),
            year: dict["year"] as? String,
            trackCount: Self.parseInt(dict["trackCount"])
        )
    }

    static func parseSearchArtist(
        _ dict: [String: Any],
        profileKind: ArtistProfileKind
    ) -> Artist? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String ?? dict["title"] as? String
        else {
            return nil
        }

        return Artist(
            id: id,
            name: name,
            thumbnailURL: Self.parseURL(dict["thumbnailURL"]),
            subtitle: dict["subtitle"] as? String,
            profileKind: profileKind
        )
    }

    static func parseSearchPlaylist(_ dict: [String: Any]) -> Playlist? {
        guard let id = dict["id"] as? String,
              let title = dict["title"] as? String
        else {
            return nil
        }

        return Playlist(
            id: id,
            title: title,
            description: dict["description"] as? String,
            thumbnailURL: Self.parseURL(dict["thumbnailURL"]),
            trackCount: Self.parseInt(dict["trackCount"]),
            author: (dict["author"] as? String).map {
                Artist.inline(name: $0, namespace: "mock-search-playlist-author")
            },
            canDelete: dict["canDelete"] as? Bool ?? false
        )
    }

    static func parseSearchPodcastShow(_ dict: [String: Any]) -> PodcastShow? {
        guard let id = dict["id"] as? String,
              let title = dict["title"] as? String
        else {
            return nil
        }

        return PodcastShow(
            id: id,
            title: title,
            author: dict["author"] as? String,
            description: dict["description"] as? String,
            thumbnailURL: Self.parseURL(dict["thumbnailURL"]),
            episodeCount: Self.parseInt(dict["episodeCount"])
        )
    }

    static func parseSearchPodcastEpisode(_ dict: [String: Any]) -> PodcastEpisode? {
        guard let id = dict["id"] as? String,
              let title = dict["title"] as? String
        else {
            return nil
        }

        return PodcastEpisode(
            id: id,
            title: title,
            showTitle: dict["showTitle"] as? String,
            showBrowseId: dict["showBrowseId"] as? String,
            description: dict["description"] as? String,
            thumbnailURL: Self.parseURL(dict["thumbnailURL"]),
            publishedDate: dict["publishedDate"] as? String,
            duration: dict["duration"] as? String,
            durationSeconds: Self.parseInt(dict["durationSeconds"]),
            playbackProgress: Self.parseDouble(dict["playbackProgress"]) ?? 0,
            isPlayed: dict["isPlayed"] as? Bool ?? false
        )
    }

    static func parseArtistNames(from dict: [String: Any]) -> [String] {
        if let artists = dict["artists"] as? [String] {
            return artists
        }

        if let artists = dict["artists"] as? [[String: Any]] {
            return artists.compactMap { $0["name"] as? String }
        }

        return (dict["artist"] as? String).map { [$0] } ?? []
    }

    static func parseURL(_ value: Any?) -> URL? {
        (value as? String).flatMap(URL.init(string:))
    }

    static func parseInt(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    static func parseDouble(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }

    static func parseTimeInterval(_ value: Any?) -> TimeInterval? {
        self.parseDouble(value)
    }
}
