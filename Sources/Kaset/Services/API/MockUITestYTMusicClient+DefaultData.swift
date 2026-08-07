import Foundation

// MARK: - Mock UI-Test Default Data

extension MockUITestYTMusicClient {
    // MARK: - Default Data

    static func defaultHomeSections() -> [HomeSection] {
        [
            HomeSection(
                id: "quick-picks",
                title: "Quick picks",
                items: self.defaultSongs(count: 8).map { .song($0) }
            ),
            HomeSection(
                id: "listen-again",
                title: "Listen again",
                items: self.defaultSongs(count: 6).map { .song($0) }
            ),
            HomeSection(
                id: "recommended",
                title: "Recommended",
                items: self.defaultSongs(count: 10).map { .song($0) }
            ),
        ]
    }

    static func defaultSearchResults() -> SearchResponse {
        let podcastShow = PodcastShow(
            id: "MPSPPMockSearchShow",
            title: "Search Podcast",
            author: "Podcast Host",
            description: "A representative podcast search result",
            thumbnailURL: nil,
            episodeCount: 24
        )

        return SearchResponse(
            songs: self.defaultSongs(count: 5),
            videos: [
                Song(
                    id: "search-video-result",
                    title: "Search Video",
                    artists: [Artist(id: "UCSearchVideoArtist", name: "Video Artist")],
                    thumbnailURL: nil,
                    videoId: "search-video-result",
                    hasVideo: true,
                    musicVideoType: .omv
                ),
            ],
            albums: self.defaultAlbums(count: 2),
            audiobooks: [
                Album(
                    id: "MPREbMockAudiobook",
                    title: "Search Audiobook",
                    artists: [Artist.inline(name: "Audiobook Author", namespace: "mock-search-audiobook")],
                    thumbnailURL: nil,
                    year: "2026",
                    trackCount: 18
                ),
            ],
            artists: [
                Artist(id: "artist-1", name: "Search Artist 1", thumbnailURL: nil),
                Artist(id: "artist-2", name: "Search Artist 2", thumbnailURL: nil),
            ],
            profiles: [
                Artist(
                    id: "UCMockSearchProfile",
                    name: "Search Profile",
                    thumbnailURL: nil,
                    subtitle: "@searchprofile",
                    profileKind: .profile
                ),
            ],
            playlists: self.defaultPlaylists(),
            podcastShows: [podcastShow],
            podcastEpisodes: [
                PodcastEpisode(
                    id: "mock-search-episode",
                    title: "Search Podcast Episode",
                    showTitle: podcastShow.title,
                    showBrowseId: podcastShow.id,
                    description: "A representative podcast episode search result",
                    thumbnailURL: nil,
                    publishedDate: "Jul 19, 2026",
                    duration: "32 min",
                    durationSeconds: 1920,
                    playbackProgress: 0,
                    isPlayed: false
                ),
            ]
        )
    }

    static func defaultPlaylists() -> [Playlist] {
        (0 ..< 5).map { index in
            Playlist(
                id: "playlist-\(index)",
                title: "My Playlist \(index + 1)",
                description: "A great playlist",
                thumbnailURL: nil,
                trackCount: 10 + index * 5,
                author: Artist.inline(name: "Test User", namespace: "playlist-author")
            )
        }
    }

    static func defaultLikedSongs() -> [Song] {
        self.defaultSongs(count: 20)
    }

    static func defaultSongs(count: Int) -> [Song] {
        (0 ..< count).map { index in
            Song(
                id: "song-\(index)",
                title: "Test Song \(index + 1)",
                artists: [Artist(id: "artist-\(index % 3)", name: "Artist \(index % 3 + 1)")],
                album: Album(
                    id: "album-\(index % 5)",
                    title: "Album \(index % 5 + 1)",
                    artists: nil,
                    thumbnailURL: nil,
                    year: "2024",
                    trackCount: 12
                ),
                duration: TimeInterval(180 + index * 10),
                thumbnailURL: nil,
                videoId: "video-\(index)"
            )
        }
    }

    static func defaultAlbums(count: Int) -> [Album] {
        (0 ..< count).map { index in
            Album(
                id: "album-\(index)",
                title: "Test Album \(index + 1)",
                artists: [Artist(id: "artist-\(index)", name: "Album Artist \(index + 1)")],
                thumbnailURL: nil,
                year: "2024",
                trackCount: 10 + index
            )
        }
    }
}
