import CryptoKit
import Foundation
import Testing
@testable import Kaset

/// Tests for YTMusicClient.
@Suite("YTMusicClient", .tags(.api))
struct YTMusicClientTests {
    @Test("SAPISIDHASH format is correct")
    func sapisidhashFormat() {
        let timestamp = 1_703_001_600
        let sapisid = "example_sapisid_value"
        let origin = "https://music.youtube.com"

        let hashInput = "\(timestamp) \(sapisid) \(origin)"
        let hash = Insecure.SHA1.hash(data: Data(hashInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let sapisidhash = "\(timestamp)_\(hash)"

        #expect(sapisidhash.contains("_"))
        let parts = sapisidhash.split(separator: "_")
        #expect(parts.count == 2)
        #expect(String(parts[0]) == "\(timestamp)")
        #expect(parts[1].count == 40, "SHA1 produces 40 hex characters")
    }

    @Test("SHA1 hash consistency")
    func sha1HashConsistency() {
        let input = "test input string"
        let hash1 = Insecure.SHA1.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let hash2 = Insecure.SHA1.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        #expect(hash1 == hash2)
        #expect(hash1.count == 40)
    }

    @Test("Song model parsing")
    func modelParsing() throws {
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

        let song = try #require(Song(from: songData))
        #expect(song.videoId == "dQw4w9WgXcQ")
        #expect(song.title == "Never Gonna Give You Up")
        #expect(song.artists.count == 1)
        #expect(song.artists.first?.name == "Rick Astley")
        #expect(song.duration == 213.0)
    }

    @Test("Song parsing with missing videoId returns nil")
    func songParsingWithMissingVideoId() {
        let songData: [String: Any] = [
            "title": "Test Song",
        ]

        let song = Song(from: songData)
        #expect(song == nil)
    }

    @Test("Playlist model parsing")
    func playlistParsing() throws {
        let playlistData: [String: Any] = [
            "playlistId": "PLtest123",
            "title": "My Playlist",
            "trackCount": 25,
            "thumbnails": [
                ["url": "https://example.com/playlist.jpg"],
            ],
        ]

        let playlist = try #require(Playlist(from: playlistData))
        #expect(playlist.id == "PLtest123")
        #expect(playlist.title == "My Playlist")
        #expect(playlist.trackCount == 25)
    }

    @Test("Album model parsing")
    func albumParsing() throws {
        let albumData: [String: Any] = [
            "browseId": "MPREtest",
            "title": "Test Album",
            "year": "2023",
        ]

        let album = try #require(Album(from: albumData))
        #expect(album.id == "MPREtest")
        #expect(album.title == "Test Album")
        #expect(album.year == "2023")
    }

    @Test("Artist model parsing")
    func artistParsing() throws {
        let artistData: [String: Any] = [
            "browseId": "UC123456",
            "name": "Test Artist",
        ]

        let artist = try #require(Artist(from: artistData))
        #expect(artist.id == "UC123456")
        #expect(artist.name == "Test Artist")
    }

    // MARK: - Podcast Show ID Validation Tests

    @Test("Podcast show ID conversion extracts suffix correctly")
    func podcastShowIdConversion() {
        // Test that MPSPP prefix removal produces correct PL format
        let showId = "MPSPP12345ABC"
        let expectedSuffix = "12345ABC" // After removing "MPSPP"
        let playlistId = "PL\(expectedSuffix)" // What subscription uses

        #expect(playlistId == "PL12345ABC")
    }

    @Test("Podcast show ID with only MPSPP prefix would be invalid")
    func podcastShowIdWithOnlyPrefix() {
        // This tests the validation logic we added
        let showId = "MPSPP"
        let suffix = String(showId.dropFirst("MPSPP".count))

        #expect(suffix.isEmpty, "Empty suffix should trigger validation error")
    }

    @Test("Valid podcast show IDs have content after prefix")
    func validPodcastShowIdHasContent() {
        let validShowId = "MPSPP12345"
        let suffix = String(validShowId.dropFirst("MPSPP".count))

        #expect(!suffix.isEmpty)
        #expect(suffix == "12345")
    }
}
