import Foundation

// MARK: - LibraryParams

/// Common params values discovered from web client observation.
/// These are base64-encoded protobuf that specify sorting/filtering options.
enum LibraryParams: String, CaseIterable, Sendable {
    // Recent activity
    case recentlyAdded = "ggMGKgQIARAA" // Sort by recently added
    case recentlyPlayed = "ggMGKgQIAhAA" // Sort by recently played
    case alphabeticalAZ = "ggMGKgQIAxAA" // Sort A-Z
    case alphabeticalZA = "ggMGKgQIBBAA" // Sort Z-A

    // Alternative formats observed
    case albumsRecent = "ggMIARAAGgYIAhAA"
    case albumsAZ = "ggMIARABGgYIAhAA"
    case songsRecent = "ggMIARoCCAE"
    case artistsRecent = "ggMIARoCCAI"

    // Minimal params (just sort order)
    case defaultSort = "ggMCCAE"
    case altSort = "ggMCCAI"

    var description: String {
        switch self {
        case .recentlyAdded: "Recently Added"
        case .recentlyPlayed: "Recently Played"
        case .alphabeticalAZ: "A-Z"
        case .alphabeticalZA: "Z-A"
        case .albumsRecent: "Albums Recent (alt)"
        case .albumsAZ: "Albums A-Z (alt)"
        case .songsRecent: "Songs Recent (alt)"
        case .artistsRecent: "Artists Recent (alt)"
        case .defaultSort: "Default Sort"
        case .altSort: "Alt Sort"
        }
    }
}

// MARK: - Endpoint Configuration

extension APIExplorer {
    /// Configuration for an endpoint to explore
    struct EndpointConfig: Sendable {
        let id: String
        let name: String
        let description: String
        let requiresAuth: Bool
        let isImplemented: Bool
        let notes: String?

        init(
            id: String,
            name: String,
            description: String,
            requiresAuth: Bool = false,
            isImplemented: Bool = false,
            notes: String? = nil
        ) {
            self.id = id
            self.name = name
            self.description = description
            self.requiresAuth = requiresAuth
            self.isImplemented = isImplemented
            self.notes = notes
        }
    }

    // MARK: - Known Browse Endpoints Registry

    /// All known browse endpoints for YouTube Music.
    /// This registry serves as the source of truth for available endpoints.
    static let browseEndpoints: [EndpointConfig] = [
        // MARK: - Implemented Endpoints

        EndpointConfig(
            id: "FEmusic_home",
            name: "Home",
            description: "Main home feed with personalized recommendations",
            requiresAuth: false,
            isImplemented: true,
            notes: "Supports continuation"
        ),
        EndpointConfig(
            id: "FEmusic_explore",
            name: "Explore",
            description: "Explore page with new releases and charts",
            requiresAuth: false,
            isImplemented: true,
            notes: "Supports continuation"
        ),
        EndpointConfig(
            id: "FEmusic_liked_playlists",
            name: "Library Playlists",
            description: "User's saved/created playlists",
            requiresAuth: true,
            isImplemented: true
        ),
        EndpointConfig(
            id: "FEmusic_liked_videos",
            name: "Liked Songs",
            description: "Songs the user has liked",
            requiresAuth: true,
            isImplemented: true,
            notes: "Returns as playlist detail format"
        ),

        // MARK: - Available (Not Implemented)

        EndpointConfig(
            id: "FEmusic_charts",
            name: "Charts",
            description: "Top songs, albums, trending charts",
            requiresAuth: false,
            notes: "High priority"
        ),
        EndpointConfig(
            id: "FEmusic_moods_and_genres",
            name: "Moods & Genres",
            description: "Browse by mood or genre",
            requiresAuth: false,
            notes: "Returns grid sections"
        ),
        EndpointConfig(
            id: "FEmusic_new_releases",
            name: "New Releases",
            description: "Recently released music",
            requiresAuth: false
        ),
        EndpointConfig(
            id: "FEmusic_podcasts",
            name: "Podcasts",
            description: "Podcast discovery",
            requiresAuth: false,
            notes: "Lower priority"
        ),
        EndpointConfig(
            id: "FEmusic_history",
            name: "History",
            description: "Listening history",
            requiresAuth: true,
            notes: "High priority"
        ),
        EndpointConfig(
            id: "FEmusic_library_landing",
            name: "Library Landing",
            description: "Library overview",
            requiresAuth: true,
            notes: "Returns login prompt without auth"
        ),
        EndpointConfig(
            id: "FEmusic_library_albums",
            name: "Library Albums",
            description: "Saved albums",
            requiresAuth: true,
            notes: "Needs auth + params"
        ),
        EndpointConfig(
            id: "FEmusic_library_artists",
            name: "Library Artists",
            description: "Followed artists",
            requiresAuth: true,
            notes: "Needs auth + params"
        ),
        EndpointConfig(
            id: "FEmusic_library_songs",
            name: "Library Songs",
            description: "All songs in library",
            requiresAuth: true,
            notes: "Needs auth + params"
        ),
        EndpointConfig(
            id: "FEmusic_recently_played",
            name: "Recently Played",
            description: "Recent content",
            requiresAuth: true,
            notes: "May overlap with history"
        ),
        EndpointConfig(
            id: "FEmusic_offline",
            name: "Downloads",
            description: "Offline content",
            requiresAuth: true,
            notes: "May not be supported on desktop"
        ),
        EndpointConfig(
            id: "FEmusic_library_privately_owned_landing",
            name: "Uploads Landing",
            description: "User uploads landing",
            requiresAuth: true
        ),
        EndpointConfig(
            id: "FEmusic_library_privately_owned_tracks",
            name: "Uploaded Tracks",
            description: "User-uploaded songs",
            requiresAuth: true
        ),
        EndpointConfig(
            id: "FEmusic_library_privately_owned_albums",
            name: "Uploaded Albums",
            description: "User-uploaded albums",
            requiresAuth: true
        ),
        EndpointConfig(
            id: "FEmusic_library_privately_owned_artists",
            name: "Uploaded Artists",
            description: "Artists from uploads",
            requiresAuth: true
        ),
    ]

