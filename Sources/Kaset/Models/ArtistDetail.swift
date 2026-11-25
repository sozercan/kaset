import Foundation

enum ArtistDetailSectionContent: Hashable {
    case albums([Album])
    case playlists([Playlist])
    case artists([Artist])
}

struct ArtistDetailSection: Identifiable, Hashable {
    let title: String
    let content: ArtistDetailSectionContent

    var id: String {
        switch self.content {
        case let .albums(albums):
            let firstID = albums.first?.id ?? "empty"
            return "albums:\(self.title):\(firstID)"
        case let .playlists(playlists):
            let firstID = playlists.first?.id ?? "empty"
            return "playlists:\(self.title):\(firstID)"
        case let .artists(artists):
            let firstID = artists.first?.id ?? "empty"
            return "artists:\(self.title):\(firstID)"
        }
    }
}

struct ArtistDetail {
    let artist: Artist
    let description: String?
    let songs: [Song]
    let songsSectionTitle: String?
    let orderedSections: [ArtistDetailSection]
    let albums: [Album]
    let singles: [Album]
    let episodes: [ArtistEpisode]
    let playlistsByArtist: [Playlist]
    let relatedArtists: [Artist]
    let podcasts: [PodcastShow]
    let moreEndpoints: [ArtistShelfKind: ShelfMoreEndpoint]
    let thumbnailURL: URL?
    let channelId: String?
    var isSubscribed: Bool
    let subscriberCount: String?
    let subscribedButtonText: String?
    let unsubscribedButtonText: String?
    let monthlyAudience: String?
    let hasMoreSongs: Bool
    let songsBrowseId: String?
    let songsParams: String?
    let mixPlaylistId: String?
    let mixVideoId: String?

    var id: String {
        self.artist.id
    }

    var name: String {
        self.artist.name
    }

    var profileKind: ArtistProfileKind {
        self.artist.profileKind
    }

    init(
        artist: Artist,
        description: String?,
        songs: [Song],
        songsSectionTitle: String? = nil,
        orderedSections: [ArtistDetailSection] = [],
        albums: [Album] = [],
        singles: [Album] = [],
        episodes: [ArtistEpisode] = [],
        playlistsByArtist: [Playlist] = [],
        relatedArtists: [Artist] = [],
        podcasts: [PodcastShow] = [],
        moreEndpoints: [ArtistShelfKind: ShelfMoreEndpoint] = [:],
        thumbnailURL: URL?,
        channelId: String? = nil,
        isSubscribed: Bool = false,
        subscriberCount: String? = nil,
        subscribedButtonText: String? = nil,
        unsubscribedButtonText: String? = nil,
        monthlyAudience: String? = nil,
        hasMoreSongs: Bool = false,
        songsBrowseId: String? = nil,
        songsParams: String? = nil,
        mixPlaylistId: String? = nil,
        mixVideoId: String? = nil
    ) {
        self.artist = artist
        self.description = description
        self.songs = songs
        self.songsSectionTitle = songsSectionTitle
        self.orderedSections = orderedSections
        self.albums = albums
        self.singles = singles
        self.episodes = episodes
        self.playlistsByArtist = playlistsByArtist
        self.relatedArtists = relatedArtists
        self.podcasts = podcasts
        self.moreEndpoints = moreEndpoints
        self.thumbnailURL = thumbnailURL
        self.channelId = channelId
        self.isSubscribed = isSubscribed
        self.subscriberCount = subscriberCount
        self.subscribedButtonText = subscribedButtonText
        self.unsubscribedButtonText = unsubscribedButtonText
        self.monthlyAudience = monthlyAudience
        self.hasMoreSongs = hasMoreSongs
        self.songsBrowseId = songsBrowseId
        self.songsParams = songsParams
        self.mixPlaylistId = mixPlaylistId
        self.mixVideoId = mixVideoId
    }
}
