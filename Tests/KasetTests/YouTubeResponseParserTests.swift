import Foundation
import Testing
@testable import Kaset

// MARK: - Fixture Loading

/// Loads a captured YouTube API fixture from the test bundle.
private func loadYouTubeFixture(_ name: String) throws -> [String: Any] {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
        throw YouTubeFixtureError.notFound(name)
    }
    let data = try Data(contentsOf: url)
    guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw YouTubeFixtureError.invalidJSON(name)
    }
    return dict
}

// MARK: - YouTubeFixtureError

private enum YouTubeFixtureError: Error {
    case notFound(String)
    case invalidJSON(String)
}

// MARK: - YouTubeSearchParserTests

@Suite("YouTubeSearchParser", .tags(.parser))
struct YouTubeSearchParserTests {
    @Test("Parses videos from a captured search response")
    func parsesVideos() throws {
        let data = try loadYouTubeFixture("youtube_search")

        let response = YouTubeSearchParser.parse(data)

        #expect(!response.videos.isEmpty)
        let first = try #require(response.videos.first)
        #expect(first.videoId == "u2rYp8AMuSg")
        #expect(first.title == "WWDC25: Embracing Swift concurrency | Apple")
        #expect(first.channelName == "Apple Developer")
        #expect(first.channelId == "UCwrVwiJllwhJUKXKmjLcckQ")
        #expect(first.lengthText == "28:01")
        #expect(first.thumbnailURL != nil)
    }

    @Test("Parses channels from a channels-filter search response")
    func parsesChannels() throws {
        let data = try loadYouTubeFixture("youtube_search_channels")

        let response = YouTubeSearchParser.parse(data)

        #expect(!response.channels.isEmpty)
        let first = try #require(response.channels.first)
        #expect(first.channelId == "UCHnyfMqiRRG1u-2MsSQLbXA")
        #expect(first.name == "Veritasium")
        #expect(first.handle == "@veritasium")
        #expect(first.subscriberCountText == "20.8M subscribers")
    }

    @Test("Parses playlist lockups from a playlists-filter search response")
    func parsesPlaylists() throws {
        let data = try loadYouTubeFixture("youtube_search_playlists")

        let response = YouTubeSearchParser.parse(data)

        #expect(!response.playlists.isEmpty)
        let first = try #require(response.playlists.first)
        #expect(first.playlistId == "PLXIclLvfETS0GFbNbRpwCgh1CGwO6hLrv")
        #expect(first.firstVideoId == "zW5wpJY1rgQ")
        #expect(!first.title.isEmpty)
    }
}

// MARK: - YouTubeFeedParserTests

@Suite("YouTubeFeedParser", .tags(.parser))
struct YouTubeFeedParserTests {
    @Test("Signed-out home feed parses without videos (nudge only)")
    func parsesSignedOutHome() throws {
        let data = try loadYouTubeFixture("youtube_home")

        let feed = YouTubeFeedParser.parse(data)

        // Unauthenticated home is a sign-in nudge; the parser must return
        // cleanly with no items rather than mis-parsing chrome as videos.
        #expect(feed.videos.isEmpty)
    }

    @Test("Collects lockup videos from a channel page response")
    func collectsFromChannelContents() throws {
        let data = try loadYouTubeFixture("youtube_channel")

        let feed = YouTubeFeedParser.parse(data)

        #expect(!feed.videos.isEmpty)
        #expect(feed.videos.allSatisfy { !$0.videoId.isEmpty && !$0.title.isEmpty })
    }

    @Test("Deduplicates repeated videos while preserving order")
    func deduplicates() {
        let video1 = MockYouTubeClient.makeVideo(videoId: "a")
        let video2 = MockYouTubeClient.makeVideo(videoId: "b")
        let result = YouTubeFeedParser.deduplicate([video1, video2, video1])
        #expect(result.map(\.videoId) == ["a", "b"])
    }

    // MARK: - Home chips & shelves

    /// A chip spec for `makeHomeResponse` (struct, not a tuple, to satisfy the
    /// large_tuple lint rule).
    private struct ChipFixture {
        let title: String
        /// InnerTube continuation cursor; `nil` models the tokenless "All" chip.
        let continuation: String?
        let selected: Bool
    }