    // MARK: - Known Action Endpoints Registry

    /// All known action endpoints for YouTube Music.
    static let actionEndpoints: [EndpointConfig] = [
        // MARK: - Implemented

        EndpointConfig(
            id: "search",
            name: "Search",
            description: "Search for content",
            requiresAuth: false,
            isImplemented: true
        ),
        EndpointConfig(
            id: "music/get_search_suggestions",
            name: "Search Suggestions",
            description: "Autocomplete suggestions",
            requiresAuth: false,
            isImplemented: true
        ),
        EndpointConfig(
            id: "next",
            name: "Next / Now Playing",
            description: "Track info, lyrics, related",
            requiresAuth: false,
            isImplemented: true,
            notes: "Used for lyrics and radio queue"
        ),
        EndpointConfig(
            id: "like/like",
            name: "Like",
            description: "Like content",
            requiresAuth: true,
            isImplemented: true
        ),
        EndpointConfig(
            id: "like/dislike",
            name: "Dislike",
            description: "Dislike a song",
            requiresAuth: true,
            isImplemented: true
        ),
        EndpointConfig(
            id: "like/removelike",
            name: "Remove Like",
            description: "Remove rating",
            requiresAuth: true,
            isImplemented: true
        ),
        EndpointConfig(
            id: "feedback",
            name: "Feedback",
            description: "Library add/remove",
            requiresAuth: true,
            isImplemented: true
        ),
        EndpointConfig(
            id: "subscription/subscribe",
            name: "Subscribe",
            description: "Subscribe to artist",
            requiresAuth: true,
            isImplemented: true
        ),
        EndpointConfig(
            id: "subscription/unsubscribe",
            name: "Unsubscribe",
            description: "Unsubscribe from artist",
            requiresAuth: true,
            isImplemented: true
        ),

        // MARK: - Available (Not Implemented)

        EndpointConfig(
            id: "player",
            name: "Player",
            description: "Video details, streaming formats",
            requiresAuth: false,
            notes: "Returns videoDetails, streamingData"
        ),
        EndpointConfig(
            id: "music/get_queue",
            name: "Get Queue",
            description: "Queue data for videos",
            requiresAuth: false,
            notes: "Returns queueDatas"
        ),
        EndpointConfig(
            id: "playlist/get_add_to_playlist",
            name: "Get Add to Playlist",
            description: "Playlists for add menu",
            requiresAuth: true,
            notes: "Returns HTTP 401 without auth"
        ),
        EndpointConfig(
            id: "browse/edit_playlist",
            name: "Edit Playlist",
            description: "Add/remove tracks",
            requiresAuth: true,
            notes: "Returns HTTP 401 without auth"
        ),
        EndpointConfig(
            id: "playlist/create",
            name: "Create Playlist",
            description: "Create new playlist",
            requiresAuth: true,
            notes: "Returns HTTP 401 without auth"
        ),
        EndpointConfig(
            id: "playlist/delete",
            name: "Delete Playlist",
            description: "Delete a playlist",
            requiresAuth: true
        ),
        EndpointConfig(
            id: "guide",
            name: "Guide",
            description: "Sidebar navigation",
            requiresAuth: false,
            notes: "Low priority"
        ),
        EndpointConfig(
            id: "account/account_menu",
            name: "Account Menu",
            description: "Account settings",
            requiresAuth: true
        ),
        EndpointConfig(
            id: "notification/get_notification_menu",
            name: "Notifications",
            description: "User notifications",
            requiresAuth: true
        ),
        EndpointConfig(
            id: "stats/watchtime",
            name: "Watch Time",
            description: "Listening statistics",
            requiresAuth: true
        ),
    ]
}
