import Foundation
import Testing
@testable import Kaset

// MARK: - RadioQueueParserTests

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
}

// MARK: - RadioQueueLikeStatusParserTests

/// Tests for row-local rating state carried in radio queue menus.
@Suite(.tags(.parser))
struct RadioQueueLikeStatusParserTests {
    // MARK: - Like Status Tests

    @Test("Parse radio queue inverts a remove-like action into a liked state")
    func parseRadioQueueInvertsRemoveLikeAction() {
        let liked = Self.makePanelVideoRendererWithRatingToggle(
            videoId: "toggle-liked",
            defaultStatus: "INDIFFERENT",
            toggledStatus: "LIKE"
        )
        let result = RadioQueueParser.parse(from: Self.makeRadioResponse(contents: [liked]))

        #expect(result.songs.count == 1)
        #expect(result.songs[0].likeStatus == .like)
    }

    @Test("Parse radio queue accepts a default-only remove-like action")
    func parseRadioQueueAcceptsDefaultOnlyRemoveLikeAction() {
        let liked = Self.makePanelVideoRendererWithRatingToggle(
            videoId: "default-only-liked",
            defaultStatus: "INDIFFERENT",
            toggledStatus: nil
        )
        let result = RadioQueueParser.parse(from: Self.makeRadioResponse(contents: [liked]))

        #expect(result.songs.count == 1)
        #expect(result.songs[0].likeStatus == .like)
    }

    @Test("Parse radio queue uses the toggled endpoint when isToggled is true")
    func parseRadioQueueUsesToggledEndpoint() {
        let liked = Self.makePanelVideoRendererWithRatingToggle(
            videoId: "initially-toggled",
            defaultStatus: "LIKE",
            toggledStatus: "INDIFFERENT",
            isToggled: true
        )
        let result = RadioQueueParser.parse(from: Self.makeRadioResponse(contents: [liked]))

        #expect(result.songs.count == 1)
        #expect(result.songs[0].likeStatus == .like)
    }

    @Test("A pending like or dislike action leaves the rating unknown")
    func pendingRatingActionLeavesRatingUnknown() {
        let missingToggleFlag = Self.makePanelVideoRendererWithRatingToggle(
            videoId: "missing-flag",
            defaultStatus: "LIKE",
            toggledStatus: "INDIFFERENT"
        )
        let falseToggleFlag = Self.makePanelVideoRendererWithRatingToggle(
            videoId: "false-flag",
            defaultStatus: "LIKE",
            toggledStatus: "INDIFFERENT",
            isToggled: false
        )
        let pendingDislike = Self.makePanelVideoRendererWithRatingToggle(
            videoId: "pending-dislike",
            defaultStatus: "DISLIKE",
            toggledStatus: "INDIFFERENT"
        )
        let result = RadioQueueParser.parse(
            from: Self.makeRadioResponse(contents: [missingToggleFlag, falseToggleFlag, pendingDislike])
        )

        #expect(result.songs.count == 3)
        #expect(result.songs.allSatisfy { $0.likeStatus == nil })
    }

    @Test("A remove-dislike action decodes as disliked, never liked")
    func removeDislikeActionDecodesAsDisliked() {
        let activeDislikeRemoval = Self.makePanelVideoRendererWithRatingToggle(
            videoId: "active-dislike-removal",
            defaultStatus: "INDIFFERENT",
            toggledStatus: "DISLIKE"
        )
        let toggledDislike = Self.makePanelVideoRendererWithRatingToggle(
            videoId: "toggled-dislike",
            defaultStatus: "DISLIKE",
            toggledStatus: "INDIFFERENT",
            isToggled: true
        )
        let result = RadioQueueParser.parse(
            from: Self.makeRadioResponse(contents: [activeDislikeRemoval, toggledDislike])
        )

        #expect(result.songs.count == 2)
        #expect(result.songs.allSatisfy { $0.likeStatus == .dislike })
    }