    /// Builds a minimal home browse response with a filter-chip bar and
    /// optional richShelfRenderer shelves, matching the live `FEwhat_to_watch`
    /// shape (`richGridRenderer.header.feedFilterChipBarRenderer` and
    /// `richGridRenderer.contents[].richSectionRenderer.content.richShelfRenderer`).
    private func makeHomeResponse(
        chips: [ChipFixture] = [],
        shelves: [(title: String, videoIds: [String])] = []
    ) -> [String: Any] {
        func chipEntry(_ chip: ChipFixture) -> [String: Any] {
            var renderer: [String: Any] = [
                "text": ["simpleText": chip.title],
                "isSelected": chip.selected,
            ]
            if let continuation = chip.continuation {
                renderer["navigationEndpoint"] = [
                    "continuationCommand": ["token": continuation],
                ]
            }
            return ["chipCloudChipRenderer": renderer]
        }

        func videoRenderer(_ id: String) -> [String: Any] {
            ["richItemRenderer": ["content": ["videoRenderer": [
                "videoId": id,
                "title": ["runs": [["text": "Video \(id)"]]],
            ]]]]
        }

        func shelfEntry(_ shelf: (title: String, videoIds: [String])) -> [String: Any] {
            ["richSectionRenderer": ["content": ["richShelfRenderer": [
                "title": ["runs": [["text": shelf.title]]],
                "contents": shelf.videoIds.map(videoRenderer),
            ]]]]
        }

        return [
            "contents": ["twoColumnBrowseResultsRenderer": ["tabs": [
                ["tabRenderer": ["content": ["richGridRenderer": [
                    "header": ["feedFilterChipBarRenderer": ["contents": chips.map(chipEntry)]],
                    "contents": shelves.map(shelfEntry),
                ]]]],
            ]]],
        ]
    }

    @Test("Parses filter chips and skips the selected All chip")
    func parsesChips() {
        let data = self.makeHomeResponse(chips: [
            ChipFixture(title: "All", continuation: nil, selected: true),
            ChipFixture(title: "Gaming", continuation: "tok-gaming", selected: false),
            ChipFixture(title: "Music", continuation: "tok-music", selected: false),
        ])

        let chips = YouTubeFeedParser.parseChips(data)

        #expect(chips.map(\.title) == ["Gaming", "Music"])
        #expect(chips.map(\.continuation) == ["tok-gaming", "tok-music"])
    }

    @Test("Chips without a token are skipped")
    func skipsTokenlessChips() {
        let data = self.makeHomeResponse(chips: [
            ChipFixture(title: "Gaming", continuation: "tok-gaming", selected: false),
            ChipFixture(title: "Broken", continuation: nil, selected: false),
        ])

        let chips = YouTubeFeedParser.parseChips(data)

        #expect(chips.map(\.title) == ["Gaming"])
    }

    @Test("Parses titled home shelves with their videos")
    func parsesHomeShelves() {
        let data = self.makeHomeResponse(shelves: [
            (title: "Breaking news", videoIds: ["n1", "n2"]),
        ])

        let sections = YouTubeFeedParser.parseHomeShelves(data)

        #expect(sections.count == 1)
        let shelf = sections.first
        #expect(shelf?.title == "Breaking news")
        #expect(shelf?.kind == .shelf)
        #expect(shelf?.videos.map(\.videoId) == ["n1", "n2"])
    }

    @Test("Empty shelves are dropped")
    func dropsEmptyShelves() {
        let data = self.makeHomeResponse(shelves: [(title: "Empty", videoIds: [])])

        #expect(YouTubeFeedParser.parseHomeShelves(data).isEmpty)
    }

    @Test("parseHomeBundle parses feed, chips, and shelves from one Data response")
    func parsesHomeBundle() throws {
        let response = self.makeHomeResponse(
            chips: [
                ChipFixture(title: "All", continuation: nil, selected: true),
                ChipFixture(title: "Gaming", continuation: "tok-gaming", selected: false),
            ],
            shelves: [(title: "Breaking news", videoIds: ["n1", "n2"])]
        )
        let data = try JSONSerialization.data(withJSONObject: response)

        let bundle = try YouTubeFeedParser.parseHomeBundle(from: data)

        // Chips: the selected "All" chip is dropped.
        #expect(bundle.chips.map(\.title) == ["Gaming"])
        #expect(bundle.chips.map(\.continuation) == ["tok-gaming"])
        // Shelves: the titled shelf with its videos.
        #expect(bundle.shelves.map(\.title) == ["Breaking news"])
        #expect(bundle.shelves.first?.videos.map(\.videoId) == ["n1", "n2"])
        // Feed: the flat walk collects the shelf videos too (the view model
        // dedupes them against the shelf rail).
        #expect(bundle.feed.videos.map(\.videoId).sorted() == ["n1", "n2"])
    }

