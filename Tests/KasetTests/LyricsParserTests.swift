import Foundation
import Testing
@testable import Kaset

/// Tests for LyricsParser.
@Suite(.tags(.parser))
struct LyricsParserTests {
    // MARK: - Extract Lyrics Browse ID Tests

    @Test("extractLyricsBrowseId returns nil for empty data")
    func extractBrowseIdEmptyData() {
        let data: [String: Any] = [:]

        let result = LyricsParser.extractLyricsBrowseId(from: data)

        #expect(result == nil)
    }

    @Test("extractLyricsBrowseId returns nil when no lyrics tab")
    func extractBrowseIdNoLyricsTab() {
        let data = Self.makeNextResponse(tabs: [
            Self.makeTab(browseId: "FEmusic_related", title: "Related"),
        ])

        let result = LyricsParser.extractLyricsBrowseId(from: data)

        #expect(result == nil)
    }

    @Test("extractLyricsBrowseId extracts lyrics browse ID")
    func extractBrowseIdSuccess() {
        let data = Self.makeNextResponse(tabs: [
            Self.makeTab(browseId: "MPLYtvideo123", title: "Lyrics"),
            Self.makeTab(browseId: "FEmusic_related", title: "Related"),
        ])

        let result = LyricsParser.extractLyricsBrowseId(from: data)

        #expect(result == "MPLYtvideo123")
    }

    @Test("extractLyricsBrowseId finds lyrics tab among multiple tabs")
    func extractBrowseIdFindsAmongMultiple() {
        let data = Self.makeNextResponse(tabs: [
            Self.makeTab(browseId: "FEmusic_up_next", title: "Up Next"),
            Self.makeTab(browseId: "MPLYtSong456", title: "Lyrics"),
            Self.makeTab(browseId: "FEmusic_related", title: "Related"),
        ])

        let result = LyricsParser.extractLyricsBrowseId(from: data)

        #expect(result == "MPLYtSong456")
    }

    @Test("extractTimedLyrics finds nested timed lyrics models")
    func extractTimedLyricsFindsNestedModel() throws {
        let data = Self.makeNestedTimedLyricsResponse(lines: [
            [
                "lyricLine": "Nested synced line",
                "startTimeMs": "1234",
                "durationMs": "567",
            ],
        ])

        let result = try #require(LyricsParser.extractTimedLyrics(from: data))

        #expect(result.source == "YTMusic")
        #expect(result.lines.count == 1)
        #expect(result.lines[0].text == "Nested synced line")
        #expect(result.lines[0].timeInMs == 1234)
        #expect(result.lines[0].duration == 567)
    }

    // MARK: - Parse Lyrics Tests

    @Test("parse returns unavailable for empty data")
    func parseEmptyData() {
        let data: [String: Any] = [:]

        let result = LyricsParser.parse(from: data)

        #expect(result == .unavailable)
    }

    @Test("parse returns unavailable when no section contents")
    func parseNoSectionContents() {
        let data: [String: Any] = [
            "contents": [
                "sectionListRenderer": [:],
            ],
        ]

        let result = LyricsParser.parse(from: data)

        #expect(result == .unavailable)
    }

    @Test("parse extracts lyrics text")
    func parseExtractsLyricsText() {
        let data = Self.makeLyricsResponse(
            lyrics: "Hello, it's me\nI was wondering",
            source: nil
        )

        let result = LyricsParser.parse(from: data)

        #expect(result.text == "Hello, it's me\nI was wondering")
        #expect(result.source == nil)
    }

    @Test("parse extracts lyrics with source")
    func parseExtractsLyricsWithSource() {
        let data = Self.makeLyricsResponse(
            lyrics: "Never gonna give you up",
            source: "Lyrics by LyricFind"
        )

        let result = LyricsParser.parse(from: data)

        #expect(result.text == "Never gonna give you up")
        #expect(result.source == "Lyrics by LyricFind")
    }

    @Test("parse handles multi-run lyrics")
    func parseHandlesMultiRunLyrics() {
        let data: [String: Any] = [
            "contents": [
                "sectionListRenderer": [
                    "contents": [
                        [
                            "musicDescriptionShelfRenderer": [
                                "description": [
                                    "runs": [
                                        ["text": "First verse\n"],
                                        ["text": "Second line\n"],
                                        ["text": "Third line"],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let result = LyricsParser.parse(from: data)

        #expect(result.text == "First verse\nSecond line\nThird line")
    }

    @Test("parse returns unavailable when lyrics text is empty")
    func parseReturnsUnavailableWhenEmpty() {
        let data = Self.makeLyricsResponse(lyrics: "", source: "Some source")

        let result = LyricsParser.parse(from: data)

        #expect(result == .unavailable)
    }

    // MARK: - Test Helpers

    /// Creates a mock "next" endpoint response with tabs.
    private static func makeNextResponse(tabs: [[String: Any]]) -> [String: Any] {
        [
            "contents": [
                "singleColumnMusicWatchNextResultsRenderer": [
                    "tabbedRenderer": [
                        "watchNextTabbedResultsRenderer": [
                            "tabs": tabs,
                        ],
                    ],
                ],
            ],
        ]
    }

    /// Creates a tab with the given browse ID.
    private static func makeTab(browseId: String, title: String) -> [String: Any] {
        [
            "tabRenderer": [
                "title": title,
                "endpoint": [
                    "browseEndpoint": [
                        "browseId": browseId,
                    ],
                ],
            ],
        ]
    }

    /// Creates a mock lyrics browse response.
    private static func makeLyricsResponse(lyrics: String, source: String?) -> [String: Any] {
        var shelfRenderer: [String: Any] = [
            "description": [
                "runs": [
                    ["text": lyrics],
                ],
            ],
        ]

        if let source {
            shelfRenderer["footer"] = [
                "runs": [
                    ["text": source],
                ],
            ]
        }

        return [
            "contents": [
                "sectionListRenderer": [
                    "contents": [
                        [
                            "musicDescriptionShelfRenderer": shelfRenderer,
                        ],
                    ],
                ],
            ],
        ]
    }

    /// Creates a mock next response with timed lyrics nested below the top level.
    private static func makeNestedTimedLyricsResponse(lines: [[String: Any]]) -> [String: Any] {
        [
            "contents": [
                "singleColumnMusicWatchNextResultsRenderer": [
                    "tabbedRenderer": [
                        "watchNextTabbedResultsRenderer": [
                            "tabs": [
                                [
                                    "tabRenderer": [
                                        "title": "Lyrics",
                                        "content": [
                                            "musicQueueRenderer": [
                                                "content": [
                                                    "timedLyricsModel": [
                                                        "lyricsData": lines,
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
