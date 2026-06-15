import Foundation
import Testing
@testable import Kaset

/// Unit tests for `YouTubeItemParser` with handcrafted renderer payloads.
@Suite("YouTubeItemParser", .tags(.parser))
struct YouTubeItemParserTests {
    // MARK: - videoRenderer

    @Test("Parses a videoRenderer with full metadata")
    func parsesVideoRenderer() throws {
        let renderer: [String: Any] = [
            "videoId": "abc123",
            "title": ["runs": [["text": "Test Video"]]],
            "ownerText": [
                "runs": [[
                    "text": "Test Channel",
                    "navigationEndpoint": ["browseEndpoint": ["browseId": "UCxyz"]],
                ]],
            ],
            "lengthText": ["simpleText": "12:34"],
            "shortViewCountText": ["simpleText": "1.2K views"],
            "publishedTimeText": ["simpleText": "3 days ago"],
            "thumbnail": [
                "thumbnails": [
                    ["url": "https://example.com/small.jpg", "width": 360, "height": 202],
                    ["url": "https://example.com/large.jpg", "width": 720, "height": 404],
                ],
            ],
        ]

        let video = try #require(YouTubeItemParser.video(fromVideoRenderer: renderer))
        #expect(video.videoId == "abc123")
        #expect(video.title == "Test Video")
        #expect(video.channelName == "Test Channel")
        #expect(video.channelId == "UCxyz")
        #expect(video.lengthText == "12:34")
        #expect(video.viewCountText == "1.2K views")
        #expect(video.publishedText == "3 days ago")
        #expect(video.thumbnailURL?.absoluteString == "https://example.com/large.jpg")
        #expect(video.isLive == false)
    }

    @Test("Parses a legacy playlistVideoRenderer via the item dispatch")
    func parsesPlaylistVideoRenderer() throws {
        let item: [String: Any] = [
            "playlistVideoRenderer": [
                "videoId": "plv123",
                "title": ["runs": [["text": "Playlist Video"]]],
                "shortBylineText": [
                    "runs": [[
                        "text": "Some Channel",
                        "navigationEndpoint": ["browseEndpoint": ["browseId": "UCplv"]],
                    ]],
                ],
                "lengthText": ["simpleText": "4:56"],
            ],
        ]

        let video = try #require(YouTubeItemParser.video(fromAnyItem: item))
        #expect(video.videoId == "plv123")
        #expect(video.title == "Playlist Video")
        #expect(video.channelName == "Some Channel")
        #expect(video.lengthText == "4:56")
    }

    @Test("Rejects a videoRenderer without a videoId")
    func rejectsVideoRendererWithoutId() {
        let renderer: [String: Any] = [
            "title": ["runs": [["text": "No ID"]]],
        ]
        #expect(YouTubeItemParser.video(fromVideoRenderer: renderer) == nil)
    }

    @Test("Detects live streams from the LIVE badge")
    func detectsLiveBadge() throws {
        let renderer: [String: Any] = [
            "videoId": "live123",
            "title": ["runs": [["text": "Live Stream"]]],
            "badges": [
                ["metadataBadgeRenderer": ["style": "BADGE_STYLE_TYPE_LIVE_NOW", "label": "LIVE"]],
            ],
        ]
        let video = try #require(YouTubeItemParser.video(fromVideoRenderer: renderer))
        #expect(video.isLive)
    }

    // MARK: - lockupViewModel

