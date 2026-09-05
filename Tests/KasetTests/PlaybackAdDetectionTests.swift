import JavaScriptCore
import Testing
@testable import Kaset

@Suite("Playback ad detection", .tags(.service))
@MainActor
struct PlaybackAdDetectionTests {
    @Test("Both players identify interrupting ads", arguments: [false, true])
    func interruptingAds(isMusic: Bool) throws {
        let context = try self.makeContext(isMusic: isMusic)
        try self.evaluate("moviePlayer.classes['ad-interrupting'] = true;", in: context)

        try self.installObserver(isMusic: isMusic, in: context)

        #expect(context.evaluateScript("lastState().isAd").toBool())
    }

    @Test("Both players identify ad media without a CSS marker", arguments: [false, true])
    func presentingAdPlayer(isMusic: Bool) throws {
        let context = try self.makeContext(isMusic: isMusic)
        try self.evaluate(
            isMusic ? "musicApi.presentingType = 2;" : "moviePlayer.presentingType = 2;",
            in: context
        )

        try self.installObserver(isMusic: isMusic, in: context)

        #expect(context.evaluateScript("lastState().isAd").toBool())
    }

    @Test("Both players request server-stitched ad state", arguments: [false, true])
    func serverStitchedAdState(isMusic: Bool) throws {
        let context = try self.makeContext(isMusic: isMusic)
        try self.evaluate(
            """
            \(isMusic ? "musicApi" : "moviePlayer").getPresentingPlayerType = function(includeStitchedAds) {
                return includeStitchedAds === true ? 2 : 1;
            };
            """,
            in: context
        )

        try self.installObserver(isMusic: isMusic, in: context)

        #expect(context.evaluateScript("lastState().isAd").toBool())
    }

    @Test("Ordinary and remote playback do not become ads", arguments: [false, true])
    func contentIsNotAnAd(isMusic: Bool) throws {
        for presentingType in ["1", "3", "undefined", "null", "'2'"] {
            let context = try self.makeContext(isMusic: isMusic)
            try self.evaluate(
                "moviePlayer.presentingType = \(presentingType); musicApi.presentingType = \(presentingType);",
                in: context
            )

            try self.installObserver(isMusic: isMusic, in: context)

            #expect(!context.evaluateScript("lastState().isAd").toBool())
        }
    }

    @Test("A failing player API preserves CSS ad detection", arguments: [false, true])
    func failingAPIKeepsDOMFallback(isMusic: Bool) throws {
        let context = try self.makeContext(isMusic: isMusic)
        try self.evaluate(
            """
            moviePlayer.getPresentingPlayerType = function() { throw new Error('not ready'); };
            musicApi.getPresentingPlayerType = moviePlayer.getPresentingPlayerType;
            moviePlayer.classes['ad-showing'] = true;
            """,
            in: context
        )

        try self.installObserver(isMusic: isMusic, in: context)

        #expect(context.evaluateScript("lastState().isAd").toBool())
    }

    @Test("A failed API probe does not interrupt state updates", arguments: [false, true])
    func failedAPIProbe(isMusic: Bool) throws {
        let context = try self.makeContext(isMusic: isMusic)
        try self.evaluate(
            """
            moviePlayer.getPresentingPlayerType = function() { throw new Error('not ready'); };
            musicApi.presentingType = 2;
            """,
            in: context
        )

        try self.installObserver(isMusic: isMusic, in: context)

        #expect(context.evaluateScript("lastState().isAd").toBool() == isMusic)
        #expect(context.evaluateScript("lastState().progress").toDouble() == 12)
    }

