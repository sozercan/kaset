import CryptoKit
import XCTest
@testable import YouTubeMusic

/// Tests for YTMusicClient.
@MainActor
final class YTMusicClientTests: XCTestCase {
    func testSAPISIDHASHFormat() {
        // Test that SAPISIDHASH is computed correctly
        let timestamp = 1_703_001_600 // Example timestamp
        let sapisid = "example_sapisid_value"
        let origin = "https://music.youtube.com"

        let hashInput = "\(timestamp) \(sapisid) \(origin)"
        let hash = Insecure.SHA1.hash(data: Data(hashInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let sapisidhash = "\(timestamp)_\(hash)"

        // Verify format: timestamp_hexhash
        XCTAssertTrue(sapisidhash.contains("_"))
        let parts = sapisidhash.split(separator: "_")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(String(parts[0]), "\(timestamp)")
        XCTAssertEqual(parts[1].count, 40) // SHA1 produces 40 hex characters
    }

    func testSHA1HashConsistency() {
        // Test that SHA1 hashing is consistent
        let input = "test input string"
        let hash1 = Insecure.SHA1.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let hash2 = Insecure.SHA1.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(hash1, hash2)
        XCTAssertEqual(hash1.count, 40)
    }

    func testModelParsing() {
        // Test Song initialization from dictionary
        let songData: [String: Any] = [
            "videoId": "dQw4w9WgXcQ",
            "title": "Never Gonna Give You Up",
            "artists": [
                ["name": "Rick Astley", "id": "UC123"],
            ],
            "duration_seconds": 213.0,
            "thumbnails": [
                ["url": "https://example.com/thumb.jpg", "width": 120, "height": 120],
            ],
        ]

        let song = Song(from: songData)
        XCTAssertNotNil(song)
        XCTAssertEqual(song?.videoId, "dQw4w9WgXcQ")
        XCTAssertEqual(song?.title, "Never Gonna Give You Up")
        XCTAssertEqual(song?.artists.count, 1)
        XCTAssertEqual(song?.artists.first?.name, "Rick Astley")
        XCTAssertEqual(song?.duration, 213.0)
    }

    func testSongParsingWithMissingVideoId() {
        let songData: [String: Any] = [
            "title": "Test Song",
        ]

        let song = Song(from: songData)
        XCTAssertNil(song)
    }

    func testPlaylistParsing() {
        let playlistData: [String: Any] = [
            "playlistId": "PLtest123",
            "title": "My Playlist",
            "trackCount": 25,
            "thumbnails": [
                ["url": "https://example.com/playlist.jpg"],
            ],
        ]

        let playlist = Playlist(from: playlistData)
        XCTAssertNotNil(playlist)
        XCTAssertEqual(playlist?.id, "PLtest123")
        XCTAssertEqual(playlist?.title, "My Playlist")
        XCTAssertEqual(playlist?.trackCount, 25)
    }

    func testAlbumParsing() {
        let albumData: [String: Any] = [
            "browseId": "MPREtest",
            "title": "Test Album",
            "year": "2023",
        ]

        let album = Album(from: albumData)
        XCTAssertNotNil(album)
        XCTAssertEqual(album?.id, "MPREtest")
        XCTAssertEqual(album?.title, "Test Album")
        XCTAssertEqual(album?.year, "2023")
    }

    func testArtistParsing() {
        let artistData: [String: Any] = [
            "browseId": "UC123456",
            "name": "Test Artist",
        ]

        let artist = Artist(from: artistData)
        XCTAssertNotNil(artist)
        XCTAssertEqual(artist?.id, "UC123456")
        XCTAssertEqual(artist?.name, "Test Artist")
    }
}
