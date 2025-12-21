import XCTest
@testable import Kaset

/// Tests for the PlaylistParser.
final class PlaylistParserTests: XCTestCase {
    // MARK: - Library Playlists

    func testParseLibraryPlaylistsEmpty() {
        // Given
        let data: [String: Any] = [:]

        // When
        let playlists = PlaylistParser.parseLibraryPlaylists(data)

        // Then
        XCTAssertTrue(playlists.isEmpty)
    }

    func testParseLibraryPlaylistsFromGrid() {
        // Given
        let data = self.makeLibraryResponseData(playlistCount: 3)

        // When
        let playlists = PlaylistParser.parseLibraryPlaylists(data)

        // Then
        XCTAssertEqual(playlists.count, 3)
    }

    // MARK: - Playlist Detail

    func testParsePlaylistDetailWithMusicDetailHeader() {
        // Given
        let data = self.makePlaylistDetailData(
            title: "My Playlist",
            description: "A great playlist",
            author: "Test User",
            trackCount: 5
        )

        // When
        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "VL123")

        // Then
        XCTAssertEqual(detail.id, "VL123")
        XCTAssertEqual(detail.title, "My Playlist")
        XCTAssertEqual(detail.description, "A great playlist")
        XCTAssertEqual(detail.author, "Test User")
        XCTAssertEqual(detail.tracks.count, 5)
    }

    func testParsePlaylistDetailWithTracks() {
        // Given
        let data = self.makePlaylistDetailData(
            title: "Track Test",
            description: nil,
            author: nil,
            trackCount: 3
        )

        // When
        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "VL456")

        // Then
        XCTAssertEqual(detail.tracks.count, 3)
        XCTAssertEqual(detail.tracks[0].title, "Track 0")
        XCTAssertEqual(detail.tracks[0].videoId, "video0")
    }

    func testParsePlaylistDetailEmpty() {
        // Given
        let data: [String: Any] = [:]

        // When
        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "VL789")

        // Then
        XCTAssertEqual(detail.id, "VL789")
        XCTAssertEqual(detail.title, "Unknown Playlist")
        XCTAssertTrue(detail.tracks.isEmpty)
    }

    // MARK: - Album Detection

    func testIsAlbumForAlbumId() {
        // Given
        let data = self.makePlaylistDetailData(title: "Album", description: nil, author: nil, trackCount: 10)

        // When
        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "MPRE12345")

        // Then
        XCTAssertTrue(detail.isAlbum)
    }

    func testIsAlbumForPlaylistId() {
        // Given
        let data = self.makePlaylistDetailData(title: "Playlist", description: nil, author: nil, trackCount: 10)

        // When
        let detail = PlaylistParser.parsePlaylistDetail(data, playlistId: "VL12345")

        // Then
        XCTAssertFalse(detail.isAlbum)
    }

    // MARK: - Helpers

    private func makeLibraryResponseData(playlistCount: Int) -> [String: Any] {
        var items: [[String: Any]] = []

        for i in 0 ..< playlistCount {
            items.append([
                "musicTwoRowItemRenderer": [
                    "title": ["runs": [["text": "Playlist \(i)"]]],
                    "navigationEndpoint": [
                        "browseEndpoint": ["browseId": "VL\(i)"],
                    ],
                ],
            ])
        }

        return [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "gridRenderer": [
                                            "items": items,
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    private func makePlaylistDetailData(
        title: String,
        description: String?,
        author: String?,
        trackCount: Int
    ) -> [String: Any] {
        var tracks: [[String: Any]] = []

        for i in 0 ..< trackCount {
            tracks.append([
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": "video\(i)"],
                    "flexColumns": [
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Track \(i)"]]],
                            ],
                        ],
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Artist \(i)"]]],
                            ],
                        ],
                    ],
                ],
            ])
        }

        var headerRenderer: [String: Any] = [
            "title": ["runs": [["text": title]]],
        ]

        if let desc = description {
            headerRenderer["description"] = ["runs": [["text": desc]]]
        }

        if let auth = author {
            headerRenderer["subtitle"] = ["runs": [["text": auth]]]
        }

        return [
            "header": [
                "musicDetailHeaderRenderer": headerRenderer,
            ],
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [[
                                        "musicShelfRenderer": [
                                            "contents": tracks,
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }
}