    @Test("Paused players report ad class changes without media events", arguments: [false, true])
    func pausedAdTransitions(isMusic: Bool) throws {
        let context = try self.makeContext(isMusic: isMusic)
        try self.installObserver(isMusic: isMusic, in: context)
        try self.evaluate(
            """
            postedMessages = [];
            moviePlayer.classes['ad-showing'] = true;
            notifyClassChange(moviePlayer);
            """,
            in: context
        )
        #expect(context.evaluateScript("stateCount()").toInt32() == 1)
        #expect(context.evaluateScript("lastState().isAd").toBool())

        try self.evaluate(
            """
            notifyClassChange(moviePlayer);
            delete moviePlayer.classes['ad-showing'];
            notifyClassChange(moviePlayer);
            """,
            in: context
        )
        #expect(context.evaluateScript("stateCount()").toInt32() == 2)
        #expect(!context.evaluateScript("lastState().isAd").toBool())
    }

    @Test("Ad player events report transitions while paused", arguments: [false, true], ["onAdStart", "onAdStateChange"])
    func playerAdEvents(isMusic: Bool, event: String) throws {
        let context = try self.makeContext(isMusic: isMusic)
        try self.installObserver(isMusic: isMusic, in: context)
        try self.evaluate(
            """
            postedMessages = [];
            var activeApi = \(isMusic ? "musicApi" : "moviePlayer");
            activeApi.presentingType = 2;
            activeApi.fire('\(event)');
            """,
            in: context
        )
        #expect(context.evaluateScript("stateCount()").toInt32() == 1)
        #expect(context.evaluateScript("lastState().isAd").toBool())

        try self.evaluate("activeApi.presentingType = 1; activeApi.fire('onAdEnd');", in: context)
        #expect(context.evaluateScript("stateCount()").toInt32() == 2)
        #expect(!context.evaluateScript("lastState().isAd").toBool())
    }

    @Test("Player replacement reconnects ad observation without stale listeners", arguments: [false, true])
    func replacementPlayer(isMusic: Bool) throws {
        let context = try self.makeContext(isMusic: isMusic)
        let playerAPI = isMusic ? "musicPlayer.playerApi" : "moviePlayer"
        try self.installObserver(isMusic: isMusic, in: context)
        try self.evaluate(
            """
            var oldPlayer = \(playerAPI);
            var replacementPlayer = makePlayer();
            \(playerAPI) = replacementPlayer;
            replacementPlayer.presentingType = 2;
            notifyChildrenChanged();
            timers.splice(0).forEach(function(callback) { callback(); });
            notifyChildrenChanged();
            timers.splice(0).forEach(function(callback) { callback(); });
            """,
            in: context
        )
        #expect(context.evaluateScript("lastState().isAd").toBool())
        #expect(context.evaluateScript("replacementPlayer.listeners.onAdStart.length").toInt32() == 1)

        try self.evaluate("postedMessages = []; oldPlayer.fire('onAdStart');", in: context)
        #expect(context.evaluateScript("stateCount()").toInt32() == 0)
        try self.evaluate("replacementPlayer.presentingType = 1; replacementPlayer.fire('onAdEnd');", in: context)
        #expect(context.evaluateScript("stateCount()").toInt32() == 1)
        #expect(!context.evaluateScript("lastState().isAd").toBool())

        // Class observation must still follow the current movie-player element.
        try self.evaluate(
            "postedMessages = []; moviePlayer.classes['ad-showing'] = true; notifyClassChange(moviePlayer);",
            in: context
        )
        #expect(context.evaluateScript("stateCount()").toInt32() == 1)
        #expect(context.evaluateScript("lastState().isAd").toBool())
    }

