import Foundation
@testable import Kaset

/// Provides test fixtures for unit tests.
enum TestFixtures {
    // MARK: - Songs

    static func makeSong(
        id: String = "test-video-id",
        title: String = "Test Song",
        artistName: String = "Test Artist",
        artistId: String = "UC123",
        duration: TimeInterval? = 180
    ) -> Song {
        Song(
            id: id,
            title: title,
            artists: [Artist(id: artistId, name: artistName)],
            album: nil,
            duration: duration,
            thumbnailURL: URL(string: "https://example.com/thumb.jpg"),
            videoId: id
        )
    }

    static func makeSongs(count: Int) -> [Song] {
        (0 ..< count).map { index in
            self.makeSong(
                id: "video-\(index)",
                title: "Song \(index)",
                artistName: "Artist \(index)",
                artistId: "UC\(index)"
            )
        }
    }

    // MARK: - Albums

    static func makeAlbum(
        id: String = "MPRE-test-album",
        title: String = "Test Album",
        artistName: String = "Test Artist",
        year: String? = "2024"
    ) -> Album {
        Album(
            id: id,
            title: title,
            artists: artistName.isEmpty ? nil : [Artist(id: "UC123", name: artistName)],
            thumbnailURL: URL(string: "https://example.com/album.jpg"),
            year: year,
            trackCount: 12
        )
    }

    // MARK: - Artists

    static func makeArtist(
        id: String = "UC123",
        name: String = "Test Artist"
    ) -> Artist {
        Artist(
            id: id,
            name: name,
            thumbnailURL: URL(string: "https://example.com/artist.jpg")
        )
    }

    // MARK: - Playlists

    static func makePlaylist(
        id: String = "VL-test-playlist",
        title: String = "Test Playlist",
        author: String? = "Test User"
    ) -> Playlist {
        Playlist(
            id: id,
            title: title,
            description: "A test playlist",
            thumbnailURL: URL(string: "https://example.com/playlist.jpg"),
            trackCount: 25,
            author: author
        )
    }

    static func makePlaylistDetail(
        playlist: Playlist? = nil,
        trackCount: Int = 10
    ) -> PlaylistDetail {
        let pl = playlist ?? self.makePlaylist()
        return PlaylistDetail(
            playlist: pl,
            tracks: self.makeSongs(count: trackCount),
            duration: "\(trackCount * 3) minutes"
        )
    }

    // MARK: - Artist Details

    static func makeArtistDetail(
        artist: Artist? = nil,
        songCount: Int = 5,
        albumCount: Int = 3
    ) -> ArtistDetail {
        let a = artist ?? self.makeArtist()
        return ArtistDetail(
            artist: a,
            description: "A test artist description",
            songs: self.makeSongs(count: songCount),
            albums: (0 ..< albumCount).map { index in
                self.makeAlbum(id: "MPRE-\(index)", title: "Album \(index)")
            },
            thumbnailURL: a.thumbnailURL
        )
    }

    // MARK: - Home Sections

    static func makeHomeSection(
        id: String = UUID().uuidString,
        title: String = "Test Section",
        itemCount: Int = 5,
        isChart: Bool = false
    ) -> HomeSection {
        HomeSection(
            id: id,
            title: title,
            items: self.makeSongs(count: itemCount).map { .song($0) },
            isChart: isChart
        )
    }

    static func makeHomeResponse(sectionCount: Int = 3) -> HomeResponse {
        HomeResponse(
            sections: (0 ..< sectionCount).map { index in
                self.makeHomeSection(
                    id: "section-\(index)",
                    title: "Section \(index)"
                )
            }
        )
    }

    // MARK: - Search Response

    static func makeSearchResponse(
        songCount: Int = 5,
        albumCount: Int = 2,
        artistCount: Int = 2,
        playlistCount: Int = 2
    ) -> SearchResponse {
        SearchResponse(
            songs: self.makeSongs(count: songCount),
            albums: (0 ..< albumCount).map { index in
                self.makeAlbum(id: "MPRE-search-\(index)", title: "Search Album \(index)")
            },
            artists: (0 ..< artistCount).map { index in
                self.makeArtist(id: "UC-search-\(index)", name: "Search Artist \(index)")
            },
            playlists: (0 ..< playlistCount).map { index in
                self.makePlaylist(id: "VL-search-\(index)", title: "Search Playlist \(index)")
            }
        )
    }

    // MARK: - Podcasts

    static func makePodcastShow(
        id: String = "MPSPPLXz2p9test123",
        title: String = "Test Podcast",
        author: String? = "Test Host"
    ) -> PodcastShow {
        PodcastShow(
            id: id,
            title: title,
            author: author,
            description: "A test podcast show",
            thumbnailURL: URL(string: "https://example.com/podcast.jpg"),
            episodeCount: 50
        )
    }
}
