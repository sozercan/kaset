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

    func testParseNavigationButtonRenderer() {
        // Given - Moods & Genres style navigation button with params
        let buttonData: [String: Any] = [
            "musicNavigationButtonRenderer": [
                "buttonText": [
                    "runs": [["text": "Chill"]],
                ],
                "clickCommand": [
                    "browseEndpoint": [
                        "browseId": "FEmusic_moods_and_genres_category_chill",
                        "params": "someEncodedParams",
                    ],
                ],
            ],
        ]

        // When
        let item = HomeResponseParser.parseHomeSectionItem(buttonData)

        // Then - ID should include params for uniqueness
        XCTAssertNotNil(item)
        if case let .playlist(playlist) = item {
            XCTAssertEqual(playlist.title, "Chill")
            XCTAssertEqual(playlist.id, "FEmusic_moods_and_genres_category_chill_someEncodedParams")
        } else {
            XCTFail("Expected playlist item from navigation button")
        }
    }

    func testParseNavigationButtonRendererWithoutParams() {
        // Given - Moods & Genres style navigation button without params
        let buttonData: [String: Any] = [
            "musicNavigationButtonRenderer": [
                "buttonText": [
                    "runs": [["text": "Focus"]],
                ],
                "clickCommand": [
                    "browseEndpoint": [
                        "browseId": "FEmusic_moods_focus",
                    ],
                ],
            ],
        ]

        // When
        let item = HomeResponseParser.parseHomeSectionItem(buttonData)

        // Then - ID should be just browseId when no params
        XCTAssertNotNil(item)
        if case let .playlist(playlist) = item {
            XCTAssertEqual(playlist.title, "Focus")
            XCTAssertEqual(playlist.id, "FEmusic_moods_focus")
        } else {
            XCTFail("Expected playlist item from navigation button")
        }
    }

    func testParseGridWithNavigationButtons() {
        // Given - Moods & Genres grid section
        let gridData: [String: Any] = [
            "gridRenderer": [
                "header": [
                    "gridHeaderRenderer": [
                        "title": ["runs": [["text": "Moods"]]],
                    ],
                ],
                "items": [
                    [
                        "musicNavigationButtonRenderer": [
                            "buttonText": [
                                "runs": [["text": "Chill"]],
                            ],
                            "clickCommand": [
                                "browseEndpoint": [
                                    "browseId": "FEmusic_moods_chill",
                                ],
                            ],
                        ],
                    ],
                    [
                        "musicNavigationButtonRenderer": [
                            "buttonText": [
                                "runs": [["text": "Focus"]],
                            ],
                            "clickCommand": [
                                "browseEndpoint": [
                                    "browseId": "FEmusic_moods_focus",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        // When
        let section = HomeResponseParser.parseHomeSection(gridData)

        // Then
        XCTAssertNotNil(section)
        XCTAssertEqual(section?.title, "Moods")
        XCTAssertEqual(section?.items.count, 2)
        XCTAssertEqual(section?.isChart, false, "Moods section should not be a chart")

        if case let .playlist(firstPlaylist) = section?.items.first {
            XCTAssertEqual(firstPlaylist.title, "Chill")
        } else {
            XCTFail("Expected playlist item from navigation button")
        }
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
