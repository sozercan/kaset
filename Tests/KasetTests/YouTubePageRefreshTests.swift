import Foundation
import Testing
@testable import Kaset

@Suite("YouTube page refresh", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct YouTubePageRefreshTests {
    @Test("Each request bumps the request ID")
    func requestBumpsID() {
        let refresh = YouTubePageRefresh()
        #expect(refresh.requestID == 0)

        refresh.request()
        refresh.request()

        #expect(refresh.requestID == 2)
    }

    @Test("The page on top is the root while nothing is pushed, then the last one pushed")
    func pageOnTopFollowsPath() {
        let refresh = YouTubePageRefresh()
        let store = YouTubeViewModelStore(client: MockYouTubeClient())
        refresh.store = store
        let channel = YouTubeRoute.channel(channelId: "UCchannel")
        let playlist = YouTubeRoute.playlist(playlistId: "PLlist")
        #expect(refresh.isOnTop(route: nil, position: nil))

        store.navigationPath = [channel]
        let channelPosition = refresh.position(of: channel)
        store.navigationPath.append(playlist)
        let playlistPosition = refresh.position(of: playlist)
        #expect(channelPosition == 0)
        #expect(playlistPosition == 1)
        #expect(!refresh.isOnTop(route: nil, position: nil))
        #expect(!refresh.isOnTop(route: channel, position: channelPosition))
        #expect(refresh.isOnTop(route: playlist, position: playlistPosition))

        store.navigationPath.removeLast()
        #expect(refresh.isOnTop(route: channel, position: channelPosition))
    }

    @Test("A page pushed again for the same route is the only one on top")
    func repeatedRouteOnlyTopRefreshes() {
        let refresh = YouTubePageRefresh()
        let store = YouTubeViewModelStore(client: MockYouTubeClient())
        refresh.store = store
        let channel = YouTubeRoute.channel(channelId: "UCchannel")
        let video = YouTubeRoute.watch(MockYouTubeClient.makeVideo(videoId: "v1"))

        store.navigationPath = [channel]
        let firstPosition = refresh.position(of: channel)
        store.navigationPath += [video, channel]
        let secondPosition = refresh.position(of: channel)

        #expect(!refresh.isOnTop(route: channel, position: firstPosition))
        #expect(refresh.isOnTop(route: channel, position: secondPosition))
    }

    @Test("A page with a position past the end is on top once its route is last again")
    func stalePositionAfterRebuild() {
        let refresh = YouTubePageRefresh()
        let store = YouTubeViewModelStore(client: MockYouTubeClient())
        refresh.store = store
        let channel = YouTubeRoute.channel(channelId: "UCchannel")
        let video = YouTubeRoute.watch(MockYouTubeClient.makeVideo(videoId: "v1"))
        // Rebuilt with [channel, video, channel] pushed: both channel pages
        // note the last index.
        store.navigationPath = [channel, video, channel]
        let rebuiltPosition = refresh.position(of: channel)
        #expect(rebuiltPosition == 2)

        store.navigationPath = [channel]
        #expect(refresh.isOnTop(route: channel, position: rebuiltPosition))
        #expect(!refresh.isOnTop(route: video, position: 1))
    }

    @Test("Refreshing the watch page reloads its data and comments")
    func watchPageRefreshReloads() async {
        let client = MockYouTubeClient()
        client.watchNextData = Self.watchNext(title: "Before", related: "r1")
        client.commentsPage = Self.comments(id: "c1")
        let sut = YouTubeWatchViewModel(
            video: MockYouTubeClient.makeVideo(videoId: "abc"),
            client: client
        )
        await sut.load()
        #expect(sut.data.videoTitle == "Before")
        #expect(sut.comments.map(\.id) == ["c1"])

        // A second load of an already loaded page does nothing; refresh does.
        client.watchNextData = Self.watchNext(title: "After", related: "r2")
        client.commentsPage = Self.comments(id: "c2")
        await sut.load()
        #expect(sut.data.videoTitle == "Before")

        await sut.refresh()

        #expect(sut.data.videoTitle == "After")
        #expect(sut.data.related.map(\.videoId) == ["r2"])
        #expect(sut.comments.map(\.id) == ["c2"])
    }

    @Test("Channel and playlist pages refresh with load(), which fetches again when loaded")
    func channelAndPlaylistLoadFetchesAgain() async {
        let client = MockYouTubeClient()
        let channel = YouTubeChannelViewModel(channelId: "UCchannel", client: client)
        let playlist = YouTubePlaylistViewModel(playlistId: "PLlist", client: client)
        await channel.load()
        await playlist.load()
        #expect(channel.detail?.channel.name == "Mock Channel")
        #expect(playlist.detail?.playlist.title == "Mock Playlist")

        client.channelDetail = YouTubeChannelDetail(
            channel: YouTubeChannel(channelId: "UCchannel", name: "Renamed Channel"),
            videos: []
        )
        client.playlistDetail = YouTubePlaylistDetail(
            playlist: YouTubePlaylist(playlistId: "PLlist", title: "Renamed Playlist"),
            videos: []
        )
        await channel.load()
        await playlist.load()

        #expect(channel.detail?.channel.name == "Renamed Channel")
        #expect(playlist.detail?.playlist.title == "Renamed Playlist")
    }

    private static func watchNext(title: String, related videoId: String) -> WatchNextData {
        WatchNextData(
            videoTitle: title,
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [MockYouTubeClient.makeVideo(videoId: videoId)],
            commentsContinuation: "comments-token"
        )
    }

    private static func comments(id: String) -> YouTubeCommentsPage {
        YouTubeCommentsPage(
            comments: [
                YouTubeComment(
                    id: id,
                    author: "@a",
                    authorAvatarURL: nil,
                    text: "Hi",
                    publishedText: nil,
                    likeCountText: nil
                ),
            ],
            continuation: nil,
            createCommentParams: nil
        )
    }
}
