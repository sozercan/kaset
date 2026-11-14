import Foundation
import Testing
@testable import Kaset

// MARK: - FeedbackLockupFixture

/// Builds a video `lockupViewModel` whose overflow menu matches the signed-in
/// Home shape verified in November 2026 (tokens are placeholders).
private enum FeedbackLockupFixture {
    static func listItem(
        title: String,
        icon: String,
        feedbackToken: String?,
        undoToken: String? = nil,
        responseText: String? = nil
    ) -> [String: Any] {
        var command: [String: Any] = ["clickTrackingParams": "mock-tracking"]
        if let feedbackToken {
            var buttons: [[String: Any]] = []
            if let undoToken {
                buttons.append([
                    "buttonRenderer": [
                        "text": ["simpleText": "Undo"],
                        "serviceEndpoint": [
                            "undoFeedbackEndpoint": ["undoToken": undoToken],
                        ],
                    ],
                ])
            }
            buttons.append([
                "buttonRenderer": [
                    "text": ["simpleText": "Tell us why"],
                    "serviceEndpoint": ["signalServiceEndpoint": [:]],
                ],
            ])
            command["feedbackEndpoint"] = [
                "feedbackToken": feedbackToken,
                "uiActions": ["hideEnclosingContainer": true],
                "actions": [[
                    "replaceEnclosingAction": [
                        "item": [
                            "notificationMultiActionRenderer": [
                                "responseText": ["simpleText": responseText ?? ""],
                                "buttons": buttons,
                            ],
                        ],
                    ],
                ]],
            ]
        } else {
            command["signalServiceEndpoint"] = [:]
        }
        return [
            "listItemViewModel": [
                "title": ["content": title],
                "leadingImage": ["sources": [["clientResource": ["imageName": icon]]]],
                "rendererContext": ["commandContext": ["onTap": ["innertubeCommand": command]]],
            ],
        ]
    }

