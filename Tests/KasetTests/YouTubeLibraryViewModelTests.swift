import Foundation
import Testing
@testable import Kaset

// MARK: - YouTubeSubscriptionsViewModelTests

@Suite("YouTubeSubscriptionsViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct YouTubeSubscriptionsViewModelTests {
    @Test("Load fetches the feed and channel rail")
    func loadFetchesFeedAndRail() async {
        let client = MockYouTubeClient()
        client.subscriptionsFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 4),
            continuation: "token"
        )
        client.subscribedChannels = [
            YouTubeChannel(channelId: "UC1", name: "One"),
            YouTubeChannel(channelId: "UC2", name: "Two"),
        ]
        let sut = YouTubeSubscriptionsViewModel(client: client)

        await sut.load()

        #expect(sut.loadingState == .loaded)
        #expect(sut.videos.count == 4)
        #expect(sut.channels.count == 2)
        #expect(sut.hasMoreVideos)
    }

    @Test("LoadMore appends via the generic feed continuation")
    func loadMoreAppends() async {
        let client = MockYouTubeClient()
        client.subscriptionsFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 2),
            continuation: "token-1"
        )
        client.feedContinuation = YouTubeFeed(
            videos: [MockYouTubeClient.makeVideo(videoId: "more-1")],
            continuation: nil
        )
        let sut = YouTubeSubscriptionsViewModel(client: client)
        await sut.load()

        await sut.loadMore()

        #expect(client.lastFeedContinuation == "token-1")
        #expect(sut.videos.count == 3)
        #expect(sut.hasMoreVideos == false)
    }

    @Test("LoadMore advances pagination trigger for duplicate-only pages")
    func loadMoreAdvancesPaginationTriggerForDuplicateOnlyPage() async {
        let client = MockYouTubeClient()
        let duplicate = MockYouTubeClient.makeVideo(videoId: "video-0")
        client.subscriptionsFeed = YouTubeFeed(videos: [duplicate], continuation: "token-1")
        client.feedContinuation = YouTubeFeed(videos: [duplicate], continuation: "token-2")
        let sut = YouTubeSubscriptionsViewModel(client: client)
        await sut.load()
        let triggerAfterLoad = sut.paginationTrigger

        await sut.loadMore()

        #expect(sut.videos.map(\.videoId) == ["video-0"])
        #expect(sut.hasMoreVideos)
        #expect(sut.paginationTrigger > triggerAfterLoad)
    }

    @Test("Feed failure surfaces an error even if the rail succeeds")
    func feedFailureSurfacesError() async {
        let client = MockYouTubeClient()
        client.error = YTMusicError.authExpired
        let sut = YouTubeSubscriptionsViewModel(client: client)

        await sut.load()

        if case .error = sut.loadingState {
            // expected
        } else {
            Issue.record("Expected error state, got \(sut.loadingState)")
        }
    }
}

// MARK: - YouTubeHistoryViewModelTests

@Suite("YouTubeHistoryViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct YouTubeHistoryViewModelTests {
    @Test("Load populates history videos")
    func loadPopulates() async {
        let client = MockYouTubeClient()
        client.historyFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 3),
            continuation: nil
        )
        let sut = YouTubeHistoryViewModel(client: client)

        await sut.load()

        #expect(sut.loadingState == .loaded)
        #expect(sut.videos.count == 3)
        #expect(sut.hasMoreVideos == false)
    }

    @Test("LoadMore advances pagination trigger for duplicate-only pages")
    func loadMoreAdvancesPaginationTriggerForDuplicateOnlyPage() async {
        let client = MockYouTubeClient()
        let duplicate = MockYouTubeClient.makeVideo(videoId: "video-0")
        client.historyFeed = YouTubeFeed(videos: [duplicate], continuation: "token-1")
        client.feedContinuation = YouTubeFeed(videos: [duplicate], continuation: "token-2")
        let sut = YouTubeHistoryViewModel(client: client)
        await sut.load()
        let triggerAfterLoad = sut.paginationTrigger

        await sut.loadMore()

        #expect(sut.videos.map(\.videoId) == ["video-0"])
        #expect(sut.hasMoreVideos)
        #expect(sut.paginationTrigger > triggerAfterLoad)
    }
}

