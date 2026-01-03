import Foundation

// MARK: - ArtistDetail

/// Contains detailed artist information including their songs.
struct ArtistDetail: Sendable {
    let artist: Artist
    let description: String?
    let songs: [Song]
    let albums: [Album]
    let thumbnailURL: URL?
    /// The channel ID for subscription operations (e.g., UCxxxxx).
    let channelId: String?
    /// Whether the user is subscribed to this artist.
    var isSubscribed: Bool
    /// Subscriber count text (e.g., "34.6M subscribers").
    let subscriberCount: String?
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

    var id: String { self.artist.id }
    var name: String { self.artist.name }

    init(
        artist: Artist,
        description: String?,
        songs: [Song],
        albums: [Album],
        thumbnailURL: URL?,
        channelId: String? = nil,
        isSubscribed: Bool = false,
        subscriberCount: String? = nil,
        hasMoreSongs: Bool = false,
        songsBrowseId: String? = nil,
        songsParams: String? = nil,
        mixPlaylistId: String? = nil,
        mixVideoId: String? = nil
    ) {
        self.artist = artist
        self.description = description
        self.songs = songs
        self.albums = albums
        self.thumbnailURL = thumbnailURL
        self.channelId = channelId
        self.isSubscribed = isSubscribed
        self.subscriberCount = subscriberCount
        self.hasMoreSongs = hasMoreSongs
        self.songsBrowseId = songsBrowseId
        self.songsParams = songsParams
        self.mixPlaylistId = mixPlaylistId
        self.mixVideoId = mixVideoId
    }
}
