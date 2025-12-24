import Foundation
import Testing
@testable import Kaset

/// Tests for the SearchResponseParser.
@Suite
struct SearchResponseParserTests {
    @Test("Parse empty response returns empty results")
    func parseEmptyResponse() {
        let data: [String: Any] = [:]
        let response = SearchResponseParser.parse(data)

        #expect(response.songs.isEmpty)
        #expect(response.albums.isEmpty)
        #expect(response.artists.isEmpty)
        #expect(response.playlists.isEmpty)
    }

    @Test("Parse response with only songs")
    func parseSongResults() {
        let data = makeSearchResponseData(songs: 3, albums: 0, artists: 0, playlists: 0)
        let response = SearchResponseParser.parse(data)

        #expect(response.songs.count == 3)
        #expect(response.albums.isEmpty)
        #expect(response.artists.isEmpty)
        #expect(response.playlists.isEmpty)
    }

    @Test("Parse response with only albums")
    func parseAlbumResults() {
        let data = makeSearchResponseData(songs: 0, albums: 2, artists: 0, playlists: 0)
        let response = SearchResponseParser.parse(data)

        #expect(response.songs.isEmpty)
        #expect(response.albums.count == 2)
    }

    @Test("Parse response with only artists")
    func parseArtistResults() {
        let data = makeSearchResponseData(songs: 0, albums: 0, artists: 2, playlists: 0)
        let response = SearchResponseParser.parse(data)

        #expect(response.songs.isEmpty)
        #expect(response.artists.count == 2)
    }

    @Test("Parse response with only playlists")
    func parsePlaylistResults() {
        let data = makeSearchResponseData(songs: 0, albums: 0, artists: 0, playlists: 2)
        let response = SearchResponseParser.parse(data)

        #expect(response.songs.isEmpty)
        #expect(response.playlists.count == 2)
    }

    @Test("Parse response with mixed results")
    func parseMixedResults() {
        let data = makeSearchResponseData(songs: 2, albums: 1, artists: 1, playlists: 1)
        let response = SearchResponseParser.parse(data)

        #expect(response.songs.count == 2)
        #expect(response.albums.count == 1)
        #expect(response.artists.count == 1)
        #expect(response.playlists.count == 1)
    }

    @Test("Song has correct video ID")
    func songHasVideoId() {
        let data = makeSearchResponseData(songs: 1, albums: 0, artists: 0, playlists: 0)
        let response = SearchResponseParser.parse(data)

        #expect(response.songs.first?.videoId == "video0")
    }

    // MARK: - Helpers

    private func makeSearchResponseData(songs: Int, albums: Int, artists: Int, playlists: Int) -> [String: Any] {
        var contents: [[String: Any]] = []

        if songs > 0 {
            contents.append(["musicShelfRenderer": ["contents": makeSongItems(count: songs)]])
        }
        if albums > 0 {
            contents.append(["musicShelfRenderer": ["contents": makeAlbumItems(count: albums)]])
        }
        if artists > 0 {
            contents.append(["musicShelfRenderer": ["contents": makeArtistItems(count: artists)]])
        }
        if playlists > 0 {
            contents.append(["musicShelfRenderer": ["contents": makePlaylistItems(count: playlists)]])
        }

        return [
            "contents": [
                "tabbedSearchResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": contents,
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    private func makeSongItems(count: Int) -> [[String: Any]] {
        (0 ..< count).map { i in
            [
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": "video\(i)"],
                    "flexColumns": [
                        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Song \(i)"]]]]],
                        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Artist"]]]]],
                    ],
                ],
            ]
        }
    }

    private func makeAlbumItems(count: Int) -> [[String: Any]] {
        (0 ..< count).map { i in
            [
                "musicResponsiveListItemRenderer": [
                    "navigationEndpoint": ["browseEndpoint": ["browseId": "MPRE\(i)"]],
                    "flexColumns": [
                        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Album \(i)"]]]]],
                    ],
                ],
            ]
        }
    }

    private func makeArtistItems(count: Int) -> [[String: Any]] {
        (0 ..< count).map { i in
            [
                "musicResponsiveListItemRenderer": [
                    "navigationEndpoint": ["browseEndpoint": ["browseId": "UC\(i)"]],
                    "flexColumns": [
                        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Artist \(i)"]]]]],
                    ],
                ],
            ]
        }
    }

    private func makePlaylistItems(count: Int) -> [[String: Any]] {
        (0 ..< count).map { i in
            [
                "musicResponsiveListItemRenderer": [
                    "navigationEndpoint": ["browseEndpoint": ["browseId": "VL\(i)"]],
                    "flexColumns": [
                        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Playlist \(i)"]]]]],
                    ],
                ],
            ]
        }
    }
}