// MARK: - YouTubePlaylistsViewModelTests

@Suite("YouTubePlaylistsViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct YouTubePlaylistsViewModelTests {
    @Test("Load populates the user's playlists")
    func loadPopulates() async {
        let client = MockYouTubeClient()
        client.userPlaylists = [
            YouTubePlaylist(playlistId: "PL1", title: "First"),
            YouTubePlaylist(playlistId: "PL2", title: "Second"),
        ]
        let sut = YouTubePlaylistsViewModel(client: client)

        await sut.load()

        #expect(sut.loadingState == .loaded)
        #expect(sut.playlists.map(\.playlistId) == ["PL1", "PL2"])
    }
}

// MARK: - YouTubeExploreViewModelTests

@Suite("YouTubeExploreViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct YouTubeExploreViewModelTests {
    @Test("Load fetches the selected destination feed")
    func loadFetchesDestination() async {
        let client = MockYouTubeClient()
        client.destinationFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 2),
            continuation: nil
        )
        let sut = YouTubeExploreViewModel(client: client)
        sut.selectedDestination = .news

        await sut.load()

        #expect(client.lastDestination == .news)
        #expect(sut.videos.count == 2)
        #expect(sut.loadingState == .loaded)
    }

    @Test("Switching destinations resets content")
    func switchingResets() async {
        let client = MockYouTubeClient()
        client.destinationFeed = YouTubeFeed(
            videos: MockYouTubeClient.makeVideos(count: 2),
            continuation: nil
        )
        let sut = YouTubeExploreViewModel(client: client)
        await sut.load()
        #expect(!sut.videos.isEmpty)

        sut.selectedDestination = .sports

        #expect(sut.videos.isEmpty)
        #expect(sut.loadingState == .idle)
    }
}

// MARK: - YouTubeWatchViewModelActionTests

