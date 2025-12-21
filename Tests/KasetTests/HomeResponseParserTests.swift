import XCTest
@testable import Kaset

/// Tests for the HomeResponseParser.
final class HomeResponseParserTests: XCTestCase {
    func testParseEmptyResponse() {
        // Given
        let data: [String: Any] = [:]

        // When
        let response = HomeResponseParser.parse(data)

        // Then
        XCTAssertTrue(response.sections.isEmpty)
    }

    func testParseResponseWithSections() {
        // Given
        let data = self.makeHomeResponseData(sectionCount: 3)

        // When
        let response = HomeResponseParser.parse(data)

        // Then
        XCTAssertEqual(response.sections.count, 3)
    }

    func testParseCarouselSectionWithAlbum() {
        // Given
        let albumData: [String: Any] = [
            "musicTwoRowItemRenderer": [
                "title": ["runs": [["text": "Test Album"]]],
                "navigationEndpoint": [
                    "browseEndpoint": [
                        "browseId": "MPRE12345",
                        "browseEndpointContextSupportedConfigs": [
                            "browseEndpointContextMusicConfig": [
                                "pageType": "MUSIC_PAGE_TYPE_ALBUM",
                            ],
                        ],
                    ],
                ],
                "thumbnail": [
                    "musicThumbnailRenderer": [
                        "thumbnail": [
                            "thumbnails": [
                                ["url": "https://example.com/thumb.jpg"],
                            ],
                        ],
                    ],
                ],
                "subtitle": ["runs": [["text": "Artist Name"]]],
            ],
        ]

        let sectionData: [String: Any] = [
            "musicCarouselShelfRenderer": [
                "header": [
                    "musicCarouselShelfBasicHeaderRenderer": [
                        "title": ["runs": [["text": "New Albums"]]],
                    ],
                ],
                "contents": [albumData],
            ],
        ]

        // When
        let section = HomeResponseParser.parseHomeSection(sectionData)

        // Then
        XCTAssertNotNil(section)
        XCTAssertEqual(section?.title, "New Albums")
        XCTAssertEqual(section?.items.count, 1)

        if case let .album(album) = section?.items.first {
            XCTAssertEqual(album.title, "Test Album")
            XCTAssertEqual(album.id, "MPRE12345")
        } else {
            XCTFail("Expected album item")
        }
    }

    func testParseCarouselSectionWithPlaylist() {
        // Given
        let playlistData: [String: Any] = [
            "musicTwoRowItemRenderer": [
                "title": ["runs": [["text": "My Playlist"]]],
                "navigationEndpoint": [
                    "browseEndpoint": [
                        "browseId": "VL12345",
                        "browseEndpointContextSupportedConfigs": [
                            "browseEndpointContextMusicConfig": [
                                "pageType": "MUSIC_PAGE_TYPE_PLAYLIST",
                            ],
                        ],
                    ],
                ],
                "subtitle": ["runs": [["text": "By User"]]],
            ],
        ]

        let sectionData: [String: Any] = [
            "musicCarouselShelfRenderer": [
                "header": [
                    "musicCarouselShelfBasicHeaderRenderer": [
                        "title": ["runs": [["text": "Playlists"]]],
                    ],
                ],
                "contents": [playlistData],
            ],
        ]

        // When
        let section = HomeResponseParser.parseHomeSection(sectionData)

        // Then
        XCTAssertNotNil(section)
        if case let .playlist(playlist) = section?.items.first {
            XCTAssertEqual(playlist.title, "My Playlist")
            XCTAssertEqual(playlist.id, "VL12345")
        } else {
            XCTFail("Expected playlist item")
        }
    }

    func testParseChartSection() {
        // Given
        let sectionData: [String: Any] = [
            "musicCarouselShelfRenderer": [
                "header": [
                    "musicCarouselShelfBasicHeaderRenderer": [
                        "title": ["runs": [["text": "Top 100 Charts"]]],
                    ],
                ],
                "contents": [],
            ],
        ]

        // When - section should be nil due to empty contents
        let section = HomeResponseParser.parseHomeSection(sectionData)

        // Then - no items, so section is nil
        XCTAssertNil(section)
    }

    func testExtractContinuationToken() {
        // Given
        let data: [String: Any] = [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [],
                                    "continuations": [[
                                        "nextContinuationData": [
                                            "continuation": "test_token_123",
                                        ],
                                    ]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]

        // When
        let token = HomeResponseParser.extractContinuationToken(from: data)

        // Then
        XCTAssertEqual(token, "test_token_123")
    }

    func testExtractContinuationTokenFromContinuation() {
        // Given
        let data: [String: Any] = [
            "continuationContents": [
                "sectionListContinuation": [
                    "continuations": [[
                        "nextContinuationData": [
                            "continuation": "next_token_456",
                        ],
                    ]],
                ],
            ],
        ]

        // When
        let token = HomeResponseParser.extractContinuationTokenFromContinuation(data)

        // Then
        XCTAssertEqual(token, "next_token_456")
    }

    // MARK: - Helpers

    private func makeHomeResponseData(sectionCount: Int) -> [String: Any] {
        var sections: [[String: Any]] = []

        for i in 0 ..< sectionCount {
            let songData: [String: Any] = [
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": "video\(i)"],
                    "flexColumns": [
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Song \(i)"]]],
                            ],
                        ],
                        [
                            "musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Artist \(i)"]]],
                            ],
                        ],
                    ],
                ],
            ]

            let section: [String: Any] = [
                "musicShelfRenderer": [
                    "title": ["runs": [["text": "Section \(i)"]]],
                    "contents": [songData],
                ],
            ]
            sections.append(section)
        }

        return [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": sections,
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }
}
