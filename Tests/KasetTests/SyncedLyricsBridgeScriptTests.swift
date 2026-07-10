import JavaScriptCore
import Testing
@testable import Kaset

// MARK: - SyncedLyricsBridgeScriptTests

@Suite(.serialized, .tags(.service))
struct SyncedLyricsBridgeScriptTests {
    @Test("Synced lyrics display bucket follows current line")
    func displayBucketFollowsCurrentLine() {
        let lyrics = SyncedLyrics(lines: [
            SyncedLyricLine(timeInMs: 0, duration: 1000, text: "A", words: nil),
            SyncedLyricLine(timeInMs: 1000, duration: 1000, text: "B", words: nil),
            SyncedLyricLine(timeInMs: 2000, duration: 1000, text: "C", words: nil),
        ], source: "Test")

        #expect(lyrics.displayBucket(at: -1) == -1)
        #expect(lyrics.displayBucket(at: 0) == 0)
        #expect(lyrics.displayBucket(at: 999) == 0)
        #expect(lyrics.displayBucket(at: 1000) == 1)
        #expect(lyrics.displayBucket(at: 2500) == 2)
        #expect(lyrics.displayBucket(at: 3000) == -4)
        #expect(lyrics.bridgeLineRanges[0] == ["startMs": 0, "endMs": 1000])

        let zeroDuration = SyncedLyrics(lines: [
            SyncedLyricLine(timeInMs: 0, duration: 0, text: "A", words: nil),
            SyncedLyricLine(timeInMs: 1000, duration: 0, text: "B", words: nil),
        ], source: "Test")
        #expect(zeroDuration.bridgeLineRanges[0] == ["startMs": 0, "endMs": 1000])
        #expect(zeroDuration.displayBucket(at: 500) == 0)
        #expect(zeroDuration.displayBucket(at: 1000) == 1)

        let gapped = SyncedLyrics(lines: [
            SyncedLyricLine(timeInMs: 0, duration: 500, text: "A", words: nil),
            SyncedLyricLine(timeInMs: 1000, duration: 500, text: "B", words: nil),
        ], source: "Test")
        #expect(gapped.displayBucket(at: 750) == -2)
        #expect(gapped.displayBucket(at: 1750) == -3)

        let overlapping = SyncedLyrics(lines: [
            SyncedLyricLine(timeInMs: 0, duration: 3000, text: "A", words: nil),
            SyncedLyricLine(timeInMs: 2000, duration: 1000, text: "B", words: nil),
        ], source: "Test")
        #expect(overlapping.bridgeLineRanges[0] == ["startMs": 0, "endMs": 2000])
        #expect(overlapping.displayBucket(at: 2500) == 1)
    }

    @Test("Lyrics bridge posts only when the current line changes")
    func bridgePostsOnlyLineChanges() throws {
        let context = try #require(JSContext())
        try self.evaluate(Self.fixtureScript, in: context)
        try self.evaluate(SingletonPlayerWebView.observerScript, in: context)

        try self.evaluate(
            """
            window.startLyricsPoll([
                { startMs: 0, endMs: 500 },
                { startMs: 1000, endMs: 1500 },
                { startMs: 2000, endMs: 2500 }
            ]);
            video.currentTime = 0.5;
            timeoutCalls[timeoutCalls.length - 1].callback();
            video.currentTime = 1.0;
            timeoutCalls[timeoutCalls.length - 1].callback();
            video.currentTime = 1.5;
            timeoutCalls[timeoutCalls.length - 1].callback();
            video.currentTime = 2.0;
            timeoutCalls[timeoutCalls.length - 1].callback();
            video.currentTime = 2.5;
            timeoutCalls[timeoutCalls.length - 1].callback();
            video.currentTime = 3.0;
            timeoutCalls[timeoutCalls.length - 1].callback();
            """,
            in: context
        )

        let messageCount = context.evaluateScript("postedMessages.filter(function(m) { return m.type === 'LYRICS_LINE'; }).length")?.toInt32() ?? -1
        let lineIndexes = context.evaluateScript("postedMessages.filter(function(m) { return m.type === 'LYRICS_LINE'; }).map(function(m) { return String(m.lineIndex); }).join(',')")?.toString()
        let timeValues = context.evaluateScript("postedMessages.filter(function(m) { return m.type === 'LYRICS_LINE'; }).map(function(m) { return String(m.timeMs); }).join(',')")?.toString()
        let lyricsIntervalCount = context.evaluateScript("intervalCalls.filter(function(call) { return call.milliseconds === 250; }).length")?.toInt32() ?? -1

        #expect(messageCount == 6)
        #expect(lineIndexes == "0,-1,1,-1,2,-1")
        #expect(timeValues == "0,500,1000,1500,2000,2500")
        #expect(lyricsIntervalCount == 0)
    }