@Suite("YouTubeWatchViewModel actions", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct YouTubeWatchViewModelActionTests {
    @Test("Comments load after watch-next and posting clears on success")
    func commentsFlow() async {
        let client = MockYouTubeClient()
        client.watchNextData = WatchNextData(
            videoTitle: "Title",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            commentsContinuation: "comments-token"
        )
        client.commentsPage = YouTubeCommentsPage(
            comments: [
                YouTubeComment(
                    id: "c1",
                    author: "@a",
                    authorAvatarURL: nil,
                    text: "Hi",
                    publishedText: nil,
                    likeCountText: nil
                ),
            ],
            continuation: nil,
            createCommentParams: "create-params"
        )
        let sut = YouTubeWatchViewModel(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            client: client
        )

        await sut.load()

        #expect(client.lastCommentsContinuation == "comments-token")
        #expect(sut.comments.count == 1)
        #expect(sut.canComment)
        #expect(sut.canLoadMoreComments == false)

        let posted = await sut.postComment(text: "  Hello there  ")
        #expect(posted)
        #expect(client.postedComments.first?.text == "Hello there")
        #expect(client.postedComments.first?.params == "create-params")
    }

    @Test("Route cancellation clears comment posting and reply busy states")
    func cancellationClearsCommentBusyStates() async {
        let client = MockYouTubeClient()
        client.watchNextData = WatchNextData(
            videoTitle: "Title",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            commentsContinuation: "comments-token"
        )
        client.commentsPage = YouTubeCommentsPage(
            comments: [],
            continuation: nil,
            createCommentParams: "create-params"
        )
        let sut = YouTubeWatchViewModel(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            client: client
        )
        await sut.load()

        let postGate = AsyncGate()
        client.beforePostCommentReturn = {
            await postGate.wait()
        }
        let postTask = Task {
            await sut.postComment(text: "Hello")
        }
        await self.waitUntil(sut.isPostingComment)

        sut.cancel()
        #expect(!sut.isPostingComment)
        await postGate.open()
        #expect(await postTask.value == false)

        client.beforePostCommentReturn = nil
        #expect(await sut.postComment(text: "Hello again"))

        let replyGate = AsyncGate()
        client.beforeCommentsReturn = { _ in
            await replyGate.wait()
        }
        let comment = YouTubeComment(
            id: "reply-parent",
            author: "@a",
            authorAvatarURL: nil,
            text: "Parent",
            publishedText: nil,
            likeCountText: nil,
            repliesContinuation: "replies-token"
        )
        let replyTask = Task {
            await sut.loadReplies(for: comment)
        }
        await self.waitUntil(sut.loadingReplies.contains(comment.id))

        sut.cancel()
        #expect(sut.loadingReplies.isEmpty)
        await replyGate.open()
        await replyTask.value

        client.beforeCommentsReturn = nil
        await sut.loadReplies(for: comment)
        #expect(sut.loadingReplies.isEmpty)
    }

    @Test("Posting without create params is rejected")
    func postWithoutParamsRejected() async {
        let client = MockYouTubeClient()
        let sut = YouTubeWatchViewModel(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            client: client
        )

        let posted = await sut.postComment(text: "Hello")

        #expect(posted == false)
        #expect(client.postedComments.isEmpty)
    }

    @Test("Comment like toggles on and off via like/unlike tokens")
    func commentLikeToggles() async {
        let client = MockYouTubeClient()
        let sut = YouTubeWatchViewModel(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            client: client
        )
        let comment = YouTubeComment(
            id: "c1",
            author: "@a",
            authorAvatarURL: nil,
            text: "Hi",
            publishedText: nil,
            likeCountText: nil,
            likeAction: "like-token",
            unlikeAction: "unlike-token"
        )

        await sut.likeComment(comment)
        #expect(sut.likedComments.contains("c1"))

        await sut.likeComment(comment)
        #expect(!sut.likedComments.contains("c1"))
        #expect(client.performedCommentActions == ["like-token", "unlike-token"])
    }

    @Test("A reply posts with the replied comment's params and shows under its thread")
    func replyPostsAndShowsUnderThread() async {
        let client = MockYouTubeClient()
        let sut = YouTubeWatchViewModel(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            client: client
        )
        let thread = Self.comment(id: "p1", text: "Parent", replyParams: "params-p1")
        let reply = Self.comment(id: "r1", text: "First reply", replyParams: "params-r1")

        let posted = await sut.postReply(
            text: "  @a Thanks  ",
            to: reply,
            inThread: thread,
            author: (name: "@me", avatarURL: nil)
        )

        #expect(posted)
        #expect(client.postedReplies.map(\.text) == ["@a Thanks"])
        #expect(client.postedReplies.map(\.params) == ["params-r1"])
        let shown = sut.postedReplies["p1"] ?? []
        #expect(shown.map(\.text) == ["@a Thanks"])
        #expect(shown.map(\.author) == ["@me"])
        #expect(shown.allSatisfy { $0.replyParams == nil })
        #expect(sut.postingReplyThreads.isEmpty)
    }

    @Test("A blank reply, or one to a comment that takes none, isn't sent")
    func replyRejectedWithoutTextOrParams() async {
        let client = MockYouTubeClient()
        let sut = YouTubeWatchViewModel(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            client: client
        )
        let open = Self.comment(id: "p1", text: "Parent", replyParams: "params-p1")
        let closed = Self.comment(id: "p2", text: "Closed", replyParams: nil)

        #expect(await sut.postReply(text: "   ", to: open, inThread: open, author: nil) == false)
        #expect(await sut.postReply(text: "Hi", to: closed, inThread: closed, author: nil) == false)
        #expect(client.postedReplies.isEmpty)
        #expect(sut.postedReplies.isEmpty)
    }

    @Test("A failed reply shows nothing and frees the thread")
    func failedReplyShowsNothing() async {
        let client = MockYouTubeClient()
        client.error = URLError(.notConnectedToInternet)
        let sut = YouTubeWatchViewModel(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            client: client
        )
        let thread = Self.comment(id: "p1", text: "Parent", replyParams: "params-p1")

        let posted = await sut.postReply(text: "Hi", to: thread, inThread: thread, author: nil)

        #expect(posted == false)
        #expect(sut.postedReplies.isEmpty)
        #expect(sut.postingReplyThreads.isEmpty)
    }

    @Test("One reply at a time per thread, and the posted one is shown as You without an account")
    func oneReplyAtATimePerThread() async {
        let client = MockYouTubeClient()
        let sut = YouTubeWatchViewModel(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            client: client
        )
        let thread = Self.comment(id: "p1", text: "Parent", replyParams: "params-p1")
        let gate = AsyncGate()
        client.beforePostReplyReturn = {
            await gate.wait()
        }

        let first = Task {
            await sut.postReply(text: "First", to: thread, inThread: thread, author: nil)
        }
        await self.waitUntil(sut.postingReplyThreads.contains("p1"))
        #expect(await sut.postReply(text: "Second", to: thread, inThread: thread, author: nil) == false)

        await gate.open()
        #expect(await first.value)
        #expect(client.postedReplies.map(\.text) == ["First"])
        #expect(sut.postedReplies["p1"]?.map(\.author) == [String(localized: "You")])
    }

    @Test("Route cancellation drops a reply still in flight")
    func cancellationDropsReplyInFlight() async {
        let client = MockYouTubeClient()
        let sut = YouTubeWatchViewModel(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            client: client
        )
        let thread = Self.comment(id: "p1", text: "Parent", replyParams: "params-p1")
        let gate = AsyncGate()
        client.beforePostReplyReturn = {
            await gate.wait()
        }

        let task = Task {
            await sut.postReply(text: "Hi", to: thread, inThread: thread, author: nil)
        }
        await self.waitUntil(sut.postingReplyThreads.contains("p1"))

        sut.cancel()
        #expect(sut.postingReplyThreads.isEmpty)
        await gate.open()
        #expect(await task.value == false)
        #expect(sut.postedReplies.isEmpty)
    }

    @Test("A posted reply that comes back, by the same author, when the thread loads is shown once")
    func postedReplyReturningInThreadShowsOnce() async {
        let client = MockYouTubeClient()
        let sut = YouTubeWatchViewModel(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            client: client
        )
        var thread = Self.comment(id: "p1", text: "Parent", replyParams: "params-p1")
        thread.repliesContinuation = "replies-token"
        let me = (name: "@me", avatarURL: URL?.none)

        for text in ["Echoed", "Thanks!", "Twice", "Twice"] {
            #expect(await sut.postReply(text: text, to: thread, inThread: thread, author: me))
        }

        client.commentsPage = YouTubeCommentsPage(
            comments: [
                // Someone else's reply with the same text isn't the posted one.
                Self.comment(id: "r1", text: "Thanks!", replyParams: "params-r1", author: "@someone"),
                Self.comment(id: "r2", text: "Echoed", replyParams: "params-r2", author: "@me"),
                // One copy back stands in for one of the two posted.
                Self.comment(id: "r3", text: "Twice", replyParams: "params-r3", author: "@me"),
            ],
            continuation: nil,
            createCommentParams: nil
        )
        await sut.loadReplies(for: thread)

        #expect(sut.repliesByComment["p1"]?.map(\.id) == ["r1", "r2", "r3"])
        #expect(sut.postedReplies["p1"]?.map(\.text) == ["Thanks!", "Twice"])
    }

    @Test("A reply posted without the account's handle isn't matched by text alone")
    func postedReplyWithoutHandleStays() async {
        let client = MockYouTubeClient()
        let sut = YouTubeWatchViewModel(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            client: client
        )
        var thread = Self.comment(id: "p1", text: "Parent", replyParams: "params-p1")
        thread.repliesContinuation = "replies-token"

        // No account loaded: shown as "You". An account without a handle: by name.
        #expect(await sut.postReply(text: "Thanks!", to: thread, inThread: thread, author: nil))
        #expect(await sut.postReply(text: "Same", to: thread, inThread: thread, author: (name: "Me", avatarURL: nil)))

        client.commentsPage = YouTubeCommentsPage(
            comments: [
                Self.comment(id: "r1", text: "Thanks!", replyParams: "params-r1", author: "@other"),
                Self.comment(id: "r2", text: "Same", replyParams: "params-r2", author: "@other"),
            ],
            continuation: nil,
            createCommentParams: nil
        )
        await sut.loadReplies(for: thread)

        #expect(sut.postedReplies["p1"]?.map(\.text) == ["Thanks!", "Same"])
    }

    @Test("A thread that loads with the reply while it posts shows it once")
    func threadLoadedWhilePostingShowsReplyOnce() async {
        let client = MockYouTubeClient()
        let sut = YouTubeWatchViewModel(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            client: client
        )
        var thread = Self.comment(id: "p1", text: "Parent", replyParams: "params-p1")
        thread.repliesContinuation = "replies-token"
        let gate = AsyncGate()
        client.beforePostReplyReturn = {
            await gate.wait()
        }

        let post = Task {
            await sut.postReply(text: "Echoed", to: thread, inThread: thread, author: (name: "@me", avatarURL: nil))
        }
        await self.waitUntil(sut.postingReplyThreads.contains("p1"))
        // YouTube has the reply before the post's response arrives.
        client.commentsPage = YouTubeCommentsPage(
            comments: [Self.comment(id: "r1", text: "Echoed", replyParams: "params-r1", author: "@me")],
            continuation: nil,
            createCommentParams: nil
        )
        await sut.loadReplies(for: thread)
        await gate.open()

        #expect(await post.value)
        #expect(sut.repliesByComment["p1"]?.map(\.id) == ["r1"])
        #expect(sut.postedReplies["p1"] == nil)
    }

    @Test("A loaded copy that stood in for an earlier posted reply doesn't hide a second one")
    func loadedCopyStandsInOnce() async {
        let client = MockYouTubeClient()
        let sut = YouTubeWatchViewModel(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            client: client
        )
        var thread = Self.comment(id: "p1", text: "Parent", replyParams: "params-p1")
        thread.repliesContinuation = "replies-token"
        let me = (name: "@me", avatarURL: URL?.none)
        #expect(await sut.postReply(text: "Thanks!", to: thread, inThread: thread, author: me))

        let gate = AsyncGate()
        client.beforePostReplyReturn = {
            await gate.wait()
        }
        let second = Task {
            await sut.postReply(text: "Thanks!", to: thread, inThread: thread, author: me)
        }
        await self.waitUntil(sut.postingReplyThreads.contains("p1"))
        // Only the first reply is on YouTube when the thread loads.
        client.commentsPage = YouTubeCommentsPage(
            comments: [Self.comment(id: "r1", text: "Thanks!", replyParams: "params-r1", author: "@me")],
            continuation: nil,
            createCommentParams: nil
        )
        await sut.loadReplies(for: thread)
        #expect(sut.postedReplies["p1"] == nil)
        await gate.open()

        #expect(await second.value)
        #expect(sut.postedReplies["p1"]?.map(\.text) == ["Thanks!"])
    }

    @Test("An earlier reply with the same text, loaded before posting, doesn't hide the new one")
    func earlierIdenticalReplyDoesNotHideNewOne() async {
        let client = MockYouTubeClient()
        let sut = YouTubeWatchViewModel(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            client: client
        )
        var thread = Self.comment(id: "p1", text: "Parent", replyParams: "params-p1")
        thread.repliesContinuation = "replies-token"
        client.commentsPage = YouTubeCommentsPage(
            comments: [Self.comment(id: "r1", text: "Thanks!", replyParams: "params-r1", author: "@me")],
            continuation: nil,
            createCommentParams: nil
        )
        await sut.loadReplies(for: thread)

        #expect(await sut.postReply(text: "Thanks!", to: thread, inThread: thread, author: (name: "@me", avatarURL: nil)))

        #expect(sut.postedReplies["p1"]?.map(\.text) == ["Thanks!"])
    }

    private static func comment(
        id: String,
        text: String,
        replyParams: String?,
        author: String = "@a"
    ) -> YouTubeComment {
        YouTubeComment(
            id: id,
            author: author,
            authorAvatarURL: nil,
            text: text,
            publishedText: nil,
            likeCountText: nil,
            replyParams: replyParams
        )
    }

    @Test("Subscribe toggle uses the watch-next channel and seeds from data")
    func subscribeToggle() async {
        let client = MockYouTubeClient()
        client.watchNextData = WatchNextData(
            videoTitle: "Title",
            viewCountText: nil,
            publishedText: nil,
            channel: YouTubeChannel(channelId: "UCxyz", name: "Channel"),
            related: [],
            isSubscribed: false
        )
        let sut = YouTubeWatchViewModel(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            client: client
        )
        await sut.load()
        #expect(sut.isSubscribed == false)

        await sut.toggleSubscribed()

        #expect(sut.isSubscribed)
        #expect(client.subscriptionChanges.first?.channelId == "UCxyz")
        #expect(client.subscriptionChanges.first?.subscribed == true)
    }

    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
        timeout: Duration = .seconds(2)
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
        #expect(condition())
    }
}

