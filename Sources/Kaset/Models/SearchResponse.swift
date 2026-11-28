import Foundation

struct SearchResponse {
    let items: [SearchResultItem]
    let continuationToken: String?

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

    var isEmpty: Bool {
        self.items.isEmpty
    }

    var hasMore: Bool {
        self.continuationToken != nil
    }

    static let empty = SearchResponse(items: [], continuationToken: nil)

    init(items: [SearchResultItem], continuationToken value: String? = nil) {
        self.items = items
        self.continuationToken = value
    }
}

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
