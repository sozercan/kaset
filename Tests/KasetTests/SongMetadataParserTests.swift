import Foundation
import Testing
@testable import Kaset

/// Tests for SongMetadataParser.
@Suite("SongMetadataParser", .tags(.parser))
struct SongMetadataParserTests {
    // MARK: - Parse Title Tests

    @Test("parseTitle extracts title from renderer")
    func parseTitleExtractsTitle() {
        let renderer: [String: Any] = [
            "title": [
                "runs": [
                    ["text": "Test Song Title"],
                ],
            ],
        ]

        let result = SongMetadataParser.parseTitle(from: renderer)

        #expect(result == "Test Song Title")
    }

    @Test("parseTitle returns Unknown when no title")
    func parseTitleReturnsUnknown() {
        let renderer: [String: Any] = [:]

        let result = SongMetadataParser.parseTitle(from: renderer)

        #expect(result == "Unknown")
    }

    @Test("parseTitle returns Unknown when runs empty")
    func parseTitleReturnsUnknownWhenRunsEmpty() {
        let renderer: [String: Any] = [
            "title": [
                "runs": [] as [[String: Any]],
            ],
        ]

        let result = SongMetadataParser.parseTitle(from: renderer)

        #expect(result == "Unknown")
    }

    // MARK: - Parse Artists Tests

    @Test("parseArtists extracts single artist")
    func parseArtistsSingleArtist() {
        let renderer = Self.makeRendererWithArtists([
            ("Taylor Swift", "UC-artist-1"),
        ])

        let artists = SongMetadataParser.parseArtists(from: renderer)

        #expect(artists.count == 1)
        #expect(artists[0].name == "Taylor Swift")
        #expect(artists[0].id == "UC-artist-1")
    }

    @Test("parseArtists extracts multiple artists")
    func parseArtistsMultipleArtists() {
        let renderer = Self.makeRendererWithArtists([
            ("Artist One", "UC-1"),
            ("Artist Two", "UC-2"),
        ])

        let artists = SongMetadataParser.parseArtists(from: renderer)

        #expect(artists.count == 2)
        #expect(artists[0].name == "Artist One")
        #expect(artists[1].name == "Artist Two")
    }

    @Test("parseArtists filters out separators")
    func parseArtistsFiltersSeparators() {
        let renderer: [String: Any] = [
            "longBylineText": [
                "runs": [
                    ["text": "Artist One"],
                    ["text": " • "],
                    ["text": "Artist Two"],
                    ["text": " & "],
                    ["text": "Artist Three"],
                ],
            ],
        ]

        let artists = SongMetadataParser.parseArtists(from: renderer)

        #expect(artists.count == 3)
        #expect(artists.map(\.name) == ["Artist One", "Artist Two", "Artist Three"])
    }

    @Test("parseArtists generates UUID for artist without ID")
    func parseArtistsGeneratesUUID() {
        let renderer: [String: Any] = [
            "longBylineText": [
                "runs": [
                    ["text": "Unknown Artist"],
                ],
            ],
        ]

        let artists = SongMetadataParser.parseArtists(from: renderer)

        #expect(artists.count == 1)
        #expect(artists[0].name == "Unknown Artist")
        #expect(!artists[0].id.isEmpty)
    }

    @Test("parseArtists returns empty when no byline")
    func parseArtistsReturnsEmptyWhenNoByline() {
        let renderer: [String: Any] = [:]

        let artists = SongMetadataParser.parseArtists(from: renderer)

        #expect(artists.isEmpty)
    }

    // MARK: - Parse Thumbnail Tests

    @Test("parseThumbnail extracts URL")
    func parseThumbnailExtractsURL() {
        let renderer: [String: Any] = [
            "thumbnail": [
                "thumbnails": [
                    ["url": "https://example.com/small.jpg", "width": 60, "height": 60],
                    ["url": "https://example.com/large.jpg", "width": 226, "height": 226],
                ],
            ],
        ]

        let url = SongMetadataParser.parseThumbnail(from: renderer)

        #expect(url?.absoluteString == "https://example.com/large.jpg")
    }

    @Test("parseThumbnail handles protocol-relative URL")
    func parseThumbnailHandlesProtocolRelative() {
        let renderer: [String: Any] = [
            "thumbnail": [
                "thumbnails": [
                    ["url": "//example.com/thumb.jpg"],
                ],
            ],
        ]

        let url = SongMetadataParser.parseThumbnail(from: renderer)

        #expect(url?.absoluteString == "https://example.com/thumb.jpg")
    }

    @Test("parseThumbnail returns nil when no thumbnails")
    func parseThumbnailReturnsNilWhenNoThumbnails() {
        let renderer: [String: Any] = [:]

        let url = SongMetadataParser.parseThumbnail(from: renderer)

        #expect(url == nil)
    }

    // MARK: - Parse Duration Tests

    @Test("parseDuration extracts duration")
    func parseDurationExtractsDuration() {
        let renderer: [String: Any] = [
            "lengthText": [
                "runs": [
                    ["text": "3:45"],
                ],
            ],
        ]

        let duration = SongMetadataParser.parseDuration(from: renderer)

        #expect(duration == 225) // 3 * 60 + 45
    }

    @Test("parseDuration handles hour format")
    func parseDurationHandlesHourFormat() {
        let renderer: [String: Any] = [
            "lengthText": [
                "runs": [
                    ["text": "1:02:30"],
                ],
            ],
        ]

        let duration = SongMetadataParser.parseDuration(from: renderer)

        #expect(duration == 3750) // 1 * 3600 + 2 * 60 + 30
    }

    @Test("parseDuration returns nil when no length text")
    func parseDurationReturnsNilWhenNoLengthText() {
        let renderer: [String: Any] = [:]

        let duration = SongMetadataParser.parseDuration(from: renderer)

        #expect(duration == nil)
    }