    @Test("Parses a video lockupViewModel")
    func parsesVideoLockup() throws {
        let lockup: [String: Any] = [
            "contentId": "lockup123",
            "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
            "contentImage": [
                "thumbnailViewModel": [
                    "image": [
                        "sources": [
                            ["url": "https://example.com/thumb.jpg", "width": 640, "height": 360],
                        ],
                    ],
                    "overlays": [
                        [
                            "thumbnailBottomOverlayViewModel": [
                                "badges": [
                                    ["thumbnailBadgeViewModel": ["text": "17:10"]],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            "metadata": [
                "lockupMetadataViewModel": [
                    "title": ["content": "Lockup Video"],
                    "metadata": [
                        "contentMetadataViewModel": [
                            "metadataRows": [
                                ["metadataParts": [["text": ["content": "Lockup Channel"]]]],
                                [
                                    "metadataParts": [
                                        ["text": ["content": "1M views"]],
                                        ["text": ["content": "9 months ago"]],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            "rendererContext": [
                "commandContext": [
                    "onTap": [
                        "innertubeCommand": [
                            "watchEndpoint": ["videoId": "lockup123"],
                        ],
                    ],
                ],
            ],
        ]

        let video = try #require(YouTubeItemParser.video(fromLockup: lockup))
        #expect(video.videoId == "lockup123")
        #expect(video.title == "Lockup Video")
        #expect(video.channelName == "Lockup Channel")
        #expect(video.viewCountText == "1M views")
        #expect(video.publishedText == "9 months ago")
        #expect(video.lengthText == "17:10")
        #expect(video.thumbnailURL?.absoluteString == "https://example.com/thumb.jpg")
    }

    @Test("Video parser rejects playlist lockups and vice versa")
    func lockupContentTypeMismatch() {
        let playlistLockup: [String: Any] = [
            "contentId": "PLabc",
            "contentType": "LOCKUP_CONTENT_TYPE_PLAYLIST",
            "metadata": ["lockupMetadataViewModel": ["title": ["content": "A Playlist"]]],
        ]
        #expect(YouTubeItemParser.video(fromLockup: playlistLockup) == nil)

        let videoLockup: [String: Any] = [
            "contentId": "abc",
            "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
            "metadata": ["lockupMetadataViewModel": ["title": ["content": "A Video"]]],
        ]
        #expect(YouTubeItemParser.playlist(fromLockup: videoLockup) == nil)
    }

    @Test("Parses a playlist lockupViewModel")
    func parsesPlaylistLockup() throws {
        let lockup: [String: Any] = [
            "contentId": "PLabc",
            "contentType": "LOCKUP_CONTENT_TYPE_PLAYLIST",
            "metadata": [
                "lockupMetadataViewModel": [
                    "title": ["content": "My Playlist"],
                ],
            ],
            "rendererContext": [
                "commandContext": [
                    "onTap": [
                        "innertubeCommand": [
                            "watchEndpoint": ["playlistId": "PLabc", "videoId": "first1"],
                        ],
                    ],
                ],
            ],
        ]

        let playlist = try #require(YouTubeItemParser.playlist(fromLockup: lockup))
        #expect(playlist.playlistId == "PLabc")
        #expect(playlist.title == "My Playlist")
        #expect(playlist.firstVideoId == "first1")
    }

    // MARK: - Watched progress

    /// Builds a minimal video `lockupViewModel` whose bottom overlay optionally
    /// carries a duration badge and/or a resume `progressBar`.
    private func makeProgressLockup(
        badgeText: String? = "32:23",
        startPercent: Any? = nil
    ) -> [String: Any] {
        var bottomOverlay: [String: Any] = [:]
        if let badgeText {
            bottomOverlay["badges"] = [["thumbnailBadgeViewModel": ["text": badgeText]]]
        }
        if let startPercent {
            bottomOverlay["progressBar"] = [
                "thumbnailOverlayProgressBarViewModel": ["startPercent": startPercent],
            ]
        }
        return [
            "contentId": "progress123",
            "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
            "contentImage": [
                "thumbnailViewModel": [
                    "overlays": [["thumbnailBottomOverlayViewModel": bottomOverlay]],
                ],
            ],
            "metadata": [
                "lockupMetadataViewModel": ["title": ["content": "Progress Video"]],
            ],
        ]
    }

    @Test("Parses startPercent from a lockup progress overlay")
    func parsesLockupWatchedPercent() throws {
        let lockup = self.makeProgressLockup(startPercent: 77)
        let video = try #require(YouTubeItemParser.video(fromLockup: lockup))
        #expect(video.watchedPercent == 77)
    }

    @Test("Unwatched lockup has no progress and still parses its duration badge")
    func unwatchedLockupHasNilProgress() throws {
        let lockup = self.makeProgressLockup(startPercent: nil)
        let video = try #require(YouTubeItemParser.video(fromLockup: lockup))
        #expect(video.watchedPercent == nil)
        // Reading the sibling progressBar key must not disturb badge parsing.
        #expect(video.lengthText == "32:23")
    }

    @Test("Clamps and coerces an out-of-range Double startPercent")
    func clampsLockupWatchedPercent() throws {
        let lockup = self.makeProgressLockup(startPercent: 150.0)
        let video = try #require(YouTubeItemParser.video(fromLockup: lockup))
        #expect(video.watchedPercent == 100)
    }

    @Test("Treats a zero-percent progress overlay as unwatched")
    func zeroPercentLockupIsUnwatched() throws {
        let lockup = self.makeProgressLockup(startPercent: 0)
        let video = try #require(YouTubeItemParser.video(fromLockup: lockup))
        #expect(video.watchedPercent == nil)
    }

    @Test("Parses percentDurationWatched from a legacy videoRenderer")
    func parsesLegacyWatchedPercent() throws {
        let renderer: [String: Any] = [
            "videoId": "legacy123",
            "title": ["runs": [["text": "Legacy Video"]]],
            "thumbnailOverlays": [
                ["thumbnailOverlayResumePlaybackRenderer": ["percentDurationWatched": 100]],
            ],
        ]
        let video = try #require(YouTubeItemParser.video(fromVideoRenderer: renderer))
        #expect(video.watchedPercent == 100)
    }

    // MARK: - channelRenderer

    @Test("Parses a channelRenderer with swapped handle/subscriber fields")
    func parsesChannelRendererSwappedFields() throws {
        // June 2026: subscriberCountText carries the handle and
        // videoCountText carries the subscriber count.
        let renderer: [String: Any] = [
            "channelId": "UCabc",
            "title": ["simpleText": "Test Channel"],
            "subscriberCountText": ["simpleText": "@testchannel"],
            "videoCountText": ["simpleText": "1M subscribers"],
            "thumbnail": [
                "thumbnails": [
                    ["url": "//example.com/avatar.jpg", "width": 88, "height": 88],
                ],
            ],
        ]

        let channel = try #require(YouTubeItemParser.channel(fromChannelRenderer: renderer))
        #expect(channel.channelId == "UCabc")
        #expect(channel.name == "Test Channel")
        #expect(channel.handle == "@testchannel")
        #expect(channel.subscriberCountText == "1M subscribers")
        // Protocol-relative URL is normalized to https.
        #expect(channel.thumbnailURL?.absoluteString == "https://example.com/avatar.jpg")
    }

    // MARK: - Text extraction

    // MARK: - Shorts

    @Test("Detects Shorts from reel endpoints and /shorts/ URLs")
    func detectsShorts() throws {
        let reelRenderer: [String: Any] = [
            "videoId": "short1",
            "title": ["runs": [["text": "A Short"]]],
            "navigationEndpoint": ["reelWatchEndpoint": ["videoId": "short1"]],
        ]
        let urlRenderer: [String: Any] = [
            "videoId": "short2",
            "title": ["runs": [["text": "Another Short"]]],
            "navigationEndpoint": [
                "commandMetadata": ["webCommandMetadata": ["url": "/shorts/short2"]],
            ],
        ]
        let regularRenderer: [String: Any] = [
            "videoId": "regular",
            "title": ["runs": [["text": "Regular"]]],
            "navigationEndpoint": [
                "commandMetadata": ["webCommandMetadata": ["url": "/watch?v=regular"]],
            ],
        ]

        #expect(try #require(YouTubeItemParser.video(fromVideoRenderer: reelRenderer)).isShort)
        #expect(try #require(YouTubeItemParser.video(fromVideoRenderer: urlRenderer)).isShort)
        #expect(try #require(YouTubeItemParser.video(fromVideoRenderer: regularRenderer)).isShort == false)
    }

    @Test("Parses a shortsLockupViewModel")
    func parsesShortsLockup() throws {
        let lockup: [String: Any] = [
            "entityId": "shorts-shelf-item-X4dGtpUD3gA",
            "onTap": [
                "innertubeCommand": [
                    "reelWatchEndpoint": ["videoId": "X4dGtpUD3gA"],
                ],
            ],
            "overlayMetadata": [
                "primaryText": ["content": "A Short Title"],
                "secondaryText": ["content": "2.1M views"],
            ],
            "thumbnailViewModel": [
                "image": [
                    "sources": [["url": "https://example.com/short.jpg", "width": 405, "height": 720]],
                ],
            ],
        ]

        let short = try #require(YouTubeItemParser.short(fromShortsLockup: lockup))
        #expect(short.videoId == "X4dGtpUD3gA")
        #expect(short.title == "A Short Title")
        #expect(short.viewCountText == "2.1M views")
        #expect(short.isShort)
    }

    @Test("Feed collection separates Shorts from regular videos")
    func feedSeparatesShorts() {
        let data: [String: Any] = [
            "contents": [
                [
                    "videoRenderer": [
                        "videoId": "regular1",
                        "title": ["runs": [["text": "Regular Video"]]],
                    ],
                ],
                [
                    "videoRenderer": [
                        "videoId": "short1",
                        "title": ["runs": [["text": "A Short"]]],
                        "navigationEndpoint": ["reelWatchEndpoint": ["videoId": "short1"]],
                    ],
                ],
                [
                    "shortsLockupViewModel": [
                        "onTap": ["innertubeCommand": ["reelWatchEndpoint": ["videoId": "short2"]]],
                        "overlayMetadata": ["primaryText": ["content": "Shelf Short"]],
                    ],
                ],
            ],
        ]

        let feed = YouTubeFeedParser.parse(data)

        #expect(feed.videos.map(\.videoId) == ["regular1"])
        #expect(Set(feed.shorts.map(\.videoId)) == ["short1", "short2"])
    }

    @Test("Extracts text from all three InnerTube encodings")
    func textExtraction() {
        #expect(YouTubeItemParser.text(from: ["simpleText": "simple"]) == "simple")
        #expect(YouTubeItemParser.text(from: ["runs": [["text": "a"], ["text": "b"]]]) == "ab")
        #expect(YouTubeItemParser.text(from: ["content": "vm-content"]) == "vm-content")
        #expect(YouTubeItemParser.text(from: nil) == nil)
        #expect(YouTubeItemParser.text(from: ["runs": [[String: Any]]()]) == nil)
    }
}
