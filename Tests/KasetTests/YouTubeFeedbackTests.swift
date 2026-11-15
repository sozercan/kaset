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

    @Test("Undo keeps a card hidden when another dismissal still covers it")
    func undoRespectsRemainingDismissals() async {
        let videos = [
            Self.video("a", channel: "UC1"),
            Self.video("b", channel: "UC1"),
            Self.video("c", channel: "UC2"),
        ]
        await self.loadHome(videos: videos)
        await self.sut.sendFeedback(Self.action(.notInterested, token: "mock-a", undoToken: "mock-undo-a"), for: videos[0])
        #expect(self.sut.videos.map(\.videoId) == ["b", "c"])

        // While the Undo for "a" is in flight, its whole channel is dismissed.
        self.mockClient.beforeFeedbackReturn = { [sut = self.sut, mockClient = self.mockClient] in
            mockClient.beforeFeedbackReturn = nil
            await sut.sendFeedback(Self.action(.dontRecommendChannel, token: "mock-b"), for: videos[1])
        }
        await self.sut.undoLastDismissal()

        #expect(self.mockClient.sentFeedbackTokens == ["mock-a", "mock-undo-a", "mock-b"])
        #expect(self.sut.videos.map(\.videoId) == ["c"])
    }

    @Test("Undo brings back a rail the dismissal emptied, in its place")
    func undoRestoresEmptiedRail() async {
        let first = Self.video("s1", channel: "UC8")
        let only = Self.video("s2", channel: "UC9")
        self.mockClient.homeShelves = [
            YouTubeHomeSection(id: "shelf-1", title: "First", videos: [first], kind: .shelf),
            YouTubeHomeSection(id: "shelf-2", title: "Second", videos: [only], kind: .shelf),
        ]
        await self.loadHome(videos: [Self.video("a", channel: "UC1")])
        await self.sut.sendFeedback(Self.action(.notInterested), for: only)
        #expect(self.sut.sections.map(\.id) == ["shelf-1"])

        await self.sut.undoLastDismissal()

        #expect(self.sut.sections.map(\.id) == ["shelf-1", "shelf-2"])
        #expect(self.sut.sections.last?.videos.map(\.videoId) == ["s2"])
    }

    @Test("Cards held back by an undo return once the covering dismissal is undone")
    func heldCardsReturnAfterCoveringUndo() async {
        let videos = [
            Self.video("a", channel: "UC1"),
            Self.video("b", channel: "UC1"),
            Self.video("c", channel: "UC2"),
        ]
        await self.loadHome(videos: videos)
        await self.sut.sendFeedback(Self.action(.notInterested, token: "mock-a", undoToken: "mock-undo-a"), for: videos[0])
        self.mockClient.beforeFeedbackReturn = { [sut = self.sut, mockClient = self.mockClient] in
            mockClient.beforeFeedbackReturn = nil
            await sut.sendFeedback(
                Self.action(.dontRecommendChannel, token: "mock-b", undoToken: "mock-undo-b"),
                for: videos[1]
            )
        }
        await self.sut.undoLastDismissal()
        #expect(self.sut.videos.map(\.videoId) == ["c"])

        // Undoing the channel dismissal releases "b" and the held "a".
        await self.sut.undoLastDismissal()

        #expect(self.sut.videos.map(\.videoId) == ["a", "b", "c"])
        #expect(self.sut.lastDismissal == nil)
    }

    @Test("Cards keep their order when dismissals and undos overlap")
    func overlappingUndosKeepCardOrder() async {
        let videos = ["a", "b", "c", "d"].map { Self.video($0, channel: "UC-\($0)") }
        await self.loadHome(videos: videos)
        await self.sut.sendFeedback(Self.action(.notInterested, token: "mock-b", undoToken: "mock-undo-b"), for: videos[1])
        // While the Undo for "b" is in flight, "a" is dismissed.
        self.mockClient.beforeFeedbackReturn = { [sut = self.sut, mockClient = self.mockClient] in
            mockClient.beforeFeedbackReturn = nil
            await sut.sendFeedback(Self.action(.notInterested, token: "mock-a", undoToken: "mock-undo-a"), for: videos[0])
        }
        await self.sut.undoLastDismissal()
        #expect(self.sut.videos.map(\.videoId) == ["b", "c", "d"])

        await self.sut.undoLastDismissal()

        #expect(self.sut.videos.map(\.videoId) == ["a", "b", "c", "d"])
    }

    @Test("Rails restored out of order go back to their original places")
    func railsRestoreInOrderAfterOutOfOrderUndo() async {
        let first = Self.video("s0", channel: "UC7")
        let middle = Self.video("s1", channel: "UC8")
        let last = Self.video("s2", channel: "UC9")
        self.mockClient.homeShelves = [
            YouTubeHomeSection(id: "shelf-0", title: "Zero", videos: [first], kind: .shelf),
            YouTubeHomeSection(id: "shelf-1", title: "One", videos: [middle], kind: .shelf),
            YouTubeHomeSection(id: "shelf-2", title: "Two", videos: [last], kind: .shelf),
        ]
        await self.loadHome(videos: [Self.video("a", channel: "UC1")])
        await self.sut.sendFeedback(Self.action(.notInterested, token: "mock-1", undoToken: "mock-undo-1"), for: middle)
        // While the middle rail's Undo is in flight, the first rail is emptied.
        self.mockClient.beforeFeedbackReturn = { [sut = self.sut, mockClient = self.mockClient] in
            mockClient.beforeFeedbackReturn = nil
            await sut.sendFeedback(Self.action(.notInterested, token: "mock-0", undoToken: "mock-undo-0"), for: first)
        }
        await self.sut.undoLastDismissal()
        #expect(self.sut.sections.map(\.id) == ["shelf-1", "shelf-2"])

        await self.sut.undoLastDismissal()

        #expect(self.sut.sections.map(\.id) == ["shelf-0", "shelf-1", "shelf-2"])
    }

    @Test("A card whose rail another dismissal emptied during its undo brings the rail back")
    func cardReturnsWithRailEmptiedDuringUndo() async {
        let kept = Self.video("x", channel: "UC1")
        let hidden = Self.video("y", channel: "UC2")
        self.mockClient.homeShelves = [
            YouTubeHomeSection(id: "rail", title: "Rail", videos: [kept, hidden], kind: .shelf),
        ]
        await self.loadHome(videos: [Self.video("a", channel: "UC3")])
        await self.sut.sendFeedback(Self.action(.notInterested, token: "mock-y", undoToken: "mock-undo-y"), for: hidden)
        // While that Undo is in flight, the rail's last card goes with its channel.
        self.mockClient.beforeFeedbackReturn = { [sut = self.sut, mockClient = self.mockClient] in
            mockClient.beforeFeedbackReturn = nil
            await sut.sendFeedback(
                Self.action(.dontRecommendChannel, token: "mock-x", undoToken: "mock-undo-x"),
                for: kept
            )
        }
        // Nothing covers "y" anymore, so its Undo brings the rail back for it.
        await self.sut.undoLastDismissal()
        #expect(self.sut.sections.map(\.id) == ["rail"])
        #expect(self.sut.sections.first?.videos.map(\.videoId) == ["y"])

        await self.sut.undoLastDismissal()

        #expect(self.sut.sections.first?.videos.map(\.videoId) == ["x", "y"])
    }

    @Test("Rails that shared a neighbor come back in their original order")
    func railsSharingANeighborRestoreInOrder() async {
        let railA = Self.video("ra", channel: "UC7")
        let railB = Self.video("rb", channel: "UC8")
        let railC = Self.video("rc", channel: "UC9")
        self.mockClient.homeShelves = [
            YouTubeHomeSection(id: "A", title: "A", videos: [railA], kind: .shelf),
            YouTubeHomeSection(id: "B", title: "B", videos: [railB], kind: .shelf),
            YouTubeHomeSection(id: "C", title: "C", videos: [railC], kind: .shelf),
        ]
        await self.loadHome(videos: [Self.video("a", channel: "UC1")])
        await self.sut.sendFeedback(Self.action(.notInterested, token: "mock-b", undoToken: "mock-undo-b"), for: railB)
        self.mockClient.beforeFeedbackReturn = { [sut = self.sut, mockClient = self.mockClient] in
            mockClient.beforeFeedbackReturn = nil
            await sut.sendFeedback(Self.action(.notInterested, token: "mock-c", undoToken: "mock-undo-c"), for: railC)
        }
        await self.sut.undoLastDismissal()
        #expect(self.sut.sections.map(\.id) == ["A", "B"])

        await self.sut.undoLastDismissal()

        #expect(self.sut.sections.map(\.id) == ["A", "B", "C"])
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

// MARK: - YouTubeFeedbackDismissalsTests

@Suite("YouTubeFeedbackDismissals", .tags(.viewModel))
struct YouTubeFeedbackDismissalsTests {
    private static let channelAction = YouTubeFeedbackAction(
        kind: .dontRecommendChannel,
        title: "Don't recommend channel",
        feedbackToken: "mock-feedback",
        undoToken: "mock-undo",
        confirmationText: nil,
        undoTitle: nil
    )

    @Test("A restored rail goes before rails that appeared after it was removed")
    func restoredRailPrecedesLaterRails() {
        var dismissals = YouTubeFeedbackDismissals()
        let action = YouTubeFeedbackAction(
            kind: .notInterested,
            title: "Not interested",
            feedbackToken: "mock-feedback",
            undoToken: "mock-undo",
            confirmationText: nil,
            undoTitle: nil
        )
        func rail(_ id: String) -> YouTubeHomeSection {
            YouTubeHomeSection(id: id, title: id, videos: [YouTubeVideo(videoId: "v-\(id)", title: id)], kind: .topic)
        }
        var videos: [YouTubeVideo] = []
        var sections = [rail("A"), rail("B")]
        let dismissal = dismissals.dismiss(action, for: sections[1].videos[0], videos: &videos, sections: &sections)
        #expect(sections.map(\.id) == ["A"])

        // More topic rails load before the undo lands.
        sections += [rail("C"), rail("D")]
        dismissals.undo(dismissal, videos: &videos, sections: &sections)

        #expect(sections.map(\.id) == ["A", "B", "C", "D"])
    }

    @Test("A channel stays filtered until every dismissal for it is undone")
    func channelCountsAcrossDismissals() {
        var dismissals = YouTubeFeedbackDismissals()
        let first = YouTubeVideo(videoId: "a", title: "a", channelId: "UC1")
        let second = YouTubeVideo(videoId: "b", title: "b", channelId: "UC1")
        let later = YouTubeVideo(videoId: "c", title: "c", channelId: "UC1")
        var videos = [first]
        var sections: [YouTubeHomeSection] = []
        let one = dismissals.dismiss(Self.channelAction, for: first, videos: &videos, sections: &sections)
        videos = [second]
        let two = dismissals.dismiss(Self.channelAction, for: second, videos: &videos, sections: &sections)

        dismissals.undo(one, videos: &videos, sections: &sections)
        #expect(dismissals.isDismissed(later))

        dismissals.undo(two, videos: &videos, sections: &sections)
        #expect(!dismissals.isDismissed(later))
    }
}
