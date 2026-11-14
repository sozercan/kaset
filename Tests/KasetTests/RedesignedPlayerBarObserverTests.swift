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
    /// It also mounts the player page's unslotted top miniplayer and a like renderer outside
    /// the player bar, neither of which the observer may read.
    private static func redesignedLayoutSetup(overrides: String = "") -> String {
        """
        var barTitle = { textContent: 'Redesigned Song' };
        var barByline = { textContent: 'Redesigned Artist • 1M views' };
        var trackThumbnail = {
            getAttribute: function(name) { return name === 'src' ? 'https://yt3.example.com/art=w60-h60' : null; },
            src: 'https://yt3.example.com/art=w60-h60'
        };
        var likePressed = 'false';
        var dislikePressed = 'false';
        var likeButton = { getAttribute: function(name) { return name === 'aria-pressed' ? likePressed : null; } };
        var dislikeButton = { getAttribute: function(name) { return name === 'aria-pressed' ? dislikePressed : null; } };
        var miniplayer = {
            querySelector: function(selector) {
                if (selector.indexOf('.ytmusicTrackInfoTitle') >= 0) return barTitle;
                if (selector.indexOf('.ytmusicTrackInfoByline') >= 0) return barByline;
                if (selector.indexOf('ytmusicTrackInfoThumbnail') >= 0) return trackThumbnail;
                if (selector === 'like-button-view-model button') return likeButton;
                if (selector === 'dislike-button-view-model button') return dislikeButton;
                return null;
            }
        };
        var staleElement = {
            textContent: 'Stale Song',
            getAttribute: function(name) { return name === 'like-status' ? 'LIKE' : 'true'; }
        };
        var topMiniplayer = { querySelector: function() { return staleElement; } };
        var hasMiniplayer = true;
        var apiTitle = 'Redesigned Song';
        var apiAuthor = 'Redesigned Artist';
        player = {};
        moviePlayer.getVideoData = function() {
            return { video_id: currentDataVideoId, title: apiTitle, author: apiAuthor };
        };
        var observedTargets = [];
        MutationObserver = function() {
            this.observe = function(target) { observedTargets.push(target); };
            this.disconnect = function() {};
        };
        document.querySelector = function(selector) {
            if (selector === 'video') return video;
            if (selector === 'ytmusic-player') return player;
            if (selector === '[slot="player-bar"]') return hasMiniplayer ? miniplayer : null;
            if (selector === 'ytmusic-miniplayer') return topMiniplayer;
            if (selector === 'ytmusic-like-button-renderer') return staleElement;
            return null;
        };
        \(overrides)
        """
    }

    private static func latestStateUpdate(
        setup: String = Self.redesignedLayoutSetup(),
        after script: String = "fakeNow = 1000; dispatch('timeupdate');"
    ) throws -> (JSContext, [String: Any]) {
        let context = try MusicPlaybackObserverTestContext.make(setup: setup)
        context.evaluateScript(script)
        let json = context.evaluateScript(
            "JSON.stringify(messages.filter(function(m) { return m.type === 'STATE_UPDATE'; }))"
        )?.toString() ?? "[]"
        let updates = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
        return try (context, #require(updates.last))
    }

    @Test("Reports playback state when the legacy player bar element is gone")
    func reportsStateWithoutLegacyPlayerBar() throws {
        let (context, latest) = try Self.latestStateUpdate()

        #expect(latest["isPlaying"] as? Bool == true)
        #expect(latest["progress"] as? Double == 179)
        #expect(latest["duration"] as? Double == 180)
        #expect(latest["videoId"] as? String == "v1")
        #expect(latest["mediaVideoId"] as? String == "v1")
        #expect(context.exception == nil)
    }

    @Test("Reports playback state before any player bar exists, then observes the bar once it mounts")
    func reportsStateBeforePlayerBarMounts() throws {
        let (context, latest) = try Self.latestStateUpdate(
            setup: Self.redesignedLayoutSetup(overrides: "hasMiniplayer = false;")
        )

        #expect(latest["progress"] as? Double == 179)
        #expect(latest["videoId"] as? String == "v1")
        #expect(context.evaluateScript("observedTargets.indexOf(miniplayer)")?.toInt32() == -1)

        context.evaluateScript("hasMiniplayer = true; for (var i = 0; i < 5 && runTimeout(500); i += 1) {}")

        #expect(context.evaluateScript("observedTargets.indexOf(miniplayer) >= 0")?.toBool() == true)
        #expect(context.exception == nil)
    }

    @Test("Observes the slotted player bar, not the player page's top miniplayer")
    func observesSlottedPlayerBar() throws {
        let (context, latest) = try Self.latestStateUpdate()

        #expect(context.evaluateScript("observedTargets.indexOf(miniplayer) >= 0")?.toBool() == true)
        #expect(context.evaluateScript("observedTargets.indexOf(topMiniplayer)")?.toInt32() == -1)
        #expect(latest["title"] as? String == "Redesigned Song")
    }

    @Test("Takes title and artist from the player API when it has them")
    func metadataComesFromPlayerApi() throws {
        let (_, latest) = try Self.latestStateUpdate()

        #expect(latest["title"] as? String == "Redesigned Song")
        #expect(latest["artist"] as? String == "Redesigned Artist")
    }

    @Test("Falls back to the redesigned bar's title and byline when the player API has none")
    func metadataFallsBackToRedesignedBar() throws {
        let (_, latest) = try Self.latestStateUpdate(
            setup: Self.redesignedLayoutSetup(overrides: "apiTitle = ''; apiAuthor = '';")
        )

        #expect(latest["title"] as? String == "Redesigned Song")
        #expect(latest["artist"] as? String == "Redesigned Artist • 1M views")
    }

    @Test("Reads the thumbnail from the redesigned miniplayer track info")
    func thumbnailComesFromMiniplayerTrackInfo() throws {
        let (_, latest) = try Self.latestStateUpdate()

        #expect(latest["thumbnailUrl"] as? String == "https://yt3.example.com/art=w60-h60")
    }

    @Test(
        "Reads like and dislike state from the redesigned bar's toggle buttons",
        arguments: [
            ("likePressed = 'true';", "LIKE"),
            ("dislikePressed = 'true';", "DISLIKE"),
            ("", "INDIFFERENT"),
        ]
    )
    func likeStatusComesFromToggleButtons(overrides: String, expected: String) throws {
        let (_, latest) = try Self.latestStateUpdate(
            setup: Self.redesignedLayoutSetup(overrides: overrides)
        )

        #expect(latest["likeStatus"] as? String == expected)
    }

    @Test("Reports an unknown like state while the bar still shows the previous track")
    func likeStatusIsUnknownWhileBarLags() throws {
        let (_, latest) = try Self.latestStateUpdate(
            setup: Self.redesignedLayoutSetup(overrides: "barTitle.textContent = 'Previous Song'; likePressed = 'true';")
        )

        #expect(latest["title"] as? String == "Redesigned Song")
        #expect((latest["likeStatus"] as? String)?.isEmpty == true)
    }

    @Test(
        "Legacy layout reads like state from its player bar",
        arguments: [
            ("likeRenderer = { getAttribute: function() { return 'LIKE'; } };", "LIKE"),
            ("likeRenderer = { getAttribute: function() { return null; } };", "INDIFFERENT"),
            ("", ""),
        ]
    )
    func legacyLayoutReportsState(setup: String, expectedLikeStatus: String) throws {
        let (context, latest) = try Self.latestStateUpdate(setup: setup)

        #expect(latest["progress"] as? Double == 179)
        #expect(latest["videoId"] as? String == "v1")
        #expect(latest["title"] as? String == "v1")
        #expect(latest["likeStatus"] as? String == expectedLikeStatus)
        #expect(context.exception == nil)
    }
}