// MARK: - GuideParserTests

@Suite("GuideParser", .tags(.parser))
struct GuideParserTests {
    @Test("Extracts channel entries and skips navigation entries")
    func extractsChannels() {
        let data: [String: Any] = [
            "items": [
                [
                    "guideEntryRenderer": [
                        "formattedTitle": ["simpleText": "Home"],
                        "navigationEndpoint": ["browseEndpoint": ["browseId": "FEwhat_to_watch"]],
                    ],
                ],
                [
                    "guideSubscriptionsSectionRenderer": [
                        "items": [
                            [
                                "guideEntryRenderer": [
                                    "formattedTitle": ["simpleText": "Some Channel"],
                                    "navigationEndpoint": ["browseEndpoint": ["browseId": "UCabc"]],
                                    "thumbnail": [
                                        "thumbnails": [
                                            ["url": "https://example.com/c.jpg", "width": 88, "height": 88],
                                        ],
                                    ],
                                ],
                            ],
                            [
                                "guideEntryRenderer": [
                                    "formattedTitle": ["simpleText": "Some Channel"],
                                    "navigationEndpoint": ["browseEndpoint": ["browseId": "UCabc"]],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let channels = GuideParser.subscribedChannels(data)

        #expect(channels.count == 1)
        #expect(channels.first?.channelId == "UCabc")
        #expect(channels.first?.name == "Some Channel")
        #expect(channels.first?.thumbnailURL != nil)
    }

    @Test("Public guide fixture yields no subscribed channels")
    func publicGuideHasNoChannels() throws {
        guard let url = Bundle.module.url(forResource: "youtube_guide", withExtension: "json"),
              let data = try JSONSerialization.jsonObject(
                  with: Data(contentsOf: url)
              ) as? [String: Any]
        else {
            Issue.record("Missing youtube_guide fixture")
            return
        }

        // Captured signed out — must not mis-classify nav entries as channels.
        #expect(GuideParser.subscribedChannels(data).isEmpty)
    }
}

// MARK: - YouTubePlaylistCollectionTests

@Suite("YouTubeFeedParser playlist collection", .tags(.parser))
struct YouTubePlaylistCollectionTests {
    @Test("Collects playlist lockups from the playlists search fixture")
    func collectsPlaylists() throws {
        guard let url = Bundle.module.url(forResource: "youtube_search_playlists", withExtension: "json"),
              let data = try JSONSerialization.jsonObject(
                  with: Data(contentsOf: url)
              ) as? [String: Any]
        else {
            Issue.record("Missing youtube_search_playlists fixture")
            return
        }

        let playlists = YouTubeFeedParser.collectPlaylists(data)

        #expect(!playlists.isEmpty)
        #expect(playlists.allSatisfy { !$0.playlistId.isEmpty && !$0.title.isEmpty })
    }
}
