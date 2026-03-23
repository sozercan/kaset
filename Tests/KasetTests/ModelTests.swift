import Foundation
import Testing
@testable import Kaset

/// Tests for data models.
@Suite("Models", .tags(.model))
struct ModelTests {
    // MARK: - Song Tests

    @Test("Parses duration from seconds field")
    func songDurationParsingFromSeconds() throws {
        let data: [String: Any] = [
            "videoId": "test123",
            "title": "Test Song",
            "duration_seconds": 185.0,
        ]

        let song = try #require(Song(from: data))
        #expect(song.duration == 185.0)
        #expect(song.durationDisplay == "3:05")
    }

    @Test("Parses duration from string field")
    func songDurationParsingFromString() throws {
        let data: [String: Any] = [
            "videoId": "test123",
            "title": "Test Song",
            "duration": "4:30",
        ]

        let song = try #require(Song(from: data))
        #expect(song.duration == 270.0) // 4 * 60 + 30
    }

    @Test("Parses duration with hours")
    func songDurationParsingHours() throws {
        let data: [String: Any] = [
            "videoId": "test123",
            "title": "Long Song",
            "duration": "1:05:30",
        ]

        let song = try #require(Song(from: data))
        #expect(song.duration == 3930.0) // 1 * 3600 + 5 * 60 + 30
    }

    @Test("Parses multiple artists correctly")
    func songWithMultipleArtists() throws {
        let data: [String: Any] = [
            "videoId": "test123",
            "title": "Collab Song",
            "artists": [
                ["name": "Artist One", "id": "A1"],
                ["name": "Artist Two", "id": "A2"],
                ["name": "Artist Three", "id": "A3"],
            ],
        ]

        let song = try #require(Song(from: data))
        #expect(song.artists.count == 3)
        #expect(song.artistsDisplay == "Artist One, Artist Two, Artist Three")
    }

    @Test("Handles song with no artists")
    func songWithNoArtists() throws {
        let data: [String: Any] = [
            "videoId": "test123",
            "title": "No Artists Song",
        ]

        let song = try #require(Song(from: data))
        #expect(song.artists.isEmpty)
        #expect(song.artistsDisplay.isEmpty)
    }

    @Test("Parses album from song data")
    func songWithAlbum() throws {
        let data: [String: Any] = [
            "videoId": "test123",
            "title": "Album Track",
            "album": [
                "browseId": "album123",
                "title": "Test Album",
            ],
        ]

        let song = try #require(Song(from: data))
        #expect(song.album != nil)
        #expect(song.album?.title == "Test Album")
    }

    @Test("Uses largest thumbnail from array")
    func songWithThumbnails() throws {
        let data: [String: Any] = [
            "videoId": "test123",
            "title": "Thumbnail Song",
            "thumbnails": [
                ["url": "https://example.com/small.jpg", "width": 60, "height": 60],
                ["url": "https://example.com/large.jpg", "width": 400, "height": 400],
            ],
        ]

        let song = try #require(Song(from: data))
        #expect(song.thumbnailURL?.absoluteString == "https://example.com/large.jpg")
    }

    @Test("Uses default title when missing")
    func songDefaultTitle() throws {
        let data: [String: Any] = [
            "videoId": "test123",
        ]

        let song = try #require(Song(from: data))
        #expect(song.title == "Unknown Title")
    }

    @Test("Handles missing duration")
    func songNoDuration() throws {
        let data: [String: Any] = [
            "videoId": "test123",
            "title": "No Duration",
        ]

        let song = try #require(Song(from: data))
        #expect(song.duration == nil)
        #expect(song.durationDisplay == "--:--")
    }

    @Test("Song is Hashable")
    func songHashable() {
        let song1 = Song(
            id: "test",
            title: "Test",
            artists: [],
            album: nil,
            duration: nil,
            thumbnailURL: nil,
            videoId: "test"
        )

        let song2 = Song(
            id: "test",
            title: "Test",
            artists: [],
            album: nil,
            duration: nil,
            thumbnailURL: nil,
            videoId: "test"
        )

        #expect(song1 == song2)

        var set: Set<Song> = []
        set.insert(song1)
        set.insert(song2)
        #expect(set.count == 1)
    }

    // MARK: - Playlist Tests

    @Test(
        "Detects album prefixes correctly",
        arguments: [
            ("OLAK5uy_abc", true),
            ("MPREb_xyz123", true),
            ("PLtest123", false),
        ]
    )
    func playlistIsAlbum(id: String, expectedIsAlbum: Bool) {
        let playlist = Playlist(
            id: id,
            title: "Title",
            description: nil,
            thumbnailURL: nil,
            trackCount: 10,
            author: nil
        )

        #expect(playlist.isAlbum == expectedIsAlbum)
    }