    @Test("Lyrics bridge schedules short ranges at their next boundary")
    func bridgeSchedulesShortRangesAtBoundary() throws {
        let context = try #require(JSContext())
        try self.evaluate(Self.fixtureScript, in: context)
        try self.evaluate(SingletonPlayerWebView.observerScript, in: context)

        try self.evaluate(
            """
            video.currentTime = 1.0;
            window.startLyricsPoll([
                { startMs: 1100, endMs: 1200 }
            ]);
            """,
            in: context
        )

        let lyricsDelay = context.evaluateScript("timeoutCalls[timeoutCalls.length - 1].milliseconds")?.toInt32() ?? -1
        #expect(lyricsDelay == 101)
    }

    @Test("Lyrics bridge allows sub-50ms boundary scheduling while playing")
    func bridgeAllowsSub50msBoundarySchedulingWhilePlaying() throws {
        let context = try #require(JSContext())
        try self.evaluate(Self.fixtureScript, in: context)
        try self.evaluate(SingletonPlayerWebView.observerScript, in: context)

        try self.evaluate(
            """
            video.paused = false;
            video.currentTime = 1.09;
            window.startLyricsPoll([
                { startMs: 1100, endMs: 1120 }
            ]);
            """,
            in: context
        )

        let lyricsDelay = context.evaluateScript("timeoutCalls[timeoutCalls.length - 1].milliseconds")?.toInt32() ?? -1
        #expect(lyricsDelay == 11)
    }

    @Test("Lyrics bridge clamps paused near-boundary scheduling to the minimum interval")
    func bridgeClampsPausedNearBoundarySchedulingToMinimumInterval() throws {
        let context = try #require(JSContext())
        try self.evaluate(Self.fixtureScript, in: context)
        try self.evaluate(SingletonPlayerWebView.observerScript, in: context)

        try self.evaluate(
            """
            video.paused = true;
            video.currentTime = 1.09;
            window.startLyricsPoll([
                { startMs: 1100, endMs: 1120 }
            ]);
            """,
            in: context
        )

        let lyricsDelay = context.evaluateScript("timeoutCalls[timeoutCalls.length - 1].milliseconds")?.toInt32() ?? -1
        #expect(lyricsDelay == 50)
    }

    @Test("Lyrics bridge reschedules when line ranges are replaced")
    func bridgeReschedulesWhenRangesAreReplaced() throws {
        let context = try #require(JSContext())
        try self.evaluate(Self.fixtureScript, in: context)
        try self.evaluate(SingletonPlayerWebView.observerScript, in: context)

        try self.evaluate(
            """
            video.currentTime = 0;
            window.startLyricsPoll([
                { startMs: 0, endMs: 10000 }
            ]);
            const firstTimeoutId = timeoutCalls.length;
            video.currentTime = 1.0;
            window.startLyricsPoll([
                { startMs: 1100, endMs: 1200 }
            ]);
            """,
            in: context
        )

        let clearedTimeout = context.evaluateScript("clearedTimeoutIds.indexOf(1) !== -1")?.toBool() ?? false
        let latestDelay = context.evaluateScript("timeoutCalls[timeoutCalls.length - 1].milliseconds")?.toInt32() ?? -1

        #expect(clearedTimeout)
        #expect(latestDelay == 101)
    }

    @Test("Lyrics bridge emits sought short line immediately")
    func bridgeEmitsSoughtShortLineImmediately() throws {
        let context = try #require(JSContext())
        try self.evaluate(Self.fixtureScript, in: context)
        try self.evaluate(SingletonPlayerWebView.observerScript, in: context)

        try self.evaluate(
            """
            window.startLyricsPoll([
                { startMs: 1100, endMs: 1200 }
            ]);
            postedMessages = [];
            video.currentTime = 1.1;
            videoListeners.seeked();
            """,
            in: context
        )

        let lineMessages = context.evaluateScript("postedMessages.filter(function(m) { return m.type === 'LYRICS_LINE'; })")
        let count = lineMessages?.forProperty("length")?.toInt32() ?? -1
        let lineIndex = context.evaluateScript("postedMessages.filter(function(m) { return m.type === 'LYRICS_LINE'; })[0].lineIndex")?.toInt32() ?? -1
        let timeMs = context.evaluateScript("postedMessages.filter(function(m) { return m.type === 'LYRICS_LINE'; })[0].timeMs")?.toInt32() ?? -1

        #expect(count == 1)
        #expect(lineIndex == 0)
        #expect(timeMs == 1100)
    }

