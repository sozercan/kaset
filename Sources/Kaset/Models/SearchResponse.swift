import Foundation

// MARK: - SearchResponse

/// Response from a YouTube Music search query.
///
/// `items` is the canonical representation so mixed search preserves YouTube
/// Music's server ranking. Typed collections are projections used by filters and
/// compatibility call sites.
struct SearchResponse {
    let items: [SearchResultItem]
    /// Continuation value for loading more results (only present for filtered searches).
    let continuationToken: String?

    /// All results in server-provided order.
    var allItems: [SearchResultItem] {
        self.items
    }

    var songs: [Song] {
        self.items.compactMap { item in
            guard case let .song(song) = item else { return nil }
            return song
        }
    }

    var videos: [Song] {
        self.items.compactMap { item in
            guard case let .video(video) = item else { return nil }
            return video
        }
    }

    var albums: [Album] {
        self.items.compactMap { item in
            guard case let .album(album) = item else { return nil }
            return album
        }
    }

    var audiobooks: [Album] {
        self.items.compactMap { item in
            guard case let .audiobook(audiobook) = item else { return nil }
            return audiobook
        }
    }

    var artists: [Artist] {
        self.items.compactMap { item in
            guard case let .artist(artist) = item else { return nil }
            return artist
        }
    }

    var profiles: [Artist] {
        self.items.compactMap { item in
            guard case let .profile(profile) = item else { return nil }
            return profile
        }
    }

    var playlists: [Playlist] {
        self.items.compactMap { item in
            guard case let .playlist(playlist) = item else { return nil }
            return playlist
        }
    }

    var podcastShows: [PodcastShow] {
        self.items.compactMap { item in
            guard case let .podcastShow(show) = item else { return nil }
            return show
        }
    }

    var podcastEpisodes: [PodcastEpisode] {
        self.items.compactMap { item in
            guard case let .podcastEpisode(episode) = item else { return nil }
            return episode
        }
    }

    /// Whether the search returned any results.
    var isEmpty: Bool {
        self.items.isEmpty
    }

    /// Whether more results are available to load.
    var hasMore: Bool {
        self.continuationToken != nil
    }

    static let empty = SearchResponse(items: [], continuationToken: nil)

    init(items: [SearchResultItem], continuationToken value: String? = nil) {
        self.items = items
        self.continuationToken = value
    }

    /// Compatibility initializer for category-specific callers and tests.
    /// Mixed API parsing should use `init(items:continuationToken:)` instead.
    init(
        songs: [Song] = [],
        videos: [Song] = [],
        albums: [Album] = [],
        audiobooks: [Album] = [],
        artists: [Artist] = [],
        profiles: [Artist] = [],
        playlists: [Playlist] = [],
        podcastShows: [PodcastShow] = [],
        podcastEpisodes: [PodcastEpisode] = [],
        continuationToken value: String? = nil
    ) {
        var items: [SearchResultItem] = []
        items.reserveCapacity(
            songs.count + videos.count + albums.count + audiobooks.count + artists.count
                + profiles.count + playlists.count + podcastShows.count + podcastEpisodes.count
        )
        items.append(contentsOf: songs.map(SearchResultItem.song))
        items.append(contentsOf: videos.map(SearchResultItem.video))
        items.append(contentsOf: albums.map(SearchResultItem.album))
        items.append(contentsOf: audiobooks.map(SearchResultItem.audiobook))
        items.append(contentsOf: artists.map { artist in
            artist.profileKind == .profile ? .profile(artist) : .artist(artist)
        })
        items.append(contentsOf: profiles.map(SearchResultItem.profile))
        items.append(contentsOf: playlists.map(SearchResultItem.playlist))
        items.append(contentsOf: podcastShows.map(SearchResultItem.podcastShow))
        items.append(contentsOf: podcastEpisodes.map(SearchResultItem.podcastEpisode))

        self.init(items: items, continuationToken: value)
    }
}

// MARK: - SearchResultItem

/// A semantically typed YouTube Music search result.
enum SearchResultItem: Identifiable, Hashable {
    case song(Song)
    case video(Song)
    case album(Album)
    case audiobook(Album)
    case artist(Artist)
    case profile(Artist)
    case playlist(Playlist)
    case podcastShow(PodcastShow)
    case podcastEpisode(PodcastEpisode)