    @Test(
        "Formats track count display correctly",
        arguments: [
            (1, "1 song"),
            (25, "25 songs"),
        ]
    )
    func playlistTrackCountDisplay(count: Int, expected: String) {
        let playlist = Playlist(
            id: "PL1",
            title: "Playlist",
            description: nil,
            thumbnailURL: nil,
            trackCount: count,
            author: nil
        )
        #expect(playlist.trackCountDisplay == expected)
    }

    @Test("Returns empty string for nil track count")
    func playlistTrackCountDisplayNil() {
        let playlist = Playlist(
            id: "PL3",
            title: "No Count",
            description: nil,
            thumbnailURL: nil,
            trackCount: nil,
            author: nil
        )
        #expect(playlist.trackCountDisplay.isEmpty)
    }

    @Test("Parses playlist with browseId")
    func playlistParsingWithBrowseId() throws {
        let data: [String: Any] = [
            "browseId": "browse123",
            "title": "Browse Playlist",
        ]

        let playlist = try #require(Playlist(from: data))
        #expect(playlist.id == "browse123")
    }

    @Test("Parses author from authors array")
    func playlistParsingWithAuthors() throws {
        let data: [String: Any] = [
            "playlistId": "PL123",
            "title": "Authored Playlist",
            "authors": [
                ["name": "Playlist Creator"],
            ],
        ]

        let playlist = try #require(Playlist(from: data))
        #expect(playlist.author == "Playlist Creator")
    }

    @Test("Parses author from string field")
    func playlistParsingWithAuthorString() throws {
        let data: [String: Any] = [
            "playlistId": "PL123",
            "title": "Authored Playlist",
            "author": "Direct Author",
        ]

        let playlist = try #require(Playlist(from: data))
        #expect(playlist.author == "Direct Author")
    }

    @Test("Parses track count from formatted string")
    func playlistParsingTrackCountString() throws {
        let data: [String: Any] = [
            "playlistId": "PL123",
            "title": "Playlist",
            "trackCount": "1,234",
        ]

        let playlist = try #require(Playlist(from: data))
        #expect(playlist.trackCount == 1234)
    }

    @Test("Returns nil for playlist with no ID")
    func playlistWithNoId() {
        let data: [String: Any] = [
            "title": "No ID Playlist",
        ]

        let playlist = Playlist(from: data)
        #expect(playlist == nil)
    }

    // MARK: - PlaylistDetail Tests

    @Test("Creates PlaylistDetail from Playlist")
    func playlistDetailFromPlaylist() {
        let playlist = Playlist(
            id: "PL123",
            title: "Test Playlist",
            description: "A description",
            thumbnailURL: URL(string: "https://example.com/thumb.jpg"),
            trackCount: 5,
            author: "Test Author"
        )

        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
        ]

        let detail = PlaylistDetail(playlist: playlist, tracks: songs, duration: "6:20")