    @Test("Lyrics bridge does not restart after stop or before start")
    func bridgeDoesNotRestartWhenInactive() throws {
        let context = try #require(JSContext())
        try self.evaluate(Self.fixtureScript, in: context)
        try self.evaluate(SingletonPlayerWebView.observerScript, in: context)

        try self.evaluate(
            """
            video.currentTime = 1.1;
            videoListeners.seeked();
            const timeoutCountBeforeStart = timeoutCalls.length;
            window.startLyricsPoll([
                { startMs: 1000, endMs: 2000 }
            ]);
            window.stopLyricsPoll();
            video.currentTime = 1.2;
            videoListeners.seeked();
            """,
            in: context
        )

        let timeoutCountBeforeStart = context.evaluateScript("timeoutCountBeforeStart")?.toInt32() ?? -1
        let finalTimeoutCount = context.evaluateScript("timeoutCalls.length")?.toInt32() ?? -1
        let lineMessageCount = context.evaluateScript("postedMessages.filter(function(m) { return m.type === 'LYRICS_LINE'; }).length")?.toInt32() ?? -1

        #expect(timeoutCountBeforeStart == 0)
        #expect(finalTimeoutCount == 1) // explicit start only; seek after stop adds none
        #expect(lineMessageCount == 1)
    }

    private static var fixtureScript: String {
        """
        var postedMessages = [];
        var intervalCalls = [];
        var timeoutCalls = [];
        var clearedTimeoutIds = [];
        function setInterval(callback, milliseconds) {
            intervalCalls.push({ callback: callback, milliseconds: milliseconds });
            return intervalCalls.length;
        }
        function clearInterval(id) {}
        function setTimeout(callback, milliseconds) {
            timeoutCalls.push({ callback: callback, milliseconds: milliseconds });
            return timeoutCalls.length;
        }
        function clearTimeout(id) { clearedTimeoutIds.push(id); }
        var bridge = {
            postMessage: function(message) { postedMessages.push(message); }
        };
        var window = {
            location: { href: 'https://music.youtube.com/watch?v=abc' },
            webkit: { messageHandlers: { singletonPlayer: bridge } },
            __kasetTargetVolume: 1.0,
            __kasetAutoplayPending: false,
            addEventListener: function() {}
        };
        var localStorage = { getItem: function() { return null; }, setItem: function() {} };
        var videoListeners = {};
        var video = {
            currentTime: 0,
            paused: true,
            ended: false,
            volume: 1.0,
            readyState: 4,
            addEventListener: function(name, handler) { videoListeners[name] = handler; }
        };
        var playerBar = { attributes: {}, childNodes: [] };
        var playerApi = {
            getVideoData: function() { return { video_id: 'abc', title: 'Title', author: 'Artist' }; }
        };
        var ytmusicPlayer = { playerApi: playerApi };
        var moviePlayer = { getVideoData: playerApi.getVideoData };
        var document = {
            readyState: 'complete',
            body: {},
            querySelector: function(selector) {
                if (selector === 'ytmusic-player-bar') return playerBar;
                if (selector === 'video') return video;
                if (selector === 'ytmusic-player') return ytmusicPlayer;
                if (selector === '#progress-bar') return null;
                return null;
            },
            getElementById: function(id) {
                if (id === 'movie_player') return moviePlayer;
                return null;
            },
            querySelectorAll: function() { return []; },
            addEventListener: function(_, handler) { handler(); }
        };
        function MutationObserver(callback) { this.callback = callback; }
        MutationObserver.prototype.observe = function() {};
        MutationObserver.prototype.disconnect = function() {};
        """
    }

    private func evaluate(_ script: String, in context: JSContext) throws {
        context.exception = nil
        _ = context.evaluateScript(script)
        if let exception = context.exception?.toString() {
            Issue.record("JavaScript exception: \(exception)")
            throw TestScriptError.javaScriptException(exception)
        }
    }
}

// MARK: - TestScriptError

private enum TestScriptError: Error {
    case javaScriptException(String)
}