    @Test("A conclusive rating toggle after a pending one still decodes")
    func conclusiveToggleAfterPendingToggleDecodes() {
        let pendingDislike = Self.makeRatingToggleItem(
            videoId: "two-toggles",
            defaultStatus: "DISLIKE",
            toggledStatus: "INDIFFERENT"
        )
        let removeLike = Self.makeRatingToggleItem(
            videoId: "two-toggles",
            defaultStatus: "INDIFFERENT",
            toggledStatus: "LIKE"
        )
        let renderer = Self.makePanelVideoRendererWithMenu(
            videoId: "two-toggles",
            menu: Self.makeMenu(items: [pendingDislike, removeLike])
        )
        let result = RadioQueueParser.parse(from: Self.makeRadioResponse(contents: [renderer]))

        #expect(result.songs.count == 1)
        #expect(result.songs[0].likeStatus == .like)
    }

    @Test("Explicit like status takes precedence over toggle evidence")
    func explicitLikeStatusTakesPrecedence() {
        let toggle = Self.makeRatingToggleItem(
            videoId: "explicit-wins",
            defaultStatus: "INDIFFERENT",
            toggledStatus: "LIKE"
        )
        let renderer = Self.makePanelVideoRendererWithMenu(
            videoId: "explicit-wins",
            menu: Self.makeMenu(directStatuses: ["DISLIKE"], items: [toggle])
        )
        let result = RadioQueueParser.parse(from: Self.makeRadioResponse(contents: [renderer]))

        #expect(result.songs.count == 1)
        #expect(result.songs[0].likeStatus == .dislike)
    }

    @Test("Unrecognized direct like status falls back to the rating toggle")
    func unrecognizedDirectLikeStatusFallsBackToToggle() {
        let cases: [(videoId: String, directStatus: Any)] = [
            ("unknown-direct", "FUTURE_STATUS"),
            ("malformed-direct", 42),
        ]
        let renderers = cases.map { videoId, directStatus in
            Self.makePanelVideoRendererWithMenu(
                videoId: videoId,
                menu: Self.makeMenu(
                    directStatuses: [directStatus],
                    items: [Self.makeRatingToggleItem(
                        videoId: videoId,
                        defaultStatus: "INDIFFERENT",
                        toggledStatus: "LIKE"
                    )]
                )
            )
        }
        let result = RadioQueueParser.parse(from: Self.makeRadioResponse(contents: renderers))

        #expect(result.songs.count == 2)
        #expect(result.songs.allSatisfy { $0.likeStatus == .like })
    }

    @Test("Rating toggle target must match the queue row when present")
    func ratingToggleTargetMustMatchQueueRowWhenPresent() {
        let mismatchedTarget = Self.makePanelVideoRendererWithRatingToggle(
            videoId: "target-row",
            defaultStatus: "INDIFFERENT",
            toggledStatus: "LIKE",
            targetVideoId: "different-video"
        )
        let missingTarget = Self.makePanelVideoRendererWithRatingToggle(
            videoId: "untargeted-row",
            defaultStatus: "INDIFFERENT",
            toggledStatus: "LIKE",
            targetVideoId: .some(nil)
        )
        let result = RadioQueueParser.parse(
            from: Self.makeRadioResponse(contents: [mismatchedTarget, missingTarget])
        )

        #expect(result.songs.count == 2)
        #expect(result.songs.first { $0.videoId == "target-row" }?.likeStatus == nil)
        #expect(result.songs.first { $0.videoId == "untargeted-row" }?.likeStatus == .like)
    }

    @Test("Song metadata menu parsing uses the rating toggle fallback")
    func songMetadataMenuParsingUsesRatingToggleFallback() {
        let ratingToggle = Self.makeRatingToggleItem(
            videoId: "metadata-liked",
            defaultStatus: "INDIFFERENT",
            toggledStatus: "LIKE"
        )
        let renderer: [String: Any] = [
            "videoId": "metadata-liked",
            "menu": Self.makeMenu(items: [ratingToggle]),
        ]

        let menuData = SongMetadataParser.parseMenuData(from: renderer)

        #expect(menuData.likeStatus == .like)
        #expect(menuData.feedbackTokens == nil)
    }

    @Test("Rating endpoints never become library feedback tokens")
    func ratingEndpointsNeverBecomeLibraryFeedbackTokens() {
        let ratingToggle = Self.makeRatingToggleItem(
            videoId: "rating-only",
            defaultStatus: "LIKE",
            toggledStatus: "INDIFFERENT",
            defaultIcon: "BOOKMARK_BORDER",
            toggledIcon: "BOOKMARK"
        )
        let renderer: [String: Any] = [
            "videoId": "rating-only",
            "menu": Self.makeMenu(items: [ratingToggle]),
        ]

        let menuData = SongMetadataParser.parseMenuData(from: renderer)

        #expect(menuData.feedbackTokens == nil)
        #expect(menuData.isInLibrary == false)
    }
}

