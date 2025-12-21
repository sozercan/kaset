import XCTest
@testable import Kaset

/// Tests for the SearchResponseParser.
final class SearchResponseParserTests: XCTestCase {
    func testParseEmptyResponse() {
        // Given
        let data: [String: Any] = [:]

        // When
        let response = SearchResponseParser.parse(data)

        // Then
        XCTAssertTrue(response.songs.isEmpty)
        XCTAssertTrue(response.albums.isEmpty)
        XCTAssertTrue(response.artists.isEmpty)
        XCTAssertTrue(response.playlists.isEmpty)
    }

    func testParseSongResults() {
        // Given
        let data = self.makeSearchResponseData(songs: 3, albums: 0, artists: 0, playlists: 0)

        // When
        let response = SearchResponseParser.parse(data)

        // Then
        XCTAssertEqual(response.songs.count, 3)
        XCTAssertTrue(response.albums.isEmpty)
        XCTAssertTrue(response.artists.isEmpty)
        XCTAssertTrue(response.playlists.isEmpty)
    }

    func testParseAlbumResults() {
        // Given
        let data = self.makeSearchResponseData(songs: 0, albums: 2, artists: 0, playlists: 0)

        // When
        let response = SearchResponseParser.parse(data)

        // Then
        XCTAssertTrue(response.songs.isEmpty)
        XCTAssertEqual(response.albums.count, 2)
    }

    func testParseArtistResults() {
        // Given
        let data = self.makeSearchResponseData(songs: 0, albums: 0, artists: 2, playlists: 0)

        // When
        let response = SearchResponseParser.parse(data)

        // Then
        XCTAssertTrue(response.songs.isEmpty)
        XCTAssertEqual(response.artists.count, 2)
    }

    func testParsePlaylistResults() {
        // Given
        let data = self.makeSearchResponseData(songs: 0, albums: 0, artists: 0, playlists: 2)

        // When
        let response = SearchResponseParser.parse(data)

        // Then
        XCTAssertTrue(response.songs.isEmpty)
        XCTAssertEqual(response.playlists.count, 2)
    }

    func testParseMixedResults() {
        // Given
        let data = self.makeSearchResponseData(songs: 2, albums: 1, artists: 1, playlists: 1)

        // When
        let response = SearchResponseParser.parse(data)

        // Then
        XCTAssertEqual(response.songs.count, 2)
        XCTAssertEqual(response.albums.count, 1)
        XCTAssertEqual(response.artists.count, 1)
        XCTAssertEqual(response.playlists.count, 1)
    }

    func testSongHasVideoId() {
        // Given
        let data = self.makeSearchResponseData(songs: 1, albums: 0, artists: 0, playlists: 0)

        // When
        let response = SearchResponseParser.parse(data)

        // Then
        XCTAssertEqual(response.songs.first?.videoId, "video0")
    }

    // MARK: - Helpers

    private func makeSearchResponseData(songs: Int, albums: Int, artists: Int, playlists: Int) -> [String: Any] {
        var contents: [[String: Any]] = []

        if songs > 0 {
            contents.append(["musicShelfRenderer": ["contents": self.makeSongItems(count: songs)]])
        }
        if albums > 0 {
            contents.append(["musicShelfRenderer": ["contents": self.makeAlbumItems(count: albums)]])
        }
        if artists > 0 {
            contents.append(["musicShelfRenderer": ["contents": self.makeArtistItems(count: artists)]])
        }
        if playlists > 0 {
            contents.append(["musicShelfRenderer": ["contents": self.makePlaylistItems(count: playlists)]])
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
