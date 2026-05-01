import Foundation

// MARK: - ArtistDetailSectionContent

enum ArtistDetailSectionContent: Hashable {
    case albums([Album])
    case playlists([Playlist])
    case artists([Artist])
}

// MARK: - ArtistDetailSection

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

// MARK: - ArtistDetail

/// Contains detailed artist information including their songs.
struct ArtistDetail {
    let artist: Artist
    let description: String?
    let songs: [Song]
    let songsSectionTitle: String?
    let orderedSections: [ArtistDetailSection]
    let albums: [Album]
    /// Singles & EPs, which use the same renderer as albums but live in their
    /// own shelf on the artist page. Empty when the artist has none.
    let singles: [Album]
    /// Latest episodes / video uploads on the artist's channel. Includes live
    /// radio streams (`isLive == true`).
    let episodes: [ArtistEpisode]
    /// Playlists curated by this artist (e.g. "Playlists by Lofi Girl").
    let playlistsByArtist: [Playlist]
    /// Related artists from the "Fans might also like" shelf.
    let relatedArtists: [Artist]
    /// Podcast shows the artist owns (`MPSPP…` browseIds).
    let podcasts: [PodcastShow]
    /// Per-shelf "See all" endpoints captured from each `moreContentButton`.
    /// Sparse: shelves without a More button are absent from the map.
    let moreEndpoints: [ArtistShelfKind: ShelfMoreEndpoint]
    let thumbnailURL: URL?
    /// The channel ID for subscription operations (e.g., UCxxxxx).
    let channelId: String?
    /// Whether the user is subscribed to this artist.
    var isSubscribed: Bool
    /// Localized subscriber count text from the API (e.g., "54.5K" or locale-specific equivalent).
    let subscriberCount: String?
    /// Localized button label for the subscribed state.
    let subscribedButtonText: String?
    /// Localized button label for the unsubscribed state.
    let unsubscribedButtonText: String?
    /// Localized monthly audience text from the API (e.g., "2.59M monthly audience").
    let monthlyAudience: String?
    /// Whether there are more songs available beyond what's loaded.
    let hasMoreSongs: Bool
    /// Browse ID for loading all songs (e.g., from "More songs" button).
    let songsBrowseId: String?
    /// Params for loading all songs.
    let songsParams: String?
    /// Playlist ID for Mix (personalized radio), e.g., "RDEM...".
    let mixPlaylistId: String?
    /// Starting video ID for Mix.
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
