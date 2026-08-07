import Foundation
import Testing
@testable import Kaset

@Suite("Mock UI-test YouTube Music search configuration", .serialized)
struct MockUITestYTMusicClientSearchTests {
    @Test("Legacy grouped search schema supports every semantic family")
    @MainActor
    func groupedSchemaSupportsEverySemanticFamily() async throws {
        let payload: [String: Any] = [
            "songs": [[
                "id": "song-1",
                "title": "Configured Song",
                "artist": "Song Artist",
                "videoId": "song-video-1",
                "albumId": "MPREbConfiguredAlbum",
                "albumTitle": "Configured Song Album",
            ]],
            "videos": [[
                "id": "video-1",
                "title": "Configured Video",
                "artist": "Video Artist",
                "videoId": "video-id-1",
                "musicVideoType": "MUSIC_VIDEO_TYPE_OMV",
            ]],
            "albums": [[
                "id": "MPREbAlbum1",
                "title": "Configured Album",
                "artist": "Album Artist",
                "year": "2026",
                "trackCount": 12,
            ]],
            "audiobooks": [[
                "id": "MPREbAudiobook1",
                "title": "Configured Audiobook",
                "artist": "Audiobook Author",
                "year": "2025",
            ]],
            "artists": [[
                "id": "UCArtist1",
                "name": "Configured Artist",
                "subtitle": "Artist subtitle",
            ]],
            "profiles": [[
                "id": "UCProfile1",
                "name": "Configured Profile",
                "subtitle": "Profile subtitle",
            ]],
            "playlists": [[
                "id": "VLPlaylist1",
                "title": "Configured Playlist",
                "description": "Playlist description",
                "trackCount": 24,
                "author": "Playlist Author",
            ]],
            "podcastShows": [[
                "id": "MPSPPShow1",
                "title": "Configured Podcast",
                "author": "Podcast Host",
                "description": "Show description",
                "episodeCount": 40,
            ]],
            "podcastEpisodes": [[
                "id": "episode-video-1",
                "title": "Configured Episode",
                "showTitle": "Configured Podcast",
                "showBrowseId": "MPSPPShow1",
                "publishedDate": "Jul 19, 2026",
                "duration": "42 min",
                "durationSeconds": 2520,
                "playbackProgress": 0.25,
                "isPlayed": false,
            ]],
        ]

        try await self.withMockSearchResults(payload) { client in
            let response = try await client.search(query: "configured")

            #expect(response.songs.map(\.title) == ["Configured Song"])
            #expect(response.songs.first?.album?.title == "Configured Song Album")
            #expect(response.videos.map(\.title) == ["Configured Video"])
            #expect(response.videos.first?.musicVideoType == .omv)
            #expect(response.albums.map(\.title) == ["Configured Album"])
            #expect(response.audiobooks.map(\.title) == ["Configured Audiobook"])
            #expect(response.artists.map(\.name) == ["Configured Artist"])
            #expect(response.profiles.map(\.name) == ["Configured Profile"])
            #expect(response.profiles.first?.profileKind == .profile)
            #expect(response.playlists.map(\.title) == ["Configured Playlist"])
            #expect(response.podcastShows.map(\.title) == ["Configured Podcast"])
            #expect(response.podcastEpisodes.map(\.title) == ["Configured Episode"])
        }
    }

    @Test("Explicit items preserve mixed semantic order")
    @MainActor
    func explicitItemsPreserveMixedSemanticOrder() async throws {
        let payload: [String: Any] = [
            "items": [
                [
                    "type": "profile",
                    "id": "UCProfileFirst",
                    "name": "First Profile",
                ],
                [
                    "type": "podcastEpisode",
                    "id": "episode-second",
                    "title": "Second Episode",
                    "showTitle": "Ordered Show",
                ],
                [
                    "type": "video",
                    "id": "video-third",
                    "title": "Third Video",
                    "artist": "Ordered Artist",
                    "videoId": "video-third",
                ],
                [
                    "type": "audiobook",
                    "id": "MPREbFourth",
                    "title": "Fourth Audiobook",
                    "artist": "Ordered Author",
                ],
                [
                    "type": "song",
                    "id": "song-fifth",
                    "title": "Fifth Song",
                    "artist": "Ordered Artist",
                    "videoId": "song-fifth",
                ],
            ],
            "songs": [[
                "id": "grouped-song",
                "title": "Grouped Song Should Not Be Appended",
                "artist": "Grouped Artist",
                "videoId": "grouped-song",
            ]],
        ]

        try await self.withMockSearchResults(payload) { client in
            let response = try await client.search(query: "ordered")

            #expect(response.allItems.map(\.title) == [
                "First Profile",
                "Second Episode",
                "Third Video",
                "Fourth Audiobook",
                "Fifth Song",
            ])
            #expect(response.songs.map(\.title) == ["Fifth Song"])
        }
    }

    @Test("Default search data covers every semantic family")
    @MainActor
    func defaultSearchDataCoversEverySemanticFamily() async throws {
        try await self.withoutConfiguredMockSearchResults { client in
            let response = try await client.search(query: "default")

            #expect(!response.songs.isEmpty)
            #expect(!response.videos.isEmpty)
            #expect(!response.albums.isEmpty)
            #expect(!response.audiobooks.isEmpty)
            #expect(!response.artists.isEmpty)
            #expect(!response.profiles.isEmpty)
            #expect(!response.playlists.isEmpty)
            #expect(!response.podcastShows.isEmpty)
            #expect(!response.podcastEpisodes.isEmpty)
        }
    }

    @MainActor
    private func withMockSearchResults(
        _ payload: [String: Any],
        operation: @MainActor (MockUITestYTMusicClient) async throws -> Void
    ) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = try #require(String(data: data, encoding: .utf8))
        try await self.withEnvironmentValue(json, operation: operation)
    }

    @MainActor
    private func withoutConfiguredMockSearchResults(
        operation: @MainActor (MockUITestYTMusicClient) async throws -> Void
    ) async throws {
        try await self.withEnvironmentValue(nil, operation: operation)
    }

    @MainActor
    private func withEnvironmentValue(
        _ value: String?,
        operation: @MainActor (MockUITestYTMusicClient) async throws -> Void
    ) async throws {
        let key = UITestConfig.mockSearchResultsKey
        let previousValue = ProcessInfo.processInfo.environment[key]
        defer {
            if let previousValue {
                setenv(key, previousValue, 1)
            } else {
                unsetenv(key)
            }
        }

        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }

        try await operation(MockUITestYTMusicClient())
    }
}