    // MARK: - Parse Menu Data Tests

    @Test("parseMenuData extracts like status")
    func parseMenuDataExtractsLikeStatus() {
        let renderer: [String: Any] = [
            "menu": [
                "menuRenderer": [
                    "items": [] as [[String: Any]],
                    "topLevelButtons": [
                        [
                            "likeButtonRenderer": [
                                "likeStatus": "LIKE",
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let result = SongMetadataParser.parseMenuData(from: renderer)

        #expect(result.likeStatus == .like)
    }

    @Test("parseMenuData extracts dislike status")
    func parseMenuDataExtractsDislikeStatus() {
        let renderer: [String: Any] = [
            "menu": [
                "menuRenderer": [
                    "items": [] as [[String: Any]],
                    "topLevelButtons": [
                        [
                            "likeButtonRenderer": [
                                "likeStatus": "DISLIKE",
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let result = SongMetadataParser.parseMenuData(from: renderer)

        #expect(result.likeStatus == .dislike)
    }

    @Test("parseMenuData defaults to indifferent")
    func parseMenuDataDefaultsToIndifferent() {
        let renderer: [String: Any] = [
            "menu": [
                "menuRenderer": [
                    "items": [] as [[String: Any]],
                    "topLevelButtons": [
                        [
                            "likeButtonRenderer": [
                                "likeStatus": "INDIFFERENT",
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let result = SongMetadataParser.parseMenuData(from: renderer)

        #expect(result.likeStatus == .indifferent)
    }

    @Test("parseMenuData extracts library add token")
    func parseMenuDataExtractsLibraryAddToken() {
        let renderer = Self.makeRendererWithLibraryMenu(
            iconType: "LIBRARY_ADD",
            feedbackToken: "add-to-library-token"
        )

        let result = SongMetadataParser.parseMenuData(from: renderer)

        #expect(result.feedbackTokens?.add == "add-to-library-token")
        #expect(result.isInLibrary == false)
    }

    @Test("parseMenuData extracts library remove token and sets in library")
    func parseMenuDataExtractsLibraryRemoveToken() {
        let renderer = Self.makeRendererWithLibraryMenu(
            iconType: "LIBRARY_REMOVE",
            feedbackToken: "remove-from-library-token"
        )

        let result = SongMetadataParser.parseMenuData(from: renderer)

        #expect(result.feedbackTokens?.remove == "remove-from-library-token")
        #expect(result.isInLibrary == true)
    }

    @Test("parseMenuData handles empty menu")
    func parseMenuDataHandlesEmptyMenu() {
        let renderer: [String: Any] = [:]

        let result = SongMetadataParser.parseMenuData(from: renderer)

        #expect(result.likeStatus == .indifferent)
        #expect(result.isInLibrary == false)
        #expect(result.feedbackTokens == nil)
    }

    // MARK: - Extract Panel Video Renderer Tests

    @Test("extractPanelVideoRenderer extracts direct renderer")
    func extractPanelVideoRendererDirect() throws {
        let data = Self.makeNextResponseWithRenderer([
            "playlistPanelVideoRenderer": [
                "videoId": "test-video",
                "title": ["runs": [["text": "Test"]]],
            ],
        ])

        let renderer = try SongMetadataParser.extractPanelVideoRenderer(from: data, videoId: "test-video")

        #expect(renderer["videoId"] as? String == "test-video")
    }

    @Test("extractPanelVideoRenderer extracts wrapped renderer")
    func extractPanelVideoRendererWrapped() throws {
        let data = Self.makeNextResponseWithRenderer([
            "playlistPanelVideoWrapperRenderer": [
                "primaryRenderer": [
                    "playlistPanelVideoRenderer": [
                        "videoId": "wrapped-video",
                        "title": ["runs": [["text": "Wrapped"]]],
                    ],
                ],
            ],
        ])

        let renderer = try SongMetadataParser.extractPanelVideoRenderer(from: data, videoId: "wrapped-video")

        #expect(renderer["videoId"] as? String == "wrapped-video")
    }

    @Test("extractPanelVideoRenderer throws on invalid structure")
    func extractPanelVideoRendererThrows() {
        let data: [String: Any] = [:]

        #expect(throws: YTMusicError.self) {
            _ = try SongMetadataParser.extractPanelVideoRenderer(from: data, videoId: "test")
        }
    }

    // MARK: - Test Helpers

    private static func makeRendererWithArtists(_ artists: [(name: String, id: String)]) -> [String: Any] {
        let runs: [[String: Any]] = artists.map { artist in
            [
                "text": artist.name,
                "navigationEndpoint": [
                    "browseEndpoint": [
                        "browseId": artist.id,
                    ],
                ],
            ]
        }

        return [
            "longBylineText": [
                "runs": runs,
            ],
        ]
    }

    private static func makeRendererWithLibraryMenu(iconType: String, feedbackToken: String) -> [String: Any] {
        [
            "menu": [
                "menuRenderer": [
                    "items": [
                        [
                            "menuServiceItemRenderer": [
                                "icon": [
                                    "iconType": iconType,
                                ],
                                "serviceEndpoint": [
                                    "feedbackEndpoint": [
                                        "feedbackToken": feedbackToken,
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    private static func makeNextResponseWithRenderer(_ item: [String: Any]) -> [String: Any] {
        [
            "contents": [
                "singleColumnMusicWatchNextResultsRenderer": [
                    "tabbedRenderer": [
                        "watchNextTabbedResultsRenderer": [
                            "tabs": [
                                [
                                    "tabRenderer": [
                                        "content": [
                                            "musicQueueRenderer": [
                                                "content": [
                                                    "playlistPanelRenderer": [
                                                        "contents": [item],
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }
}