    @Test("parseHomeBundle throws when the bytes are not a JSON object")
    func homeBundleThrowsOnNonJSON() {
        let data = Data("not json".utf8)

        #expect(throws: (any Error).self) {
            _ = try YouTubeFeedParser.parseHomeBundle(from: data)
        }
    }
}

// MARK: - WatchNextParserTests

@Suite("WatchNextParser", .tags(.parser))
struct WatchNextParserTests {
    @Test("Parses primary metadata and related videos from a captured next response")
    func parsesWatchNext() throws {
        let data = try loadYouTubeFixture("youtube_watch_next")

        let watchNext = WatchNextParser.parse(data)

        #expect(watchNext.videoTitle == "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)")
        #expect(watchNext.viewCountText == "1,781,910,755 views")
        #expect(watchNext.publishedText == "16 years ago")

        let channel = try #require(watchNext.channel)
        #expect(channel.name == "Rick Astley")
        #expect(channel.channelId.hasPrefix("UC"))

        #expect(!watchNext.related.isEmpty)
        let firstRelated = try #require(watchNext.related.first)
        #expect(firstRelated.videoId == "pAMZjmDGFRQ")
        #expect(firstRelated.channelName == "Plingoro")
        #expect(firstRelated.lengthText == "17:10")

        let description = try #require(watchNext.descriptionText)
        #expect(description.hasPrefix("The official video for"))
    }

    @Test("Parses canonical chapters and merges macro-marker end bounds")
    func parsesPlayerOverlayChapters() throws {
        let watchNext = WatchNextParser.parse(Self.chapterRendererResponse())

        #expect(watchNext.chapters.count == 2)

        let first = try #require(watchNext.chapters.first)
        #expect(first.videoId == "video-1")
        #expect(first.title == "Introduction")
        #expect(first.startTime == 0)
        #expect(first.endTime == 197)
        #expect(first.timeText == nil)
        #expect(first.thumbnailURL?.absoluteString == "https://example.com/intro-336.jpg")

        let second = watchNext.chapters[1]
        #expect(second.title == "Single-threaded code")
        #expect(second.startTime == 197)
        #expect(second.endTime == 360)
    }

    @Test("Falls back to deduplicated macro marker chapter cards")
    func parsesMacroMarkerFallbackChapters() throws {
        let chapters = WatchNextParser.chapters(of: Self.macroMarkerOnlyResponse())

        #expect(chapters.count == 2)

        let first = try #require(chapters.first)
        #expect(first.videoId == "video-1")
        #expect(first.title == "Introduction")
        #expect(first.startTime == 0)
        #expect(first.endTime == 197)
        #expect(first.timeText == "0:00")
        #expect(first.thumbnailURL?.absoluteString == "https://example.com/intro-336.jpg")

        let second = chapters[1]
        #expect(second.title == "Single-threaded code")
        #expect(second.startTime == 197)
        #expect(second.endTime == 360)
    }

    @Test("Ignores heatmap replay markers when chapters are absent")
    func ignoresHeatmapMarkers() {
        let chapters = WatchNextParser.chapters(of: Self.heatmapOnlyResponse())

        #expect(chapters.isEmpty)
    }

    @Test("Parses the structured watch-page description")
    func parsesDescriptionText() {
        let description = "00:00 - Artist A - Track One\n03:15 - Artist B - Track Two"
        let parsed = WatchNextParser.parse(Self.descriptionResponse(description))

        #expect(parsed.descriptionText == description)
    }

    @Test("Falls back to the secondary-info description")
    func parsesSecondaryInfoDescription() {
        let parsed = WatchNextParser.parse(Self.secondaryInfoDescriptionResponse("Secondary description"))

        #expect(parsed.descriptionText == "Secondary description")
    }

