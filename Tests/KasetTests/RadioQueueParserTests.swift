import Foundation
import Testing
@testable import Kaset

/// Tests for RadioQueueParser.
@Suite("RadioQueueParser", .tags(.parser))
struct RadioQueueParserTests {
    // MARK: - Parse Initial Response Tests

    @Test("Parse empty data returns empty result")
    func parseEmptyData() {
        let data: [String: Any] = [:]
        let result = RadioQueueParser.parse(from: data)

        #expect(result.songs.isEmpty)
        #expect(result.continuationToken == nil)
    }

    @Test("Parse valid radio queue extracts songs")
    func parseValidRadioQueue() {
        let data = Self.makeRadioQueueResponse(songCount: 3)
        let result = RadioQueueParser.parse(from: data)

        #expect(result.songs.count == 3)
        #expect(result.songs[0].title == "Song 0")
        #expect(result.songs[0].videoId == "video-0")
    }

    @Test("Parse radio queue extracts continuation token")
    func parseRadioQueueWithContinuation() {
        let data = Self.makeRadioQueueResponse(songCount: 2, continuationToken: "next-page-token")
        let result = RadioQueueParser.parse(from: data)

        #expect(result.songs.count == 2)
        #expect(result.continuationToken == "next-page-token")
    }

    @Test("Parse radio queue without continuation token")
    func parseRadioQueueWithoutContinuation() {
        let data = Self.makeRadioQueueResponse(songCount: 2, continuationToken: nil)
        let result = RadioQueueParser.parse(from: data)

        #expect(result.songs.count == 2)
        #expect(result.continuationToken == nil)
    }

    @Test("Parse radio queue extracts artist info")
    func parseRadioQueueExtractsArtists() {
        let data = Self.makeRadioQueueResponse(songCount: 1)
        let result = RadioQueueParser.parse(from: data)

        #expect(result.songs.count == 1)
        #expect(!result.songs[0].artists.isEmpty)
        #expect(result.songs[0].artists[0].name == "Artist 0")
    }

    @Test("Parse radio queue extracts thumbnail URL")
    func parseRadioQueueExtractsThumbnail() {
        let data = Self.makeRadioQueueResponse(songCount: 1)
        let result = RadioQueueParser.parse(from: data)

        #expect(result.songs.count == 1)
        #expect(result.songs[0].thumbnailURL != nil)
        #expect(result.songs[0].thumbnailURL?.absoluteString.contains("example.com") == true)
    }

    @Test("Parse radio queue extracts duration")
    func parseRadioQueueExtractsDuration() {
        let data = Self.makeRadioQueueResponse(songCount: 1)
        let result = RadioQueueParser.parse(from: data)

        #expect(result.songs.count == 1)
        #expect(result.songs[0].duration == 180) // 3:00
    }

    @Test("Parse radio queue handles missing optional fields")
    func parseRadioQueueHandlesMissingFields() {
        let data = Self.makeMinimalRadioQueueResponse()
        let result = RadioQueueParser.parse(from: data)

        #expect(result.songs.count == 1)
        #expect(result.songs[0].videoId == "minimal-video")
        #expect(result.songs[0].title == "Unknown")
    }

    @Test("Parse radio queue handles wrapped renderer structure")
    func parseRadioQueueHandlesWrappedRenderer() {
        let data = Self.makeRadioQueueResponseWithWrapper()
        let result = RadioQueueParser.parse(from: data)

        #expect(result.songs.count == 1)
        #expect(result.songs[0].videoId == "wrapped-video")
        #expect(result.songs[0].title == "Wrapped Song")
    }

    // MARK: - Parse Continuation Response Tests

    @Test("Parse continuation empty data returns empty result")
    func parseContinuationEmptyData() {
        let data: [String: Any] = [:]
        let result = RadioQueueParser.parseContinuation(from: data)

        #expect(result.songs.isEmpty)
        #expect(result.continuationToken == nil)
    }

    @Test("Parse continuation extracts songs")
    func parseContinuationExtractsSongs() {
        let data = Self.makeContinuationResponse(songCount: 5, nextToken: nil)
        let result = RadioQueueParser.parseContinuation(from: data)

        #expect(result.songs.count == 5)
        #expect(result.songs[0].videoId == "cont-video-0")
    }