extension RadioQueueParserTests {
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
}

extension RadioQueueLikeStatusParserTests {
    /// Wraps panel renderer contents in the full radio "next" response envelope.
    static func makeRadioResponse(contents: [[String: Any]]) -> [String: Any] {
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
    static func makePanelVideoRendererWithLikeStatus(
        videoId: String,
        title: String,
        likeStatus: String
    ) -> [String: Any] {
        self.makePanelVideoRendererWithMenu(
            videoId: videoId,
            title: title,
            menu: self.makeLikeMenu(likeStatus)
        )
    }

    /// Creates a `menu` carrying a like button with the given status, matching the shape
    /// SongMetadataParser.parseLikeStatus reads (menuRenderer.topLevelButtons.likeButtonRenderer).
    static func makeLikeMenu(_ likeStatus: String) -> [String: Any] {
        self.makeMenu(directStatuses: [likeStatus])
    }

    /// Creates a panel row whose menu carries a single rating toggle.
    /// `targetVideoId` defaults to the row; pass `.some(nil)` to omit the targets.
    private static func makePanelVideoRendererWithRatingToggle(
        videoId: String,
        defaultStatus: String,
        toggledStatus: String?,
        isToggled: Bool? = nil,
        targetVideoId: String?? = nil
    ) -> [String: Any] {
        let toggle = Self.makeRatingToggleItem(
            videoId: videoId,
            defaultStatus: defaultStatus,
            toggledStatus: toggledStatus,
            isToggled: isToggled,
            targetVideoId: targetVideoId
        )
        return Self.makePanelVideoRendererWithMenu(
            videoId: videoId,
            menu: Self.makeMenu(items: [toggle])
        )
    }

    private static func makePanelVideoRendererWithMenu(
        videoId: String,
        title: String = "Rating Track",
        menu: [String: Any]
    ) -> [String: Any] {
        [
            "playlistPanelVideoRenderer": [
                "videoId": videoId,
                "title": ["runs": [["text": title]]],
                "menu": menu,
            ],
        ]
    }

    private static func makeMenu(
        directStatuses: [Any]? = nil,
        items: [[String: Any]]? = nil
    ) -> [String: Any] {
        var menuRenderer: [String: Any] = [:]
        if let directStatuses {
            menuRenderer["topLevelButtons"] = directStatuses.map { status in
                [
                    "likeButtonRenderer": [
                        "likeStatus": status,
                    ],
                ]
            }
        }
        if let items {
            menuRenderer["items"] = items
        }
        return ["menuRenderer": menuRenderer]
    }

    private static func makeRatingToggleItem(
        videoId: String,
        defaultStatus: String,
        toggledStatus: String?,
        isToggled: Bool? = nil,
        targetVideoId: String?? = nil,
        defaultIcon: String = "FAVORITE",
        toggledIcon: String = "UNFAVORITE"
    ) -> [String: Any] {
        let target = targetVideoId ?? videoId
        var toggle: [String: Any] = [
            "defaultIcon": ["iconType": defaultIcon],
            "toggledIcon": ["iconType": toggledIcon],
            "defaultServiceEndpoint": Self.makeLikeServiceEndpoint(status: defaultStatus, targetVideoId: target),
        ]
        if let toggledStatus {
            toggle["toggledServiceEndpoint"] = Self.makeLikeServiceEndpoint(
                status: toggledStatus,
                targetVideoId: target
            )
        }
        if let isToggled {
            toggle["isToggled"] = isToggled
        }
        return ["toggleMenuServiceItemRenderer": toggle]
    }

    private static func makeLikeServiceEndpoint(
        status: String,
        targetVideoId: String?
    ) -> [String: Any] {
        var likeEndpoint: [String: Any] = ["status": status]
        if let targetVideoId {
            likeEndpoint["target"] = ["videoId": targetVideoId]
        }
        if status == "INDIFFERENT" {
            likeEndpoint["removeLikeParams"] = "REDACTED"
        } else {
            likeEndpoint["likeParams"] = "REDACTED"
        }
        return ["likeEndpoint": likeEndpoint]
    }
}
