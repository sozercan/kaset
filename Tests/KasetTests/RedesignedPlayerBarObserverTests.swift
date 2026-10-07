import JavaScriptCore
import Testing
@testable import Kaset

/// YouTube Music rolled out a redesigned player UI server-side: `ytmusic-player-bar` is
/// replaced by `ytmusic-miniplayer[slot="player-bar"]`, `ytmusic-player.playerApi` is gone
/// (`#movie_player` still exposes the player API), and the like button is now a
/// `like-button-view-model` toggle. The observer must keep reporting playback state.
@Suite(.tags(.service))
@MainActor
struct RedesignedPlayerBarObserverTests {
    /// Fake DOM for the redesigned layout. `overrides` is appended to tweak individual elements.
    private static func redesignedLayoutSetup(overrides: String = "") -> String {
        """
        var miniplayer = {};
        var trackThumbnail = {
            getAttribute: function(name) { return name === 'src' ? 'https://yt3.example.com/art=w60-h60' : null; },
            src: 'https://yt3.example.com/art=w60-h60'
        };
        var likePressed = 'false';
        var dislikePressed = 'false';
        var likeButton = { getAttribute: function(name) { return name === 'aria-pressed' ? likePressed : null; } };
        var dislikeButton = { getAttribute: function(name) { return name === 'aria-pressed' ? dislikePressed : null; } };
        var hasMiniplayer = true;
        player = {};
        moviePlayer.getVideoData = function() {
            return { video_id: currentDataVideoId, title: 'Redesigned Song', author: 'Redesigned Artist' };
        };
        document.querySelector = function(selector) {
            if (selector === 'video') return video;
            if (selector === 'ytmusic-player') return player;
            if (selector === 'ytmusic-miniplayer') return hasMiniplayer ? miniplayer : null;
            if (selector.indexOf('ytmusicTrackInfoThumbnail') >= 0) return trackThumbnail;
            if (selector === 'ytmusic-miniplayer like-button-view-model button') return likeButton;
            if (selector === 'ytmusic-miniplayer dislike-button-view-model button') return dislikeButton;
            return null;
        };
        \(overrides)
        """
    }

    private static func stateUpdates(in context: JSContext) -> [[String: Any]] {
        let json = context.evaluateScript(
            "JSON.stringify(messages.filter(function(m) { return m.type === 'STATE_UPDATE'; }))"
        )?.toString() ?? "[]"
        let data = Data(json.utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    @Test("Reports playback state when the legacy player bar element is gone")
    func reportsStateWithoutLegacyPlayerBar() throws {
        let context = try MusicPlaybackObserverTestContext.make(setup: Self.redesignedLayoutSetup())

        context.evaluateScript("fakeNow = 1000; dispatch('timeupdate');")

        let updates = Self.stateUpdates(in: context)
        let latest = try #require(updates.last)
        #expect(latest["isPlaying"] as? Bool == true)
        #expect(latest["progress"] as? Double == 179)
        #expect(latest["duration"] as? Double == 180)
        #expect(latest["videoId"] as? String == "v1")
        #expect(latest["mediaVideoId"] as? String == "v1")
        #expect(context.exception == nil)
    }

    @Test("Reports playback state even when no player bar container exists at all")
    func reportsStateWithoutAnyPlayerBarContainer() throws {
        let context = try MusicPlaybackObserverTestContext.make(
            setup: Self.redesignedLayoutSetup(overrides: "hasMiniplayer = false;")
        )

        context.evaluateScript("fakeNow = 1000; dispatch('timeupdate');")

        let latest = try #require(Self.stateUpdates(in: context).last)
        #expect(latest["progress"] as? Double == 179)
        #expect(latest["videoId"] as? String == "v1")
        #expect(context.exception == nil)
    }

    @Test("Takes title and artist from the player API when the DOM bar is gone")
    func metadataComesFromPlayerApi() throws {
        let context = try MusicPlaybackObserverTestContext.make(setup: Self.redesignedLayoutSetup())

        context.evaluateScript("fakeNow = 1000; dispatch('timeupdate');")

        let latest = try #require(Self.stateUpdates(in: context).last)
        #expect(latest["title"] as? String == "Redesigned Song")
        #expect(latest["artist"] as? String == "Redesigned Artist")
    }

    @Test("Reads the thumbnail from the redesigned miniplayer track info")
    func thumbnailComesFromMiniplayerTrackInfo() throws {
        let context = try MusicPlaybackObserverTestContext.make(setup: Self.redesignedLayoutSetup())

        context.evaluateScript("fakeNow = 1000; dispatch('timeupdate');")

        let latest = try #require(Self.stateUpdates(in: context).last)
        #expect(latest["thumbnailUrl"] as? String == "https://yt3.example.com/art=w60-h60")
    }

    @Test("Reads like and dislike state from the redesigned toggle buttons")
    func likeStatusComesFromToggleButtons() throws {
        let liked = try MusicPlaybackObserverTestContext.make(
            setup: Self.redesignedLayoutSetup(overrides: "likePressed = 'true';")
        )
        liked.evaluateScript("fakeNow = 1000; dispatch('timeupdate');")
        #expect(try #require(Self.stateUpdates(in: liked).last)["likeStatus"] as? String == "LIKE")

        let disliked = try MusicPlaybackObserverTestContext.make(
            setup: Self.redesignedLayoutSetup(overrides: "dislikePressed = 'true';")
        )
        disliked.evaluateScript("fakeNow = 1000; dispatch('timeupdate');")
        #expect(try #require(Self.stateUpdates(in: disliked).last)["likeStatus"] as? String == "DISLIKE")

        let neutral = try MusicPlaybackObserverTestContext.make(setup: Self.redesignedLayoutSetup())
        neutral.evaluateScript("fakeNow = 1000; dispatch('timeupdate');")
        #expect(try #require(Self.stateUpdates(in: neutral).last)["likeStatus"] as? String == "INDIFFERENT")
    }

    @Test("Legacy layout keeps working and still prefers the legacy player bar")
    func legacyLayoutStillReportsState() throws {
        let context = try MusicPlaybackObserverTestContext.make()

        context.evaluateScript("fakeNow = 1000; dispatch('timeupdate');")

        let latest = try #require(Self.stateUpdates(in: context).last)
        #expect(latest["progress"] as? Double == 179)
        #expect(latest["videoId"] as? String == "v1")
        #expect(latest["title"] as? String == "v1")
    }
}