    var id: String {
        switch self {
        case let .song(song):
            "song-\(song.id)"
        case let .video(video):
            "video-\(video.id)"
        case let .album(album):
            "album-\(album.id)"
        case let .audiobook(audiobook):
            "audiobook-\(audiobook.id)"
        case let .artist(artist):
            "artist-\(artist.id)"
        case let .profile(profile):
            "profile-\(profile.id)"
        case let .playlist(playlist):
            "playlist-\(playlist.id)"
        case let .podcastShow(show):
            "podcast-\(show.id)"
        case let .podcastEpisode(episode):
            "episode-\(episode.id)"
        }
    }

    /// Cross-type identity used to deduplicate the same destination while
    /// preserving the first server-ranked occurrence.
    var contentIdentity: String {
        switch self {
        case let .song(song), let .video(song):
            "video:\(song.videoId)"
        case let .podcastEpisode(episode):
            "video:\(episode.id)"
        case let .album(album), let .audiobook(album):
            "album:\(album.id)"
        case let .artist(artist), let .profile(artist):
            "artist:\(artist.id)"
        case let .playlist(playlist):
            "playlist:\(LibraryContentIdentity.playlistKey(for: playlist))"
        case let .podcastShow(show):
            "podcast:\(show.id)"
        }
    }

    var title: String {
        switch self {
        case let .song(song), let .video(song):
            song.title
        case let .album(album), let .audiobook(album):
            album.title
        case let .artist(artist), let .profile(artist):
            artist.name
        case let .playlist(playlist):
            playlist.title
        case let .podcastShow(show):
            show.title
        case let .podcastEpisode(episode):
            episode.title
        }
    }

    var subtitle: String? {
        switch self {
        case let .song(song), let .video(song):
            let display = song.artistsDisplay
            return display.isEmpty ? nil : display
        case let .album(album), let .audiobook(album):
            let display = album.artistsDisplay
            return display.isEmpty ? nil : display
        case let .artist(artist), let .profile(artist):
            return artist.subtitle
        case let .playlist(playlist):
            guard let authorName = playlist.author?.name else { return nil }
            let stripped = authorName
                .replacingOccurrences(of: "Playlist • ", with: "")
                .trimmingCharacters(in: .whitespaces)
            return stripped.isEmpty ? nil : stripped
        case let .podcastShow(show):
            return show.author
        case let .podcastEpisode(episode):
            let components = [episode.publishedDate, episode.showTitle]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return components.isEmpty ? nil : components.joined(separator: " • ")
        }
    }

    var thumbnailURL: URL? {
        switch self {
        case let .song(song), let .video(song):
            song.thumbnailURL
        case let .album(album), let .audiobook(album):
            album.thumbnailURL
        case let .artist(artist), let .profile(artist):
            artist.thumbnailURL
        case let .playlist(playlist):
            playlist.thumbnailURL
        case let .podcastShow(show):
            show.thumbnailURL
        case let .podcastEpisode(episode):
            episode.thumbnailURL
        }
    }

    var resultType: String {
        switch self {
        case .song:
            String(localized: "Song")
        case .video:
            String(localized: "Video")
        case .album:
            String(localized: "Album")
        case .audiobook:
            String(localized: "Audiobook")
        case .artist:
            String(localized: "Artist")
        case .profile:
            String(localized: "Profile")
        case .playlist:
            String(localized: "Playlist")
        case .podcastShow:
            String(localized: "Podcast")
        case .podcastEpisode:
            String(localized: "Episode")
        }
    }

    /// Returns the playable video ID, when the result is directly playable.
    var videoId: String? {
        switch self {
        case let .song(song), let .video(song):
            song.videoId
        case let .podcastEpisode(episode):
            episode.id
        default:
            nil
        }
    }

    /// Song payload used by shared playback, queue, favorite, and share actions.
    var songPayload: Song? {
        switch self {
        case let .song(song), let .video(song):
            song
        case let .podcastEpisode(episode):
            episode.playbackSong
        default:
            nil
        }
    }

    var usesCircularThumbnail: Bool {
        switch self {
        case .artist, .profile:
            true
        default:
            false
        }
    }
}
