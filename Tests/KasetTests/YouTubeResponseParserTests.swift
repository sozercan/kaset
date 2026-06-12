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
