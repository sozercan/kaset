import Foundation
import Testing
@testable import Kaset

extension RadioQueueLikeStatusParserTests {
    @Test("Parse radio queue decodes exact row-local like statuses")
    func parseRadioQueueDecodesExactLikeStatuses() {
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
        let renderer: [String: Any] = [
            "playlistPanelVideoRenderer": [
                "videoId": "menu-less-video",
                "title": ["runs": [["text": "Menu-less Track"]]],
            ],
        ]
        let data = Self.makeRadioResponse(contents: [renderer])
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
}