    @Test("Ad listeners wait for the player API on an existing element", arguments: [false, true])
    func latePlayerAPI(isMusic: Bool) throws {
        let context = try self.makeContext(isMusic: isMusic)
        try self.evaluate(
            """
            var playerAddEventListener = moviePlayer.addEventListener;
            var presentingPlayerType = moviePlayer.getPresentingPlayerType;
            delete moviePlayer.getPresentingPlayerType;
            moviePlayer.addEventListener = function() {};
            """,
            in: context
        )
        try self.installObserver(isMusic: isMusic, in: context)
        try self.evaluate(
            """
            moviePlayer.getPresentingPlayerType = presentingPlayerType;
            moviePlayer.addEventListener = playerAddEventListener;
            notifyChildrenChanged();
            timers.splice(0).forEach(function(callback) { callback(); });
            postedMessages = [];
            moviePlayer.presentingType = 2;
            moviePlayer.fire('onAdStart');
            """,
            in: context
        )

        #expect(context.evaluateScript("stateCount()").toInt32() == 1)
        #expect(context.evaluateScript("lastState().isAd").toBool())
    }

    @Test("Ad-end events clear ads first observed through media updates", arguments: [false, true])
    func adEndAfterMediaSample(isMusic: Bool) throws {
        let context = try self.makeContext(isMusic: isMusic)
        try self.installObserver(isMusic: isMusic, in: context)
        try self.evaluate(
            """
            var activeApi = \(isMusic ? "musicApi" : "moviePlayer");
            activeApi.presentingType = 2;
            fireVideoEvent('waiting');
            """,
            in: context
        )
        #expect(context.evaluateScript("lastState().isAd").toBool())

        try self.evaluate(
            """
            postedMessages = [];
            activeApi.presentingType = 1;
            activeApi.fire('onAdEnd');
            """,
            in: context
        )
        #expect(context.evaluateScript("stateCount()").toInt32() == 1)
        #expect(!context.evaluateScript("lastState().isAd").toBool())
    }