    @Test("Parse continuation extracts next continuation token")
    func parseContinuationExtractsNextToken() {
        let data = Self.makeContinuationResponse(songCount: 3, nextToken: "another-page")
        let result = RadioQueueParser.parseContinuation(from: data)

        #expect(result.songs.count == 3)
        #expect(result.continuationToken == "another-page")
    }

    @Test("Parse continuation without next token")
    func parseContinuationWithoutNextToken() {
        let data = Self.makeContinuationResponse(songCount: 2, nextToken: nil)
        let result = RadioQueueParser.parseContinuation(from: data)

        #expect(result.songs.count == 2)
        #expect(result.continuationToken == nil)
    }

    // MARK: - Test Helpers

    /// Creates a mock radio queue response with the specified number of songs.
    private static func makeRadioQueueResponse(
        songCount: Int,
        continuationToken: String? = nil
    ) -> [String: Any] {
        var playlistContents: [[String: Any]] = []
        for i in 0 ..< songCount {
            playlistContents.append(Self.makePanelVideoRenderer(index: i))
        }

        var playlistPanelRenderer: [String: Any] = [
            "contents": playlistContents,
        ]

        if let token = continuationToken {
            playlistPanelRenderer["continuations"] = [
                [
                    "nextRadioContinuationData": [
                        "continuation": token,
                    ],
                ],
            ]
        }

        return [
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
                                                    "playlistPanelRenderer": playlistPanelRenderer,
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

    /// Creates a minimal radio queue response with just videoId.
    private static func makeMinimalRadioQueueResponse() -> [String: Any] {
        let minimalRenderer: [String: Any] = [
            "playlistPanelVideoRenderer": [
                "videoId": "minimal-video",
            ],
        ]

        return [
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
                                                        "contents": [minimalRenderer],
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

    /// Creates a radio queue response with wrapped renderer structure.
    private static func makeRadioQueueResponseWithWrapper() -> [String: Any] {
        let wrappedRenderer: [String: Any] = [
            "playlistPanelVideoWrapperRenderer": [
                "primaryRenderer": [
                    "playlistPanelVideoRenderer": [
                        "videoId": "wrapped-video",
                        "title": [
                            "runs": [
                                ["text": "Wrapped Song"],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        return [
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
                                                        "contents": [wrappedRenderer],
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

    /// Creates a mock continuation response.
    private static func makeContinuationResponse(
        songCount: Int,
        nextToken: String?
    ) -> [String: Any] {
        var contents: [[String: Any]] = []
        for i in 0 ..< songCount {
            contents.append([
                "playlistPanelVideoRenderer": [
                    "videoId": "cont-video-\(i)",
                    "title": [
                        "runs": [
                            ["text": "Continuation Song \(i)"],
                        ],
                    ],
                ],
            ])
        }

        var playlistPanelContinuation: [String: Any] = [
            "contents": contents,
        ]

        if let token = nextToken {
            playlistPanelContinuation["continuations"] = [
                [
                    "nextRadioContinuationData": [
                        "continuation": token,
                    ],
                ],
            ]
        }

        return [
            "continuationContents": [
                "playlistPanelContinuation": playlistPanelContinuation,
            ],
        ]
    }

    /// Creates a single panel video renderer for testing.
    private static func makePanelVideoRenderer(index: Int) -> [String: Any] {
        [
            "playlistPanelVideoRenderer": [
                "videoId": "video-\(index)",
                "title": [
                    "runs": [
                        ["text": "Song \(index)"],
                    ],
                ],
                "longBylineText": [
                    "runs": [
                        [
                            "text": "Artist \(index)",
                            "navigationEndpoint": [
                                "browseEndpoint": [
                                    "browseId": "UC-artist-\(index)",
                                ],
                            ],
                        ],
                    ],
                ],
                "thumbnail": [
                    "thumbnails": [
                        ["url": "https://example.com/thumb-\(index).jpg", "width": 120, "height": 120],
                    ],
                ],
                "lengthText": [
                    "runs": [
                        ["text": "3:00"],
                    ],
                ],
            ],
        ]
    }
}