    @Test("Prefers the structured description over secondary info")
    func structuredDescriptionTakesPriority() {
        var response = Self.descriptionResponse("Structured description")
        response["contents"] = Self.secondaryInfoDescriptionResponse("Secondary description")["contents"]

        let parsed = WatchNextParser.parse(response)

        #expect(parsed.descriptionText == "Structured description")
    }

    @Test("Parses the runs-based watch-page description")
    func parsesRunsDescriptionText() {
        let parsed = WatchNextParser.parse([
            "engagementPanels": [
                [
                    "descriptionBodyText": [
                        "runs": [
                            ["text": "00:00 Artist A - Track One\n"],
                            ["text": "03:00 Artist B - Track Two"],
                        ],
                    ],
                ],
            ],
        ])

        #expect(parsed.descriptionText == "00:00 Artist A - Track One\n03:00 Artist B - Track Two")
    }

    private static func chapterRendererResponse() -> [String: Any] {
        [
            "currentVideoEndpoint": [
                "watchEndpoint": ["videoId": "video-1"],
            ],
            "playerOverlays": [
                "playerOverlayRenderer": [
                    "decoratedPlayerBarRenderer": [
                        "decoratedPlayerBarRenderer": [
                            "playerBar": [
                                "multiMarkersPlayerBarRenderer": [
                                    "markersMap": [
                                        [
                                            "key": "DESCRIPTION_CHAPTERS",
                                            "value": [
                                                "chapters": [
                                                    ["chapterRenderer": self.chapterRenderer(title: "Introduction", startMs: 0, imageName: "intro")],
                                                    ["chapterRenderer": self.chapterRenderer(title: "Single-threaded code", startMs: 197_000, imageName: "single")],
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
            // Matching macro markers provide end bounds that the canonical
            // chapterRenderer timeline omits.
            "engagementPanels": [
                [
                    "engagementPanelSectionListRenderer": [
                        "content": [
                            "macroMarkersListRenderer": [
                                "contents": [
                                    ["macroMarkersListItemRenderer": self.macroMarkerRenderer(title: "Introduction", startMs: 0, endMs: 197_000, imageName: "intro")],
                                    ["macroMarkersListItemRenderer": self.macroMarkerRenderer(title: "Single-threaded code", startMs: 197_000, endMs: 360_000, imageName: "single")],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    private static func macroMarkerOnlyResponse() -> [String: Any] {
        [
            "currentVideoEndpoint": [
                "watchEndpoint": ["videoId": "video-1"],
            ],
            "engagementPanels": [
                [
                    "engagementPanelSectionListRenderer": [
                        "content": [
                            "macroMarkersListRenderer": [
                                "contents": [
                                    ["macroMarkersListItemRenderer": self.macroMarkerRenderer(title: "Introduction", startMs: 0, endMs: 197_000, imageName: "intro")],
                                    ["macroMarkersListItemRenderer": self.macroMarkerRenderer(title: "Introduction", startMs: 0, endMs: 197_000, imageName: "intro")],
                                    ["macroMarkersListItemRenderer": self.macroMarkerRenderer(title: "Other video chapter", startMs: 45000, endMs: 90000, imageName: "other", videoId: "other-video")],
                                    ["macroMarkersListItemRenderer": self.macroMarkerRenderer(title: "Single-threaded code", startMs: 197_000, endMs: 360_000, imageName: "single")],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    private static func heatmapOnlyResponse() -> [String: Any] {
        [
            "frameworkUpdates": [
                "entityBatchUpdate": [
                    "mutations": [
                        [
                            "payload": [
                                "macroMarkersListEntity": [
                                    "markersList": [
                                        "markerType": "MARKER_TYPE_HEATMAP",
                                        "markers": [
                                            ["startMillis": "0", "durationMillis": "1000", "intensityScoreNormalized": 1],
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

    private static func secondaryInfoDescriptionResponse(_ description: String) -> [String: Any] {
        [
            "contents": [
                "twoColumnWatchNextResults": [
                    "results": [
                        "results": [
                            "contents": [
                                [
                                    "videoSecondaryInfoRenderer": [
                                        "attributedDescription": ["content": description],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    private static func descriptionResponse(_ description: String) -> [String: Any] {
        [
            "engagementPanels": [
                [
                    "engagementPanelSectionListRenderer": [
                        "content": [
                            "structuredDescriptionContentRenderer": [
                                "items": [
                                    [
                                        "expandableVideoDescriptionBodyRenderer": [
                                            "attributedDescriptionBodyText": ["content": description],
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

    private static func chapterRenderer(title: String, startMs: Int, imageName: String) -> [String: Any] {
        [
            "timeRangeStartMillis": startMs,
            "title": ["simpleText": title],
            "thumbnail": self.thumbnail(imageName: imageName),
        ]
    }

    private static func macroMarkerRenderer(
        title: String,
        startMs: Int,
        endMs: Int,
        imageName: String,
        videoId: String = "video-1",
        includesExplicitStart: Bool = true
    ) -> [String: Any] {
        var renderer: [String: Any] = [
            "title": ["runs": [["text": title]]],
            "timeDescription": ["simpleText": self.timeText(seconds: startMs / 1000)],
            "thumbnail": self.thumbnail(imageName: imageName),
        ]

        renderer["onTap"] = [
            "watchEndpoint": includesExplicitStart ? [
                "videoId": videoId,
                "startTimeSeconds": startMs / 1000,
            ] : [
                "videoId": videoId,
            ],
        ]

        if includesExplicitStart {
            renderer["repeatButton"] = [
                "toggleButtonRenderer": [
                    "defaultServiceEndpoint": [
                        "repeatChapterCommand": [
                            "startTimeMs": "\(startMs)",
                            "endTimeMs": "\(endMs)",
                        ],
                    ],
                ],
            ]
        }

        return renderer
    }

    private static func thumbnail(imageName: String) -> [String: Any] {
        [
            "thumbnails": [
                ["url": "https://example.com/\(imageName)-168.jpg", "width": 168, "height": 94],
                ["url": "https://example.com/\(imageName)-336.jpg", "width": 336, "height": 188],
            ],
        ]
    }

    private static func timeText(seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - ChannelPageParserTests

@Suite("ChannelPageParser", .tags(.parser))
struct ChannelPageParserTests {
    @Test("Parses channel metadata and landing videos from a captured browse response")
    func parsesChannelPage() throws {
        let data = try loadYouTubeFixture("youtube_channel")

        let detail = try #require(ChannelPageParser.parse(data, channelId: "UC_x5XG1OV2P6uZZ5FSM9Ttw"))

        #expect(detail.channel.channelId == "UC_x5XG1OV2P6uZZ5FSM9Ttw")
        #expect(detail.channel.name == "Google for Developers")
        #expect(detail.channel.thumbnailURL != nil)
        #expect(detail.channel.descriptionSnippet?.isEmpty == false)
        #expect(!detail.videos.isEmpty)
    }
}

// MARK: - YouTubePlaylistPageParserTests

@Suite("YouTubePlaylistPageParser", .tags(.parser))
struct YouTubePlaylistPageParserTests {
    @Test("Parses playlist title and videos from a captured browse response")
    func parsesPlaylistPage() throws {
        let data = try loadYouTubeFixture("youtube_playlist")

        let detail = YouTubePlaylistPageParser.parse(data, playlistId: "PLsyeobzWxl7poL9JTVyndKe62ieoN-MZ3")

        #expect(detail.playlist.playlistId == "PLsyeobzWxl7poL9JTVyndKe62ieoN-MZ3")
        #expect(detail.playlist.title == "Python for Beginners (Full Course) | Programming Tutorial")
        #expect(!detail.videos.isEmpty)
        #expect(detail.playlist.firstVideoId == detail.videos.first?.videoId)
    }
}

// MARK: - YouTubeCommentsParserTests

@Suite("YouTubeCommentsParser", .tags(.parser))
struct YouTubeCommentsParserTests {
    @Test("Watch-next fixture exposes the comments continuation")
    func watchNextHasCommentsContinuation() throws {
        let data = try loadYouTubeFixture("youtube_watch_next")
        #expect(WatchNextParser.commentsContinuation(of: data) != nil)
    }

    @Test("Parses comments from entity payload mutations")
    func parsesEntityPayloads() throws {
        let data: [String: Any] = [
            "frameworkUpdates": [
                "entityBatchUpdate": [
                    "mutations": [
                        [
                            "payload": [
                                "commentEntityPayload": [
                                    "properties": [
                                        "commentId": "c1",
                                        "content": ["content": "Nice video"],
                                        "publishedTime": "2 days ago",
                                    ],
                                    "author": [
                                        "displayName": "@someone",
                                        "avatarThumbnailUrl": "https://example.com/a.jpg",
                                    ],
                                    "toolbar": ["likeCountNotliked": "42"],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            "onResponseReceivedEndpoints": [
                [
                    "appendContinuationItemsAction": [
                        "continuationItems": [
                            [
                                "continuationItemRenderer": [
                                    "continuationEndpoint": [
                                        "continuationCommand": ["token": "next-page"],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let page = YouTubeCommentsParser.parse(data)

        let comment = try #require(page.comments.first)
        #expect(comment.id == "c1")
        #expect(comment.author == "@someone")
        #expect(comment.text == "Nice video")
        #expect(comment.publishedText == "2 days ago")
        #expect(comment.likeCountText == "42")
        #expect(page.continuation == "next-page")
    }

    @Test("Links view models to entity payloads, surfaces, and replies")
    func linksViewModels() throws {
        let data: [String: Any] = [
            "frameworkUpdates": [
                "entityBatchUpdate": [
                    "mutations": [
                        [
                            "entityKey": "key-c1",
                            "payload": [
                                "commentEntityPayload": [
                                    "properties": [
                                        "commentId": "c1",
                                        "content": ["content": "Threaded"],
                                    ],
                                    "author": [
                                        "displayName": "@author",
                                        "channelId": "UCauthor",
                                    ],
                                ],
                            ],
                        ],
                        [
                            "entityKey": "key-s1",
                            "payload": [
                                "engagementToolbarSurfaceEntityPayload": [
                                    "likeCommand": [
                                        "innertubeCommand": [
                                            "performCommentActionEndpoint": ["action": "like-token"],
                                        ],
                                    ],
                                    "unlikeCommand": [
                                        "innertubeCommand": [
                                            "performCommentActionEndpoint": ["action": "unlike-token"],
                                        ],
                                    ],
                                    "dislikeCommand": [
                                        "innertubeCommand": [
                                            "performCommentActionEndpoint": ["action": "dislike-token"],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            "onResponseReceivedEndpoints": [
                [
                    "appendContinuationItemsAction": [
                        "continuationItems": [
                            [
                                "commentThreadRenderer": [
                                    "commentViewModel": [
                                        "commentViewModel": [
                                            "commentId": "c1",
                                            "commentKey": "key-c1",
                                            "toolbarSurfaceKey": "key-s1",
                                        ],
                                    ],
                                    "replies": [
                                        "commentRepliesRenderer": [
                                            "contents": [
                                                [
                                                    "continuationItemRenderer": [
                                                        "continuationEndpoint": [
                                                            "continuationCommand": ["token": "replies-token"],
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
            ],
        ]

        let page = YouTubeCommentsParser.parse(data)

        let comment = try #require(page.comments.first)
        #expect(comment.id == "c1")
        #expect(comment.authorChannelId == "UCauthor")
        #expect(comment.likeAction == "like-token")
        #expect(comment.unlikeAction == "unlike-token")
        #expect(comment.dislikeAction == "dislike-token")
        #expect(comment.repliesContinuation == "replies-token")
    }

    @Test("Parses legacy commentRenderer responses and create params")
    func parsesLegacyRenderers() throws {
        let data: [String: Any] = [
            "onResponseReceivedEndpoints": [
                [
                    "appendContinuationItemsAction": [
                        "continuationItems": [
                            [
                                "commentThreadRenderer": [
                                    "comment": [
                                        "commentRenderer": [
                                            "commentId": "legacy1",
                                            "contentText": ["runs": [["text": "Old style"]]],
                                            "authorText": ["simpleText": "@old"],
                                            "publishedTimeText": ["runs": [["text": "1 year ago"]]],
                                            "voteCount": ["simpleText": "7"],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            "header": [
                "commentsHeaderRenderer": [
                    "createRenderer": [
                        "commentSimpleboxRenderer": [
                            "submitButton": [
                                "buttonRenderer": [
                                    "serviceEndpoint": [
                                        "createCommentEndpoint": [
                                            "createCommentParams": "create-params-token",
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let page = YouTubeCommentsParser.parse(data)

        let comment = try #require(page.comments.first)
        #expect(comment.id == "legacy1")
        #expect(comment.author == "@old")
        #expect(comment.text == "Old style")
        #expect(page.createCommentParams == "create-params-token")
    }
}
