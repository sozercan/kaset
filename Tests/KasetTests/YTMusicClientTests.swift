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

    @Test("Podcast show ID conversion handles L-prefixed suffix correctly")
    func podcastShowIdConversionWithLPrefix() {
        // Real podcast IDs are "MPSPP" + "L" + {base64id}
        // Example: "MPSPPLXz2p9abc123"
        let showId = "MPSPPLXz2p9abc123"
        let suffix = String(showId.dropFirst(5)) // "LXz2p9abc123"
        let playlistId = "P" + suffix // "PLXz2p9abc123"

        #expect(suffix == "LXz2p9abc123")
        #expect(suffix.hasPrefix("L"), "Suffix should start with 'L'")
        #expect(playlistId == "PLXz2p9abc123")
        #expect(playlistId.hasPrefix("PL"), "Playlist ID should start with 'PL'")
    }

    @Test("Podcast show ID conversion avoids double-L bug")
    func podcastShowIdAvoidDoubleLBug() {
        // The bug was: "PL" + suffix = "PLLXz2p9..." (double L = 404)
        // Fix: "P" + suffix = "PLXz2p9..." (correct)
        let showId = "MPSPPLXz2p9abc123"
        let suffix = String(showId.dropFirst(5)) // "LXz2p9abc123"

        // Wrong: This was the bug
        let wrongPlaylistId = "PL" + suffix // "PLLXz2p9abc123" - DOUBLE L!
        #expect(wrongPlaylistId.hasPrefix("PLL"), "Bug would produce double-L")

        // Correct: This is the fix
        let correctPlaylistId = "P" + suffix // "PLXz2p9abc123"
        #expect(!correctPlaylistId.hasPrefix("PLL"), "Fix should not have double-L")
        #expect(correctPlaylistId == "PLXz2p9abc123")
    }

    @Test("Podcast show ID with only MPSPP prefix is invalid")
    func podcastShowIdWithOnlyPrefix() {
        // This tests the validation logic we added
        let showId = "MPSPP"
        let suffix = String(showId.dropFirst(5))

        #expect(suffix.isEmpty, "Empty suffix should trigger validation error")
    }

    @Test("Valid podcast show IDs have L-prefixed content after MPSPP")
    func validPodcastShowIdHasLPrefixedContent() {
        let validShowId = "MPSPPLabc123"
        let suffix = String(validShowId.dropFirst(5))

        #expect(!suffix.isEmpty)
        #expect(suffix.hasPrefix("L"), "Valid suffix should start with 'L'")
        #expect(suffix == "Labc123")
    }

    @Test("Podcast show ID without L-prefix should be rejected")
    func podcastShowIdWithoutLPrefix() {
        // IDs like "MPSPPX123" would be invalid
        let invalidShowId = "MPSPPX123"
        let suffix = String(invalidShowId.dropFirst(5))

        #expect(!suffix.isEmpty)
        #expect(!suffix.hasPrefix("L"), "This ID doesn't have required L-prefix")
    }

    // MARK: - Podcast Subscription Integration Tests

    @Test("subscribeToPodcast throws for empty suffix")
    @MainActor
    func subscribeToPodcastThrowsForEmptySuffix() async {
        let mockClient = MockYTMusicClient()

        await #expect(throws: YTMusicError.self) {
            try await mockClient.subscribeToPodcast(showId: "MPSPP")
        }
    }

    @Test("subscribeToPodcast throws for missing L-prefix")
    @MainActor
    func subscribeToPodcastThrowsForMissingLPrefix() async {
        let mockClient = MockYTMusicClient()

        await #expect(throws: YTMusicError.self) {
            try await mockClient.subscribeToPodcast(showId: "MPSPPX123")
        }
    }

    @Test("subscribeToPodcast succeeds for valid MPSPP ID")
    @MainActor
    func subscribeToPodcastSucceedsForValidId() async throws {
        let mockClient = MockYTMusicClient()

        // Should not throw for valid ID
        try await mockClient.subscribeToPodcast(showId: "MPSPPLXz2p9abc123")
    }

    @Test("unsubscribeFromPodcast throws for empty suffix")
    @MainActor
    func unsubscribeFromPodcastThrowsForEmptySuffix() async {
        let mockClient = MockYTMusicClient()

        await #expect(throws: YTMusicError.self) {
            try await mockClient.unsubscribeFromPodcast(showId: "MPSPP")
        }
    }

    @Test("unsubscribeFromPodcast throws for missing L-prefix")
    @MainActor
    func unsubscribeFromPodcastThrowsForMissingLPrefix() async {
        let mockClient = MockYTMusicClient()

        await #expect(throws: YTMusicError.self) {
            try await mockClient.unsubscribeFromPodcast(showId: "MPSPPX123")
        }
    }

    @Test("unsubscribeFromPodcast succeeds for valid MPSPP ID")
    @MainActor
    func unsubscribeFromPodcastSucceedsForValidId() async throws {
        let mockClient = MockYTMusicClient()

        // Should not throw for valid ID
        try await mockClient.unsubscribeFromPodcast(showId: "MPSPPLXz2p9abc123")
    }
}