    static func lockup(videoId: String = "vid-1", listItems: [[String: Any]]) -> [String: Any] {
        [
            "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
            "contentId": videoId,
            "rendererContext": [
                "commandContext": [
                    "onTap": ["innertubeCommand": ["watchEndpoint": ["videoId": videoId]]],
                ],
            ],
            "metadata": [
                "lockupMetadataViewModel": [
                    "title": ["content": "A video"],
                    "menuButton": [
                        "buttonViewModel": [
                            "onTap": [
                                "innertubeCommand": [
                                    "showSheetCommand": [
                                        "panelLoadingStrategy": [
                                            "inlineContent": [
                                                "sheetViewModel": [
                                                    "content": [
                                                        "listViewModel": ["listItems": listItems],
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

    static var homeMenu: [[String: Any]] {
        [
            self.listItem(title: "Add to queue", icon: "ADD_TO_QUEUE_TAIL", feedbackToken: nil),
            self.listItem(
                title: "Not interested",
                icon: "HIDE",
                feedbackToken: "mock-not-interested",
                undoToken: "mock-undo-video",
                responseText: "Video removed"
            ),
            self.listItem(
                title: "Don't recommend channel",
                icon: "REMOVE",
                feedbackToken: "mock-dont-recommend",
                undoToken: "mock-undo-channel",
                responseText: "We won't recommend videos from this channel to you again"
            ),
            self.listItem(title: "Report", icon: "FLAG", feedbackToken: nil),
        ]
    }
}

// MARK: - YouTubeFeedbackParserTests

@Suite("YouTubeFeedbackParser", .tags(.parser))
struct YouTubeFeedbackParserTests {
    @Test("Home menu yields Not interested and Don't recommend channel with undo")
    func parsesHomeMenu() throws {
        let video = try #require(YouTubeItemParser.video(fromLockup: FeedbackLockupFixture.lockup(
            listItems: FeedbackLockupFixture.homeMenu
        )))

        #expect(video.feedbackActions.map(\.kind) == [.notInterested, .dontRecommendChannel])

        let notInterested = try #require(video.feedbackActions.first)
        #expect(notInterested.title == "Not interested")
        #expect(notInterested.feedbackToken == "mock-not-interested")
        #expect(notInterested.undoToken == "mock-undo-video")
        #expect(notInterested.undoTitle == "Undo")
        #expect(notInterested.confirmationText == "Video removed")

        let channel = try #require(video.feedbackActions.last)
        #expect(channel.feedbackToken == "mock-dont-recommend")
        #expect(channel.undoToken == "mock-undo-channel")
    }

    @Test("Watch-history removal is not treated as recommendation feedback")
    func ignoresHistoryRemoval() {
        let lockup = FeedbackLockupFixture.lockup(listItems: [
            FeedbackLockupFixture.listItem(
                title: "Remove from watch history",
                icon: "DELETE",
                feedbackToken: "mock-history-token"
            ),
        ])

        #expect(YouTubeFeedbackParser.actions(fromLockup: lockup).isEmpty)
    }

    @Test("Entries without a feedback token or menu are skipped")
    func skipsIncompleteEntries() {
        let withoutToken = FeedbackLockupFixture.lockup(listItems: [
            FeedbackLockupFixture.listItem(title: "Not interested", icon: "HIDE", feedbackToken: nil),
        ])
        #expect(YouTubeFeedbackParser.actions(fromLockup: withoutToken).isEmpty)

        let withoutMenu: [String: Any] = [
            "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
            "contentId": "vid-1",
            "metadata": ["lockupMetadataViewModel": ["title": ["content": "A video"]]],
        ]
        #expect(YouTubeItemParser.video(fromLockup: withoutMenu)?.feedbackActions.isEmpty == true)
    }

    @Test("Feedback without an undo button still parses")
    func parsesWithoutUndo() throws {
        let lockup = FeedbackLockupFixture.lockup(listItems: [
            FeedbackLockupFixture.listItem(title: "Not interested", icon: "HIDE", feedbackToken: "mock-token"),
        ])

        let action = try #require(YouTubeFeedbackParser.actions(fromLockup: lockup).first)
        #expect(action.undoToken == nil)
        #expect(action.undoTitle == nil)
    }
}

// MARK: - YouTubeHomeFeedbackTests

@Suite("YouTubeHomeViewModel feedback", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct YouTubeHomeFeedbackTests {
    let mockClient: MockYouTubeClient
    let sut: YouTubeHomeViewModel

    init() {
        self.mockClient = MockYouTubeClient()
        self.sut = YouTubeHomeViewModel(client: self.mockClient)
    }

    private static func action(
        _ kind: YouTubeFeedbackAction.Kind,
        token: String = "mock-feedback",
        undoToken: String? = "mock-undo"
    ) -> YouTubeFeedbackAction {
        YouTubeFeedbackAction(
            kind: kind,
            title: kind == .notInterested ? "Not interested" : "Don't recommend channel",
            feedbackToken: token,
            undoToken: undoToken,
            confirmationText: "Video removed",
            undoTitle: "Undo"
        )
    }

    private static func video(_ id: String, channel: String) -> YouTubeVideo {
        YouTubeVideo(videoId: id, title: id, channelName: channel, channelId: channel)
    }

    private func loadHome(videos: [YouTubeVideo], continuation: YouTubeFeed? = nil) async {
        self.mockClient.homeFeed = YouTubeFeed(videos: videos, continuation: nil)
        self.mockClient.homeFeedContinuation = continuation
        await self.sut.load()
    }

    @Test("Not interested sends the token and hides only that video")
    func notInterestedHidesVideo() async {
        let videos = [
            Self.video("a", channel: "UC1"),
            Self.video("b", channel: "UC1"),
            Self.video("c", channel: "UC2"),
        ]
        await self.loadHome(videos: videos)

        await self.sut.sendFeedback(Self.action(.notInterested), for: videos[0])

        #expect(self.mockClient.sentFeedbackTokens == ["mock-feedback"])
        #expect(self.sut.videos.map(\.videoId) == ["b", "c"])
        #expect(self.sut.lastDismissal?.action.kind == .notInterested)
    }

    @Test("Don't recommend channel hides every card from that channel")
    func dontRecommendChannelHidesChannel() async {
        let videos = [
            Self.video("a", channel: "UC1"),
            Self.video("b", channel: "UC2"),
            Self.video("c", channel: "UC1"),
        ]
        await self.loadHome(videos: videos)

        await self.sut.sendFeedback(Self.action(.dontRecommendChannel), for: videos[0])

        #expect(self.sut.videos.map(\.videoId) == ["b"])
    }

    @Test("Rejected feedback keeps the cards and reports a failure")
    func failureKeepsCards() async {
        let videos = [Self.video("a", channel: "UC1"), Self.video("b", channel: "UC2")]
        await self.loadHome(videos: videos)
        self.mockClient.feedbackError = YTMusicError.networkError(underlying: URLError(.timedOut))

        await self.sut.sendFeedback(Self.action(.notInterested), for: videos[0])

        #expect(self.sut.videos.map(\.videoId) == ["a", "b"])
        #expect(self.sut.lastDismissal == nil)
        #expect(self.sut.feedbackFailureCount == 1)
    }

    @Test("Undo sends the undo token and restores cards in place")
    func undoRestoresCards() async {
        let videos = [
            Self.video("a", channel: "UC1"),
            Self.video("b", channel: "UC2"),
            Self.video("c", channel: "UC1"),
        ]
        await self.loadHome(videos: videos)
        await self.sut.sendFeedback(Self.action(.dontRecommendChannel), for: videos[2])

        await self.sut.undoLastDismissal()

        #expect(self.mockClient.sentFeedbackTokens == ["mock-feedback", "mock-undo"])
        #expect(self.sut.videos.map(\.videoId) == ["a", "b", "c"])
        #expect(self.sut.lastDismissal == nil)
    }

    @Test("Undo restores cards even if the confirmation closes while the request is in flight")
    func undoSurvivesClosedConfirmation() async throws {
        let videos = [Self.video("a", channel: "UC1"), Self.video("b", channel: "UC2")]
        await self.loadHome(
            videos: videos,
            continuation: YouTubeFeed(videos: [Self.video("c", channel: "UC1")], continuation: nil)
        )
        await self.sut.sendFeedback(Self.action(.dontRecommendChannel), for: videos[0])
        let dismissal = try #require(self.sut.lastDismissal)
        self.mockClient.beforeFeedbackReturn = { [sut = self.sut] in
            sut.clearLastDismissal(id: dismissal.id)
        }

        await self.sut.undoLastDismissal()

        #expect(self.sut.videos.map(\.videoId) == ["a", "b"])
        #expect(self.sut.lastDismissal == nil)

        // The channel is no longer filtered from later pages either.
        await self.sut.loadMore()
        #expect(self.sut.videos.map(\.videoId) == ["a", "b", "c"])
    }

    @Test("Dismissed channels stay out of later continuation pages")
    func continuationFiltersDismissedChannel() async {
        let videos = [Self.video("a", channel: "UC1"), Self.video("b", channel: "UC2")]
        await self.loadHome(
            videos: videos,
            continuation: YouTubeFeed(
                videos: [Self.video("c", channel: "UC1"), Self.video("d", channel: "UC3")],
                continuation: nil
            )
        )
        await self.sut.sendFeedback(Self.action(.dontRecommendChannel), for: videos[0])

        await self.sut.loadMore()

        #expect(self.sut.videos.map(\.videoId) == ["b", "d"])
    }

    @Test("Feedback removes the video from rails and drops emptied rails")
    func feedbackUpdatesRails() async {
        let shelfVideo = Self.video("s1", channel: "UC9")
        self.mockClient.homeShelves = [
            YouTubeHomeSection(id: "shelf-1", title: "Shelf", videos: [shelfVideo], kind: .shelf),
        ]
        await self.loadHome(videos: [Self.video("a", channel: "UC1")])
        #expect(self.sut.sections.map(\.id) == ["shelf-1"])

        await self.sut.sendFeedback(Self.action(.notInterested), for: shelfVideo)

        #expect(self.sut.sections.isEmpty)
        #expect(self.sut.videos.map(\.videoId) == ["a"])
    }
}