    @Test("Ended events retain ad classification", arguments: [false, true], [false, true])
    func adEndsAreNotContentEnds(isMusic: Bool, signalClearsFirst: Bool) throws {
        let context = try self.makeContext(isMusic: isMusic)
        try self.evaluate(
            "currentData = { video_id: 'creative', title: 'Advertisement' }; moviePlayer.presentingType = 2; musicApi.presentingType = 2;",
            in: context
        )
        try self.installObserver(isMusic: isMusic, in: context)
        if signalClearsFirst {
            try self.evaluate("moviePlayer.presentingType = 1; musicApi.presentingType = 1;", in: context)
        }
        try self.evaluate("postedMessages = []; video.ended = true; fireVideoEvent('ended');", in: context)

        #expect(context.evaluateScript(
            "postedMessages.filter(function(message) { return message.type === '\(isMusic ? "TRACK_ENDED" : "VIDEO_ENDED")'; })[0].isAd"
        ).toBool())
    }

    @Test("Music ad metadata does not consume the first content update")
    func musicMetadataWaitsForContent() throws {
        let context = try self.makeContext(isMusic: true)
        try self.evaluate("moviePlayer.classes['ad-showing'] = true;", in: context)
        try self.installObserver(isMusic: true, in: context)
        #expect(!context.evaluateScript("lastState().trackChanged").toBool())

        try self.evaluate(
            """
            delete moviePlayer.classes['ad-showing'];
            fireVideoEvent('waiting');
            """,
            in: context
        )
        #expect(!context.evaluateScript("lastState().isAd").toBool())
        #expect(context.evaluateScript("lastState().trackChanged").toBool())
    }

    @Test("Music ad creatives do not create content metadata transitions")
    func musicAdCreativeMetadata() throws {
        let context = try self.makeContext(isMusic: true)
        try self.installObserver(isMusic: true, in: context)
        try self.evaluate(
            """
            var contentData = currentData;
            currentData = { video_id: 'creative', title: 'Advertisement', author: 'Advertiser' };
            moviePlayer.classes['ad-showing'] = true;
            fireVideoEvent('waiting');
            """,
            in: context
        )
        #expect(context.evaluateScript("lastState().isAd").toBool())
        #expect(!context.evaluateScript("lastState().trackChanged").toBool())

        try self.evaluate(
            """
            currentData = contentData;
            delete moviePlayer.classes['ad-showing'];
            fireVideoEvent('waiting');
            """,
            in: context
        )
        #expect(!context.evaluateScript("lastState().isAd").toBool())
        #expect(!context.evaluateScript("lastState().trackChanged").toBool())
    }

    @Test("Music waits for content metadata after an early ad-end event", arguments: [false, true], [false, true])
    func musicAdEndBeforeMetadata(startsDuringAd: Bool, metadataReturnsFirst: Bool) throws {
        let context = try self.makeContext(isMusic: true)
        if !startsDuringAd {
            try self.installObserver(isMusic: true, in: context)
        }
        try self.evaluate(
            """
            var contentData = currentData;
            currentData = { video_id: 'creative', title: 'Advertisement', author: 'Advertiser' };
            musicApi.presentingType = 2;
            musicApi.fire('onAdStart');
            """,
            in: context
        )
        if startsDuringAd {
            try self.installObserver(isMusic: true, in: context)
        }
        #expect(context.evaluateScript("lastState().isAd").toBool())
        #expect(!context.evaluateScript("lastState().trackChanged").toBool())

        if metadataReturnsFirst {
            try self.evaluate(
                "currentData.title = contentData.title; currentData.author = contentData.author; fireVideoEvent('waiting');",
                in: context
            )
        }
        try self.evaluate("musicApi.presentingType = 1; musicApi.fire('onAdEnd');", in: context)

        #expect(context.evaluateScript("lastState().isAd").toBool())
        #expect(!context.evaluateScript("lastState().trackChanged").toBool())

        try self.evaluate("currentData = contentData; fireVideoEvent('waiting');", in: context)
        #expect(!context.evaluateScript("lastState().isAd").toBool())
        #expect(context.evaluateScript("lastState().trackChanged").toBool() == startsDuringAd)
        #expect(context.evaluateScript("lastState().videoId").toString() == "content")
        #expect(context.evaluateScript("lastState().title").toString() == "Song")
    }

    @Test("Both players accept requested content when its metadata leads the watch URL during an ad", arguments: [false, true])
    func requestedMetadataDuringAd(isMusic: Bool) throws {
        let context = try self.makeContext(isMusic: isMusic)
        try self.installObserver(isMusic: isMusic, in: context)
        try self.evaluate(
            """
            currentData = { video_id: 'next', title: 'Next song', author: 'Artist' };
            var activeApi = \(isMusic ? "musicApi" : "moviePlayer");
            activeApi.presentingType = 2;
            activeApi.fire('onAdStart');
            window.location.href = 'https://\(isMusic ? "music" : "www").youtube.com/watch?v=next';
            activeApi.presentingType = 1;
            activeApi.fire('onAdEnd');
            """,
            in: context
        )

        #expect(!context.evaluateScript("lastState().isAd").toBool())
        if isMusic {
            #expect(context.evaluateScript("lastState().trackChanged").toBool())
        }
        #expect(context.evaluateScript("lastState().videoId").toString() == "next")
    }

    @Test("Early ad-end events preserve native content state on both players", arguments: [false, true])
    func earlyAdEndPreservesNativeState(isMusic: Bool) throws {
        let context = try self.makeContext(isMusic: isMusic)
        try self.installObserver(isMusic: isMusic, in: context)
        try self.evaluate(
            """
            var contentData = currentData;
            var activeApi = \(isMusic ? "musicApi" : "moviePlayer");
            currentData = { video_id: 'creative', title: 'Advertisement', author: 'Advertiser' };
            video.currentSrc = 'https://media.example/creative';
            video.currentTime = 0;
            video.duration = 30;
            activeApi.presentingType = 2;
            activeApi.fire('onAdStart');
            activeApi.presentingType = 1;
            activeApi.fire('onAdEnd');
            """,
            in: context
        )
        let isAd = context.evaluateScript("lastState().isAd").toBool()
        let hasReadyMedia = context.evaluateScript("lastState().hasReadyMedia").toBool()
        #expect(isAd)
        let standaloneDetection = """
        (function() {
            \(PlaybackAdDetectionScript.detection)
            return isAdShowing();
        })();
        """
        #expect(context.evaluateScript(standaloneDetection).toBool())
        if isMusic {
            #expect(!SingletonPlayerWebView.isAuthoritativePlaybackSample(
                hasReadyMedia: hasReadyMedia,
                isShowingAd: isAd
            ))
        } else {
            let controller = MockYouTubeWatchPlaybackController()
            let player = YouTubePlayerService(playbackController: controller)
            defer { player.stop() }
            player.play(video: MockYouTubeClient.makeVideo(videoId: "content"))
            player.updatePlaybackState(.init(
                isPlaying: true,
                progress: 12,
                duration: 180,
                hasReadyMedia: true,
                videoId: "content",
                boundVideoId: "content"
            ))
            player.updatePlaybackState(.init(
                isPlaying: context.evaluateScript("lastState().isPlaying").toBool(),
                progress: context.evaluateScript("lastState().progress").toDouble(),
                duration: context.evaluateScript("lastState().duration").toDouble(),
                hasReadyMedia: hasReadyMedia,
                videoId: context.evaluateScript("lastState().videoId").toString(),
                boundVideoId: context.evaluateScript("lastState().boundVideoId").toString(),
                title: context.evaluateScript("lastState().title").toString(),
                isAd: isAd
            ))
            let currentVideoId = player.currentVideo?.videoId
            let isShowingAd = player.isShowingAd
            #expect(currentVideoId == "content")
            #expect(isShowingAd)
            player.reloadCurrentVideoForIdentitySwitch()
            let recoveryPositions = controller.reloadResumeSeconds
            #expect(recoveryPositions == [12])
        }

        try self.evaluate("currentData = null;", in: context)
        #expect(context.evaluateScript(standaloneDetection).toBool())
        try self.evaluate(
            """
            currentData = contentData;
            video.currentSrc = 'https://media.example/content';
            video.currentTime = 12;
            video.duration = 180;
            fireVideoEvent('waiting');
            """,
            in: context
        )
        #expect(!context.evaluateScript("lastState().isAd").toBool())
        #expect(context.evaluateScript("lastState().videoId").toString() == "content")
    }

    @Test("Recovery seeks wait for content when only the player API identifies an ad")
    func recoverySeekWaitsForContent() throws {
        let context = try self.makeContext(isMusic: false)
        try self.evaluate("moviePlayer.presentingType = 2; video.__kasetBoundVideoId = 'content';", in: context)
        let script = YouTubeWatchWebView.seekWithRecoveryScript(
            documentGeneration: 7,
            target: 42,
            videoIdLiteral: "'content'",
            attemptID: 1
        )

        try self.evaluate(script, in: context)

        #expect(context.evaluateScript("video.currentTime").toDouble() == 12)
        #expect(context.evaluateScript("window.__kasetPendingSeek").toDouble() == 42)
    }

    private func installObserver(isMusic: Bool, in context: JSContext) throws {
        try self.evaluate(
            isMusic ? SingletonPlayerWebView.observerScript : YouTubeWatchWebView.observerScript,
            in: context
        )
    }

    private func makeContext(isMusic: Bool) throws -> JSContext {
        let context = try #require(JSContext())
        try self.evaluate(
            """
            var window = globalThis;
            var postedMessages = [];
            var videoListeners = {};
            var observers = [];
            var timers = [];
            var currentData = { video_id: 'content', title: 'Song', author: 'Artist' };
            var console = { log: function() {} };
            window.__kasetDocumentGeneration = 7;
            window.location = { href: 'https://\(isMusic ? "music" : "www").youtube.com/watch?v=content' };
            // JavaScriptCore has no browser URL API.
            var URL = function(value) { this.searchParams = { get: key => value.match(new RegExp('[?&]' + key + '=([^&]*)'))?.[1] || null }; };
            var bridge = { postMessage: function(message) { postedMessages.push(message); } };
            window.webkit = { messageHandlers: { singletonPlayer: bridge, youtubePlayer: bridge } };
            function setTimeout(callback) { timers.push(callback); return timers.length; }
            function clearTimeout() {}
            function setInterval() { return 1; }
            function clearInterval() {}
            function lastState() {
                return postedMessages.filter(function(message) { return message.type === 'STATE_UPDATE'; }).pop() || {};
            }
            function stateCount() {
                return postedMessages.filter(function(message) { return message.type === 'STATE_UPDATE'; }).length;
            }
            function fireVideoEvent(name) {
                (videoListeners[name] || []).forEach(function(handler) { handler({ type: name, currentTarget: video }); });
            }
            function makePlayer() {
                var player = {
                    classes: {},
                    listeners: {},
                    presentingType: 1,
                    getPresentingPlayerType: function() { return this.presentingType; },
                    getVideoData: function() { return currentData; },
                    addEventListener: function(name, handler) {
                        if (!this.listeners[name]) this.listeners[name] = [];
                        this.listeners[name].push(handler);
                    },
                    removeEventListener: function(name, handler) {
                        this.listeners[name] = (this.listeners[name] || []).filter(function(item) { return item !== handler; });
                    },
                    fire: function(name) { (this.listeners[name] || []).slice().forEach(function(handler) { handler(); }); }
                };
                player.classList = { contains: function(name) { return player.classes[name] === true; } };
                return player;
            }
            var moviePlayer = makePlayer();
            var musicApi = makePlayer();
            var musicPlayer = { playerApi: musicApi };
            var playerBar = {};
            var video = {
                currentTime: 12, duration: 180, currentSrc: 'https://media.example/content',
                paused: true, ended: false, readyState: 4, volume: 1, muted: false,
                seekable: { length: 1, start: function() { return 0; }, end: function() { return 180; } },
                addEventListener: function(name, handler) {
                    if (!videoListeners[name]) videoListeners[name] = [];
                    videoListeners[name].push(handler);
                }
            };
            var document = {
                title: 'Song - YouTube', readyState: 'complete', body: {}, documentElement: {},
                getElementById: function(id) { return id === 'movie_player' ? moviePlayer : null; },
                querySelector: function(selector) {
                    if (selector === 'video' || selector === '#movie_player video') return video;
                    if (selector === 'ytmusic-player' && \(isMusic)) return musicPlayer;
                    if (selector === 'ytmusic-player-bar' && \(isMusic)) return playerBar;
                    return null;
                },
                querySelectorAll: function() { return []; },
                addEventListener: function() {}
            };
            function MutationObserver(callback) {
                this.callback = callback;
                observers.push(this);
            }
            MutationObserver.prototype.observe = function(target, options) { this.target = target; this.options = options; };
            MutationObserver.prototype.disconnect = function() { this.target = null; };
            function notifyClassChange(target) {
                observers.slice().forEach(function(observer) {
                    if (observer.target === target && observer.options.attributes
                        && observer.options.attributeFilter.indexOf('class') !== -1) {
                        observer.callback([{ type: 'attributes', target: target, attributeName: 'class' }]);
                    }
                });
            }
            function notifyChildrenChanged() {
                observers.slice().forEach(function(observer) {
                    if ((observer.target === document.body || observer.target === document.documentElement)
                        && observer.options.childList) {
                        observer.callback([{ type: 'childList', target: observer.target }]);
                    }
                });
            }
            """,
            in: context
        )
        return context
    }

    private func evaluate(_ script: String, in context: JSContext) throws {
        context.exception = nil
        context.evaluateScript(script)
        try #require(context.exception == nil, "JavaScript exception: \(context.exception?.toString() ?? "")")
    }
}
