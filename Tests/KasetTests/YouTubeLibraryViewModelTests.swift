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