        #expect(detail.id == "PL123")
        #expect(detail.title == "Test Playlist")
        #expect(detail.description == "A description")
        #expect(detail.author == "Test Author")
        #expect(detail.tracks.count == 2)
        #expect(detail.duration == "6:20")
    }

    @Test("PlaylistDetail inherits isAlbum from playlist")
    func playlistDetailIsAlbum() {
        let albumPlaylist = Playlist(
            id: "OLAK5uy_abc",
            title: "Album",
            description: nil,
            thumbnailURL: nil,
            trackCount: 10,
            author: nil
        )

        let detail = PlaylistDetail(playlist: albumPlaylist, tracks: [])
        #expect(detail.isAlbum)
    }

    // MARK: - Album Tests

    @Test("Formats multiple artists display")
    func albumArtistsDisplay() {
        let artists = [
            Artist(id: "a1", name: "Artist A"),
            Artist(id: "a2", name: "Artist B"),
        ]

        let album = Album(
            id: "album1",
            title: "Multi-Artist Album",
            artists: artists,
            thumbnailURL: nil,
            year: "2024",
            trackCount: 12
        )

        #expect(album.artistsDisplay == "Artist A, Artist B")
    }

    @Test("Returns empty string for nil artists")
    func albumNoArtistsDisplay() {
        let album = Album(
            id: "album1",
            title: "No Artist Album",
            artists: nil,
            thumbnailURL: nil,
            year: "2024",
            trackCount: 12
        )

        #expect(album.artistsDisplay.isEmpty)
    }

    @Test("Parses album with albumId")
    func albumParsingWithAlbumId() throws {
        let data: [String: Any] = [
            "albumId": "ALBUM123",
            "title": "Album via albumId",
        ]

        let album = try #require(Album(from: data))
        #expect(album.id == "ALBUM123")
    }

    @Test("Parses album with id field")
    func albumParsingWithId() throws {
        let data: [String: Any] = [
            "id": "ID123",
            "title": "Album via id",
        ]

        let album = try #require(Album(from: data))
        #expect(album.id == "ID123")
    }

    @Test("Parses inline album reference with name only")
    func albumParsingInlineReference() throws {
        let data: [String: Any] = [
            "name": "Referenced Album",
        ]

        let album = try #require(Album(from: data))
        #expect(album.title == "Referenced Album")
        #expect(!album.id.isEmpty)
    }

    @Test("Parses album with artists array")
    func albumParsingWithArtists() throws {
        let data: [String: Any] = [
            "browseId": "ALBUM123",
            "title": "Album with Artists",
            "artists": [
                ["name": "Artist One", "id": "A1"],
            ],
        ]

        let album = try #require(Album(from: data))
        #expect(album.artists?.count == 1)
        #expect(album.artists?.first?.name == "Artist One")
    }

    @Test("Parses year field")
    func albumParsingWithYear() throws {
        let data: [String: Any] = [
            "browseId": "ALBUM123",
            "title": "Album",
            "year": "2023",
        ]

        let album = try #require(Album(from: data))
        #expect(album.year == "2023")
    }

    @Test("Uses default title when missing")
    func albumDefaultTitle() throws {
        let data: [String: Any] = [
            "browseId": "ALBUM123",
        ]

        let album = try #require(Album(from: data))
        #expect(album.title == "Unknown Album")
    }

    @Test("Uses name field as title")
    func albumWithNameAsTitle() throws {
        let data: [String: Any] = [
            "browseId": "ALBUM123",
            "name": "Album Name",
        ]

        let album = try #require(Album(from: data))
        #expect(album.title == "Album Name")
    }

    @Test("Returns nil when no ID or name")
    func albumNoIdOrName() {
        let data: [String: Any] = [
            "someOther": "field",
        ]

        let album = Album(from: data)
        #expect(album == nil)
    }

    // MARK: - Artist Tests

    @Test("Parses artist with thumbnail")
    func artistWithThumbnail() throws {
        let data: [String: Any] = [
            "browseId": "UC123",
            "name": "Artist with Thumb",
            "thumbnails": [
                ["url": "https://example.com/artist.jpg"],
            ],
        ]

        let artist = try #require(Artist(from: data))
        #expect(artist.thumbnailURL?.absoluteString == "https://example.com/artist.jpg")
    }

    @Test("Parses artist with id field")
    func artistWithId() throws {
        let data: [String: Any] = [
            "id": "ID123",
            "name": "Artist via id",
        ]

        let artist = try #require(Artist(from: data))
        #expect(artist.id == "ID123")
    }

    @Test("Parses artist with browseId")
    func artistWithBrowseId() throws {
        let data: [String: Any] = [
            "browseId": "UC456",
            "name": "Artist via browseId",
        ]

        let artist = try #require(Artist(from: data))
        #expect(artist.id == "UC456")
    }

    @Test("Generates UUID for inline artist")
    func artistFallbackId() throws {
        let data: [String: Any] = [
            "name": "Inline Artist",
        ]

        let artist = try #require(Artist(from: data))
        #expect(!artist.id.isEmpty)
    }

    @Test("Uses default name when missing")
    func artistDefaultName() throws {
        let data: [String: Any] = [
            "id": "123",
        ]

        let artist = try #require(Artist(from: data))
        #expect(artist.name == "Unknown Artist")
    }

    @Test("Direct initializer sets all properties")
    func artistInitializer() {
        let artist = Artist(id: "A1", name: "Test Artist", thumbnailURL: URL(string: "https://example.com/a.jpg"))

        #expect(artist.id == "A1")
        #expect(artist.name == "Test Artist")
        #expect(artist.thumbnailURL?.absoluteString == "https://example.com/a.jpg")
    }

    @Test("Artist is Hashable")
    func artistHashable() {
        let artist1 = Artist(id: "A1", name: "Artist")
        let artist2 = Artist(id: "A1", name: "Artist")

        #expect(artist1 == artist2)

        var set: Set<Artist> = []
        set.insert(artist1)
        set.insert(artist2)
        #expect(set.count == 1)
    }

    @Test("hasNavigableId returns true for UC channel IDs")
    func artistHasNavigableIdWithUCPrefix() {
        let artist = Artist(id: "UCxxxxxxxxxxxxxxxxxxxxxxx", name: "Real Artist")
        #expect(artist.hasNavigableId == true)
    }

    @Test("hasNavigableId returns false for SHA256 hash IDs")
    func artistHasNavigableIdWithHashId() {
        // Stable hash IDs generated by ParsingHelpers.stableId() are hex strings
        let artist = Artist(id: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6", name: "Hash Artist")
        #expect(artist.hasNavigableId == false)
    }

    @Test("hasNavigableId returns false for UUID IDs")
    func artistHasNavigableIdWithUUID() {
        let artist = Artist(id: "550e8400-e29b-41d4-a716-446655440000", name: "UUID Artist")
        #expect(artist.hasNavigableId == false)
    }

    @Test("hasNavigableId returns false for empty ID")
    func artistHasNavigableIdEmpty() {
        let artist = Artist(id: "", name: "No ID Artist")
        #expect(artist.hasNavigableId == false)
    }
}
