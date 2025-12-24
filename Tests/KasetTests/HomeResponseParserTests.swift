import Foundation
import Testing
@testable import Kaset

/// Tests for the HomeResponseParser.
@Suite
struct HomeResponseParserTests {
    @Test("Parse empty response returns empty sections")
    func parseEmptyResponse() {
        let data: [String: Any] = [:]
        let response = HomeResponseParser.parse(data)
        #expect(response.sections.isEmpty)
    }

    @Test("Parse response with multiple sections")
    func parseResponseWithSections() {
        let data = makeHomeResponseData(sectionCount: 3)
        let response = HomeResponseParser.parse(data)
        #expect(response.sections.count == 3)
    }

    @Test("Parse carousel section with album")
    func parseCarouselSectionWithAlbum() throws {
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

        let section = try #require(HomeResponseParser.parseHomeSection(sectionData))

        #expect(section.title == "New Albums")
        #expect(section.items.count == 1)

        if case let .album(album) = section.items.first {
            #expect(album.title == "Test Album")
            #expect(album.id == "MPRE12345")
        } else {
            Issue.record("Expected album item")
        }
    }

    @Test("Parse carousel section with playlist")
    func parseCarouselSectionWithPlaylist() throws {
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

        let section = try #require(HomeResponseParser.parseHomeSection(sectionData))

        if case let .playlist(playlist) = section.items.first {
            #expect(playlist.title == "My Playlist")
            #expect(playlist.id == "VL12345")
        } else {
            Issue.record("Expected playlist item")
        }
    }

    @Test("Parse chart section with empty contents returns nil")
    func parseChartSection() {
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

        let section = HomeResponseParser.parseHomeSection(sectionData)
        #expect(section == nil)
    }

    @Test("Extract continuation token from initial response")
    func extractContinuationToken() {
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

        let token = HomeResponseParser.extractContinuationToken(from: data)
        #expect(token == "test_token_123")
    }

    @Test("Extract continuation token from continuation response")
    func extractContinuationTokenFromContinuation() {
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

        let token = HomeResponseParser.extractContinuationTokenFromContinuation(data)
        #expect(token == "next_token_456")
    }

    @Test("Parse navigation button renderer with params")
    func parseNavigationButtonRenderer() {
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

        let item = HomeResponseParser.parseHomeSectionItem(buttonData)

        #expect(item != nil)
        if case let .playlist(playlist) = item {
            #expect(playlist.title == "Chill")
            #expect(playlist.id == "FEmusic_moods_and_genres_category_chill_someEncodedParams")
        } else {
            Issue.record("Expected playlist item from navigation button")
        }
    }

    @Test("Parse navigation button renderer without params")
    func parseNavigationButtonRendererWithoutParams() {
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

        let item = HomeResponseParser.parseHomeSectionItem(buttonData)

        #expect(item != nil)
        if case let .playlist(playlist) = item {
            #expect(playlist.title == "Focus")
            #expect(playlist.id == "FEmusic_moods_focus")
        } else {
            Issue.record("Expected playlist item from navigation button")
        }
    }

    @Test("Parse grid with navigation buttons")
    func parseGridWithNavigationButtons() throws {
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

        let section = try #require(HomeResponseParser.parseHomeSection(gridData))

        #expect(section.title == "Moods")
        #expect(section.items.count == 2)
        #expect(section.isChart == false, "Moods section should not be a chart")

        if case let .playlist(firstPlaylist) = section.items.first {
            #expect(firstPlaylist.title == "Chill")
        } else {
            Issue.record("Expected playlist item from navigation button")
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
