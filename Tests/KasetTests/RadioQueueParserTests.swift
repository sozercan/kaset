import Foundation
import Testing
@testable import Kaset

/// Tests for RadioQueueParser.
@Suite(.tags(.parser))
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
        #expect(result.songs[0].artists.count == 1)
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
    @Test("Parse radio queue propagates explicit badge")
    func parseRadioQueuePropagatesExplicitBadge() {
        let explicitRenderer: [String: Any] = [
            "playlistPanelVideoRenderer": [
                "videoId": "explicit-video",
                "title": ["runs": [["text": "Explicit Track"]]],
                "badges": [[
                    "musicInlineBadgeRenderer": [
                        "icon": ["iconType": "MUSIC_EXPLICIT_BADGE"],
                    ],
                ]],
            ],
        ]
        let cleanRenderer: [String: Any] = [
            "playlistPanelVideoRenderer": [
                "videoId": "clean-video",
                "title": ["runs": [["text": "Clean Track"]]],
            ],
        ]
        let data: [String: Any] = [
            "contents": [
                "singleColumnMusicWatchNextResultsRenderer": [
                    "tabbedRenderer": [
                        "watchNextTabbedResultsRenderer": [
                            "tabs": [[
                                "tabRenderer": [
                                    "content": [
                                        "musicQueueRenderer": [
                                            "content": [
                                                "playlistPanelRenderer": [
                                                    "contents": [explicitRenderer, cleanRenderer],
                                                ],
                                            ],
                                        ],
                                    ],
                                ],
                            ]],
                        ],
                    ],
                ],
            ],
        ]

        let result = RadioQueueParser.parse(from: data)

        #expect(result.songs.count == 2)
        let explicit = result.songs.first { $0.videoId == "explicit-video" }
        let clean = result.songs.first { $0.videoId == "clean-video" }
        #expect(explicit?.isExplicit == true)
        #expect(clean?.isExplicit == false)
    }

    // MARK: - Like Status Tests

    @Test("Parse radio queue decodes each row's like status from its menu")
    func parseRadioQueueDecodesLikeStatus() {
        let liked = Self.makePanelVideoRendererWithLikeStatus(
            videoId: "liked-video", title: "Liked Track", likeStatus: "LIKE"
        )
        let neutral = Self.makePanelVideoRendererWithLikeStatus(
            videoId: "neutral-video", title: "Neutral Track", likeStatus: "INDIFFERENT"
        )
        let disliked = Self.makePanelVideoRendererWithLikeStatus(
            videoId: "disliked-video", title: "Disliked Track", likeStatus: "DISLIKE"
        )
        let data = Self.makeRadioResponse(contents: [liked, neutral, disliked])

        let result = RadioQueueParser.parse(from: data)

        #expect(result.songs.count == 3)
        #expect(result.songs.first { $0.videoId == "liked-video" }?.likeStatus == .like)
        #expect(result.songs.first { $0.videoId == "neutral-video" }?.likeStatus == .indifferent)
        #expect(result.songs.first { $0.videoId == "disliked-video" }?.likeStatus == .dislike)
    }

    @Test("Parse radio queue leaves like status nil when the row carries no menu")
    func parseRadioQueueLikeStatusNilWithoutMenu() {
        // Rows without a like menu must keep likeStatus == nil so the existing cache/song
        // fallback still governs — the decode change must not fabricate a status.
        let data = Self.makeRadioQueueResponse(songCount: 1)
        let result = RadioQueueParser.parse(from: data)

        #expect(result.songs.count == 1)
        #expect(result.songs[0].likeStatus == nil)
    }

    @Test("Parse radio queue decodes like status from a wrapped renderer's menu")
    func parseRadioQueueDecodesLikeStatusFromWrappedRenderer() {
        let wrapped: [String: Any] = [
            "playlistPanelVideoWrapperRenderer": [
                "primaryRenderer": [
                    "playlistPanelVideoRenderer": [
                        "videoId": "wrapped-liked",
                        "title": ["runs": [["text": "Wrapped Liked"]]],
                        "menu": Self.makeLikeMenu("LIKE"),
                    ],
                ],
            ],
        ]
        let data = Self.makeRadioResponse(contents: [wrapped])

        let result = RadioQueueParser.parse(from: data)

        #expect(result.songs.count == 1)
        #expect(result.songs[0].videoId == "wrapped-liked")
        #expect(result.songs[0].likeStatus == .like)
    }

    @Test("Parse continuation decodes each row's like status from its menu")
    func parseContinuationDecodesLikeStatus() {
        let liked = Self.makePanelVideoRendererWithLikeStatus(
            videoId: "cont-liked", title: "Cont Liked", likeStatus: "LIKE"
        )
        let data: [String: Any] = [
            "continuationContents": [
                "playlistPanelContinuation": [
                    "contents": [liked],
                ],
            ],
        ]
        let result = RadioQueueParser.parseContinuation(from: data)

        #expect(result.songs.count == 1)
        #expect(result.songs[0].likeStatus == .like)
    }

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
                        ["text": " • "],
                        ["text": "1.3M views"],
                        ["text": " • "],
                        ["text": "42K likes"],
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

    /// Wraps panel renderer contents in the full radio "next" response envelope.
    private static func makeRadioResponse(contents: [[String: Any]]) -> [String: Any] {
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
                                                        "contents": contents,
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

    /// Creates a panel video renderer carrying a like button in its menu, mirroring the
    /// real "next"/radio response shape SongMetadataParser reads for the seed track.
    private static func makePanelVideoRendererWithLikeStatus(
        videoId: String,
        title: String,
        likeStatus: String
    ) -> [String: Any] {
        [
            "playlistPanelVideoRenderer": [
                "videoId": videoId,
                "title": ["runs": [["text": title]]],
                "menu": self.makeLikeMenu(likeStatus),
            ],
        ]
    }

    /// Creates a `menu` carrying a like button with the given status, matching the shape
    /// SongMetadataParser.parseLikeStatus reads (menuRenderer.topLevelButtons.likeButtonRenderer).
    private static func makeLikeMenu(_ likeStatus: String) -> [String: Any] {
        [
            "menuRenderer": [
                "topLevelButtons": [
                    [
                        "likeButtonRenderer": [
                            "likeStatus": likeStatus,
                        ],
                    ],
                ],
            ],
        ]
    }
}
