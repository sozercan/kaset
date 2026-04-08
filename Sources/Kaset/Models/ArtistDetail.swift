import Foundation

// MARK: - AlbumCarouselSection

struct AlbumCarouselSection: Identifiable, Hashable {
    let title: String
    let albums: [Album]

    var id: String {
        self.title
    }
}

// MARK: - ArtistCarouselSection

struct ArtistCarouselSection: Identifiable, Hashable {
    let title: String
    let artists: [Artist]

    var id: String {
        self.title
    }
}

// MARK: - PlaylistCarouselSection

struct PlaylistCarouselSection: Identifiable, Hashable {
    let title: String
    let playlists: [Playlist]

    var id: String {
        self.title
    }
}

// MARK: - ArtistDetail

/// Contains detailed artist information including their songs.
struct ArtistDetail {
    let artist: Artist
    let description: String?
    let songs: [Song]
    let albumSections: [AlbumCarouselSection]
    let playlistSections: [PlaylistCarouselSection]
    let artistSections: [ArtistCarouselSection]
    let thumbnailURL: URL?
    /// The channel ID for subscription operations (e.g., UCxxxxx).
    let channelId: String?
    /// Whether the user is subscribed to this artist.
    var isSubscribed: Bool
    /// Subscriber count text (e.g., "34.6M subscribers").
    let subscriberCount: String?
    /// Monthly audience count text (e.g., "2.59M").
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

    func audienceSubtitle(languageCode: String) -> String? {
        if let monthlyAudience = self.monthlyAudience,
           let formattedMonthlyAudience = AudienceTextFormatter.formatMonthlyAudience(monthlyAudience, languageCode: languageCode)
        {
            return formattedMonthlyAudience
        }

        return nil
    }

    func formattedSubscriberCount(languageCode: String) -> String? {
        guard let subscriberCount = self.subscriberCount else { return nil }
        return AudienceTextFormatter.formatSubscriberCount(subscriberCount, languageCode: languageCode)
    }

    init(
        artist: Artist,
        description: String?,
        songs: [Song],
        albumSections: [AlbumCarouselSection] = [],
        playlistSections: [PlaylistCarouselSection] = [],
        artistSections: [ArtistCarouselSection] = [],
        thumbnailURL: URL?,
        channelId: String? = nil,
        isSubscribed: Bool = false,
        subscriberCount: String? = nil,
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
        self.albumSections = albumSections
        self.playlistSections = playlistSections
        self.artistSections = artistSections
        self.thumbnailURL = thumbnailURL
        self.channelId = channelId
        self.isSubscribed = isSubscribed
        self.subscriberCount = subscriberCount
        self.monthlyAudience = monthlyAudience
        self.hasMoreSongs = hasMoreSongs
        self.songsBrowseId = songsBrowseId
        self.songsParams = songsParams
        self.mixPlaylistId = mixPlaylistId
        self.mixVideoId = mixVideoId
    }
}
