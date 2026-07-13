import JavaScriptCore
import Testing
@testable import Kaset

// MARK: - AutoplayRecoveryJSTests

@Suite(.tags(.service))
struct AutoplayRecoveryJSTests {
    private func makeContext() -> JSContext {
        let ctx = JSContext()!
        // JSCore has no DOM, so alias `window` onto the global object before
        // loading the recovery function (which references `window.__kaset…`).
        ctx.evaluateScript("var window = globalThis;")
        ctx.evaluateScript(SingletonPlayerWebView.autoplayRecoveryFunctionJS)
        return ctx
    }

    @Test("Clicks the player-bar button when the flag is set and video is paused")
    func clicksButtonWhenFlagPendingAndPaused() {
        let ctx = self.makeContext()
        ctx.evaluateScript(
            """
            window.__kasetAutoplayPending = true;
            var clicked = false;
            var played = false;
            var video = { paused: true, play: function() { played = true; } };
            var btn = { click: function() { clicked = true; } };
            globalThis.result = __kasetAttemptAutoplayRecovery(video, btn);
            """
        )
        #expect(ctx.evaluateScript("clicked").toBool() == true)
        #expect(ctx.evaluateScript("played").toBool() == false)
        #expect(ctx.evaluateScript("result").toString() == "clicked")
        #expect(ctx.evaluateScript("window.__kasetAutoplayPending").toBool() == true)
    }

    @Test("Falls back to video.play() when the player-bar button is not mounted")
    func fallsBackToVideoPlay() {
        let ctx = self.makeContext()
        ctx.evaluateScript(
            """
            window.__kasetAutoplayPending = true;
            var played = false;
            var video = { paused: true, play: function() { played = true; } };
            globalThis.result = __kasetAttemptAutoplayRecovery(video, null);
            """
        )
        #expect(ctx.evaluateScript("played").toBool() == true)
        #expect(ctx.evaluateScript("result").toString() == "played")
        #expect(ctx.evaluateScript("window.__kasetAutoplayPending").toBool() == true)
    }

    @Test("Does nothing and clears the flag when the video is already playing")
    func skipsWhenAlreadyPlaying() {
        let ctx = self.makeContext()
        ctx.evaluateScript(
            """
            window.__kasetAutoplayPending = true;
            var clicked = false;
            var video = { paused: false };
            var btn = { click: function() { clicked = true; } };
            globalThis.result = __kasetAttemptAutoplayRecovery(video, btn);
            """
        )
        #expect(ctx.evaluateScript("clicked").toBool() == false)
        #expect(ctx.evaluateScript("result").toString() == "noop")
        #expect(ctx.evaluateScript("window.__kasetAutoplayPending").toBool() == false)
    }

    @Test("Bounds repeated autoplay attempts while preserving future intent")
    func boundsAutoplayAttempts() {
        let ctx = self.makeContext()
        ctx.evaluateScript(
            """
            window.__kasetAutoplayPending = true;
            window.__kasetAutoplayAttempts = 5;
            var played = false;
            var video = { paused: true, play: function() { played = true; } };
            globalThis.result = __kasetAttemptAutoplayRecovery(video, null);
            """
        )

        #expect(ctx.evaluateScript("result").toString() == "exhausted")
        #expect(ctx.evaluateScript("played").toBool() == false)
        #expect(ctx.evaluateScript("window.__kasetAutoplayPending").toBool() == true)
    }

    @Test("Exhausted autoplay attempts wait for a fresh lifecycle or native play")
    func exhaustedAttemptsDoNotScheduleCooldown() {
        let ctx = self.makeContext()
        ctx.evaluateScript(
            """
            window.__kasetAutoplayPending = true;
            window.__kasetAutoplayAttempts = 5;
            var scheduled = 0;
            globalThis.setTimeout = function() { scheduled += 1; };
            var video = { paused: true, play: function() {} };
            globalThis.result = __kasetAttemptAutoplayRecovery(video, null);
            """
        )

        #expect(ctx.evaluateScript("result").toString() == "exhausted")
        #expect(ctx.evaluateScript("scheduled").toInt32() == 0)
        #expect(ctx.evaluateScript("window.__kasetAutoplayAttempts").toInt32() == 5)
        #expect(ctx.evaluateScript("window.__kasetAutoplayPending").toBool() == true)
    }

    @Test("Does nothing when the autoplay flag is not set")
    func skipsWhenFlagUnset() {
        let ctx = self.makeContext()
        ctx.evaluateScript(
            """
            window.__kasetAutoplayPending = false;
            var clicked = false;
            var played = false;
            var video = { paused: true, play: function() { played = true; } };
            var btn = { click: function() { clicked = true; } };
            globalThis.result = __kasetAttemptAutoplayRecovery(video, btn);
            """
        )
        #expect(ctx.evaluateScript("clicked").toBool() == false)
        #expect(ctx.evaluateScript("played").toBool() == false)
        #expect(ctx.evaluateScript("result").toString() == "noop")
    }

    @Test("Reports 'error' when video.play() throws")
    func reportsErrorWhenVideoPlayThrows() {
        let ctx = self.makeContext()
        ctx.evaluateScript(
            """
            window.__kasetAutoplayPending = true;
            var video = {
                paused: true,
                play: function() { throw new Error('blocked'); }
            };
            globalThis.result = __kasetAttemptAutoplayRecovery(video, null);
            """
        )
        #expect(ctx.evaluateScript("result").toString() == "error")
        #expect(ctx.evaluateScript("window.__kasetAutoplayPending").toBool() == true)
    }

    @Test("Observer script embeds the recovery function")
    func observerScriptEmbedsRecoveryFunction() {
        #expect(SingletonPlayerWebView.observerScript.contains("__kasetAttemptAutoplayRecovery"))
    }

    @Test("Observer script clears autoplay intent on successful playback")
    func observerScriptClearsAutoplayIntentOnPlayback() {
        #expect(SingletonPlayerWebView.observerScript.contains("window.__kasetAutoplayPending = false;"))
        #expect(SingletonPlayerWebView.observerScript.contains("window.__kasetAutoplayAttempts = 0;"))
    }

    @Test("Explicit play controls reset an exhausted autoplay retry budget")
    func explicitPlayControlsResetRetryBudget() {
        #expect(SingletonPlayerWebView.playCommandScript.contains("window.__kasetAutoplayAttempts = 0;"))
        #expect(SingletonPlayerWebView.playPauseCommandScript.contains("window.__kasetAutoplayAttempts = 0;"))
    }

    @Test("Explicit play controls share bounded autoplay recovery")
    func explicitPlayControlsUseSharedRecovery() {
        for script in [
            SingletonPlayerWebView.playCommandScript,
            SingletonPlayerWebView.playPauseCommandScript,
        ] {
            #expect(script.contains("window.__kasetAttemptAutoplayRecovery"))
        }
        #expect(SingletonPlayerWebView.observerScript.contains(
            "window.__kasetAttemptAutoplayRecovery = __kasetAttemptAutoplayRecovery;"
        ))
    }

    @Test("Observer retries asynchronous autoplay failures without dropping intent")
    func observerRetriesAsynchronousAutoplayFailures() {
        let script = SingletonPlayerWebView.autoplayRecoveryFunctionJS

        #expect(script.contains("playResult.catch"))
        #expect(script.contains("scheduleRetry()"))
        #expect(script.contains("attempts >= 5"))
    }

    @Test("A fresh native play request resets the bounded retry budget")
    func nativePlayResetsRetryBudget() {
        for script in [
            SingletonPlayerWebView.playCommandScript,
            SingletonPlayerWebView.playPauseCommandScript,
        ] {
            #expect(script.contains("window.__kasetAutoplayAttempts = 0;"))
            #expect(script.contains("window.__kasetAutoplayRetryScheduled = false;"))
        }
    }

    @Test("Committed autoplay synchronization is generation guarded")
    func autoplaySynchronizationIsGenerationGuarded() {
        let script = SingletonPlayerWebView.autoplayIntentSynchronizationScript(
            shouldAutoplay: false,
            nativePlaybackGeneration: 9,
            documentGeneration: 7
        )

        #expect(script.contains("window.__kasetDocumentGeneration !== 7"))
        #expect(script.contains("window.__kasetNativePlaybackGeneration = 9"))
        #expect(script.contains("window.__kasetAutoplayPending = false"))
        #expect(script.contains("window.__kasetPlaybackSuppressed = true"))
    }

    @Test("Restoration resume only unsuppresses ready advertisement media")
    func restoredAdResumeIsGated() {
        let source = try? String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/KasetTests/AutoplayRecoveryTests.swift",
            with: "Sources/Kaset/Views/SingletonPlayerWebView+PlaybackControls.swift"
        ))
        #expect(source?.contains("if (!isAd || !video || !video.currentSrc") == true)
        #expect(source?.contains("window.__kasetDocumentGeneration !==") == true)
        #expect(source?.contains("window.__kasetAttemptAutoplayRecovery(video, null)") == true)
    }

    @Test("Observer script retries recovery when media is already ready")
    func observerScriptRetriesRecoveryWhenMediaAlreadyReady() {
        #expect(SingletonPlayerWebView.observerScript.contains("video.readyState >= 3"))
    }

    @Test("Observer script schedules trailing throttled updates")
    func observerScriptSchedulesTrailingThrottledUpdates() {
        let script = SingletonPlayerWebView.observerScript

        #expect(script.contains("trailingUpdateTimeoutId"))
        #expect(script.contains("sendUpdate(true);"))
    }

    @Test("Observer uses media time updates when hidden timers are throttled")
    func observerUsesMediaTimeUpdates() {
        #expect(SingletonPlayerWebView.observerScript.contains(
            "video.addEventListener('timeupdate', () => sendUpdate());"
        ))
    }
}

// MARK: - AutoplayIntentScriptTests

@Suite(.tags(.service))
struct AutoplayIntentScriptTests {
    @Test("Sets the pending flag to true for a fresh navigation")
    func setsPendingTrue() {
        let script = SingletonPlayerWebView.autoplayIntentScript(isRestoringPlaybackSession: false)
        #expect(script == "window.__kasetAutoplayPending = true;")
    }

    @Test("Sets the pending flag to false during a restored session")
    func clearsPendingForRestoredSession() {
        let script = SingletonPlayerWebView.autoplayIntentScript(isRestoringPlaybackSession: true)
        #expect(script == "window.__kasetAutoplayPending = false;")
    }

    @Test("Explicit paused intent clears autoplay outside restoration")
    func clearsPendingForExplicitPausedIntent() {
        let script = SingletonPlayerWebView.autoplayIntentScript(shouldAutoplay: false)
        #expect(script == "window.__kasetAutoplayPending = false;")
    }

    @Test("Page bootstrap seeds document generation, autoplay intent, and target volume")
    func pageBootstrapSeedsDocumentGenerationIntentAndTargetVolume() {
        let script = SingletonPlayerWebView.pageBootstrapScript(
            isRestoringPlaybackSession: false,
            targetVolume: 0.42,
            documentGeneration: 42,
            nativePlaybackGeneration: 9
        )

        #expect(script.contains("window.location.search"))
        #expect(script.contains(".get('kasetDocumentGeneration')"))
        #expect(script.contains("rawGeneration === null"))
        #expect(script.contains("window.location.hash"))
        #expect(script.contains("window.__kasetDocumentGeneration = -1;"))
        #expect(script.contains("window.__kasetAutoplayPending = true;"))
        #expect(script.contains("window.__kasetAutoplayAttempts = 0;"))
        #expect(script.contains("window.__kasetTargetVolume = 0.42;"))
        #expect(script.contains("window.__kasetNativePlaybackGeneration = 9;"))
    }

    @Test("Page bootstrap clamps invalid target volume")
    func pageBootstrapClampsInvalidTargetVolume() {
        let script = SingletonPlayerWebView.pageBootstrapScript(
            isRestoringPlaybackSession: false,
            targetVolume: .infinity,
            documentGeneration: 7
        )

        #expect(script.contains("window.__kasetTargetVolume = 1.0;"))
    }
}

// MARK: - MusicPlaybackOccurrenceJSTests

@Suite(.tags(.service))
struct MusicPlaybackOccurrenceJSTests {
    private func makeContext() -> JSContext {
        let context = JSContext()!
        context.evaluateScript(SingletonPlayerWebView.playbackOccurrenceFunctionJS)
        return context
    }

    private func makeObserverContext() -> JSContext {
        let context = JSContext()!
        context.evaluateScript(
            """
            var messages = [];
            var listeners = {};
            function addListener(name, callback) {
                if (!listeners[name]) listeners[name] = [];
                listeners[name].push(callback);
            }
            function dispatch(name) {
                (listeners[name] || []).forEach(function(callback) { callback({ currentTarget: video }); });
            }
            function setTimeout() { return 1; }
            function clearTimeout() {}
            function setInterval() { return 1; }
            function clearInterval() {}
            function MutationObserver() { this.observe = function() {}; }

            var currentDataVideoId = 'v1';
            var video = {
                paused: false,
                ended: false,
                currentSrc: 'https://media.example/v1',
                src: '',
                currentTime: 179,
                duration: 180,
                readyState: 4,
                volume: 1,
                webkitCurrentPlaybackTargetIsWireless: false,
                addEventListener: addListener,
                pause: function() { this.paused = true; },
                play: function() { this.paused = false; }
            };
            var player = {
                playerApi: {
                    getVideoData: function() {
                        return { video_id: currentDataVideoId, title: currentDataVideoId, author: 'Artist' };
                    },
                    setVolume: function() {}
                }
            };
            var moviePlayer = {
                classList: { contains: function() { return false; } },
                getVideoData: function() { return { video_id: currentDataVideoId }; },
                setVolume: function() {}
            };
            var playerBar = {};
            var progressBar = {
                getAttribute: function(name) { return name === 'value' ? '179' : '180'; }
            };
            var titleElement = { textContent: 'v1' };
            var artistElement = { textContent: 'Artist' };
            var document = {
                readyState: 'complete',
                body: {},
                addEventListener: function() {},
                getElementById: function(id) { return id === 'movie_player' ? moviePlayer : null; },
                querySelectorAll: function() { return []; },
                querySelector: function(selector) {
                    if (selector === 'video') return video;
                    if (selector === 'ytmusic-player') return player;
                    if (selector === 'ytmusic-player-bar') return playerBar;
                    if (selector === '#progress-bar') return progressBar;
                    if (selector === '.ytmusic-player-bar.title') return titleElement;
                    if (selector === '.ytmusic-player-bar.byline') return artistElement;
                    return null;
                }
            };
            var window = globalThis;
            window.location = { href: 'https://music.youtube.com/watch?v=v1' };
            window.__kasetDocumentGeneration = 7;
            window.__kasetTargetVolume = 1;
            window.__kasetAutoplayPending = false;
            window.__kasetPlaybackSuppressed = false;
            window.webkit = {
                messageHandlers: {
                    singletonPlayer: {
                        postMessage: function(message) { messages.push(message); }
                    }
                }
            };
            """
        )
        context.evaluateScript(SingletonPlayerWebView.observerScript)
        return context
    }

    @Test("Leading metadata alone does not rebind the ending media occurrence")
    func leadingMetadataDoesNotRebindOccurrence() {
        let context = self.makeContext()

        #expect(context.evaluateScript(
            "__kasetShouldBindMediaOccurrence(true, false, false, true, false)"
        ).toBool() == false)
        #expect(context.evaluateScript(
            "__kasetShouldBindMediaOccurrence(true, true, false, true, false)"
        ).toBool() == true)
        #expect(context.evaluateScript(
            "__kasetShouldBindMediaOccurrence(true, false, true, false, false)"
        ).toBool() == true)
        #expect(context.evaluateScript(
            "__kasetShouldBindMediaOccurrence(true, false, true, true, false)"
        ).toBool() == false)
        #expect(context.evaluateScript(
            "__kasetShouldBindMediaOccurrence(true, false, false, true, true)"
        ).toBool() == true)
    }

    @Test("A replay after ended advances only the consumed occurrence")
    func replayAfterEndedAdvancesOccurrence() {
        let context = self.makeContext()

        #expect(context.evaluateScript(
            "__kasetShouldAdvanceEndedOccurrence(4, 4)"
        ).toBool() == true)
        #expect(context.evaluateScript(
            "__kasetShouldAdvanceEndedOccurrence(4, 5)"
        ).toBool() == false)
        #expect(context.evaluateScript(
            "__kasetShouldAdvanceEndedOccurrence(null, 4)"
        ).toBool() == false)
    }

    @Test("Observer state and ended payloads carry the media occurrence")
    func observerPayloadsCarryOccurrence() {
        let script = SingletonPlayerWebView.observerScript

        #expect(script.contains("mediaVideoId: mediaVideoId"))
        #expect(script.contains("mediaGeneration: mediaGeneration"))
        #expect(script.contains("mediaGeneration: occurrenceGeneration"))
        #expect(script.contains("function __kasetEventTimestampMilliseconds()"))
        #expect(script.contains("Number(performance.timeOrigin) + Number(performance.now())"))
        #expect(script.contains("eventIssuedAtMilliseconds: __kasetEventTimestampMilliseconds()"))
        #expect(script.contains("eventIssuedAtMilliseconds: now"))
        #expect(script.contains("setTimeout(() => retryTrackEnded(video, endedPayload), 16)"))
        #expect(script.contains("function trackEndedPayload(video)"))
        #expect(script.contains("function retryTrackEnded(video, payload)"))
        #expect(script.contains("video.__kasetEndedOccurrenceGeneration"))
        #expect(script.contains("video.__kasetBoundVideoId || lastVideoId || currentVideoId()"))
    }

    @Test("Late ended keeps the outgoing occurrence after metadata leads")
    func lateEndedKeepsOutgoingOccurrence() {
        let context = self.makeObserverContext()
        #expect(context.exception == nil)

        context.evaluateScript(
            """
            messages = [];
            currentDataVideoId = 'v2';
            titleElement.textContent = 'v2';
            dispatch('waiting');
            video.paused = true;
            video.ended = true;
            dispatch('ended');
            """
        )

        #expect(context.evaluateScript(
            "messages.filter(function(message) { return message.type === 'TRACK_ENDED'; })[0].videoId"
        ).toString() == "v1")
        #expect(context.evaluateScript(
            "messages.filter(function(message) { return message.type === 'TRACK_ENDED'; })[0].mediaGeneration"
        ).toInt32() == 1)

        context.evaluateScript(
            """
            video.currentSrc = 'https://media.example/v2';
            video.currentTime = 0;
            video.paused = false;
            video.ended = false;
            dispatch('loadedmetadata');
            video.paused = true;
            video.ended = true;
            dispatch('ended');
            """
        )

        #expect(context.evaluateScript(
            """
            messages.filter(function(message) { return message.type === 'TRACK_ENDED'; })
                .map(function(message) { return message.videoId; }).join(',')
            """
        ).toString() == "v1,v2")
        #expect(context.evaluateScript(
            """
            messages.filter(function(message) { return message.type === 'TRACK_ENDED'; })
                .map(function(message) { return message.mediaGeneration; }).join(',')
            """
        ).toString() == "1,2")
    }

    @Test("A queued ended callback cannot end a replayed media occurrence")
    func queuedEndedAfterReplayIsIgnored() {
        let context = self.makeObserverContext()
        context.evaluateScript(
            """
            messages = [];
            video.paused = true;
            video.ended = true;
            dispatch('ended');
            video.paused = false;
            video.ended = false;
            dispatch('play');
            dispatch('ended');
            """
        )

        #expect(context.evaluateScript(
            "messages.filter(function(message) { return message.type === 'TRACK_ENDED'; }).length"
        ).toInt32() == 1)
    }

    @Test("A backward seek cannot rebind old media to leading metadata")
    func backwardSeekDoesNotPermitLeadingIdentityRepair() {
        let context = self.makeObserverContext()
        context.evaluateScript(
            """
            messages = [];
            var initialGeneration = video.__kasetMediaGeneration;
            currentDataVideoId = 'v2';
            titleElement.textContent = 'v2';
            video.currentTime = 30;
            dispatch('seeked');
            var backwardSeekGeneration = video.__kasetMediaGeneration;
            dispatch('waiting');
            video.paused = true;
            video.ended = true;
            dispatch('ended');
            """
        )

        #expect(context.evaluateScript("video.__kasetBoundVideoId").toString() == "v1")
        #expect(context.evaluateScript(
            "video.__kasetMediaGeneration === backwardSeekGeneration"
        ).toBool() == true)
        #expect(context.evaluateScript(
            "backwardSeekGeneration === initialGeneration"
        ).toBool() == true)
        #expect(context.evaluateScript(
            "messages.filter(function(message) { return message.type === 'TRACK_ENDED'; })[0].videoId"
        ).toString() == "v1")
        #expect(context.evaluateScript(
            """
            messages.filter(function(message) { return message.type === 'TRACK_ENDED'; })[0].mediaGeneration
                === backwardSeekGeneration
            """
        ).toBool() == true)
    }

    @Test("Music source transition repairs identity when metadata catches up")
    func sourceTransitionRepairsLeadingIdentity() {
        let context = self.makeObserverContext()
        context.evaluateScript(
            """
            messages = [];
            video.currentSrc = 'https://media.example/v2';
            video.currentTime = 0;
            dispatch('loadedmetadata');
            currentDataVideoId = 'v2';
            titleElement.textContent = 'v2';
            dispatch('waiting');
            video.paused = true;
            video.ended = true;
            dispatch('ended');
            """
        )

        #expect(context.evaluateScript(
            "messages.filter(function(message) { return message.type === 'TRACK_ENDED'; })[0].videoId"
        ).toString() == "v2")
    }

    @Test("A backward seek preserves deferred source-transition identity repair")
    func backwardSeekPreservesDeferredIdentityRepair() {
        let context = self.makeObserverContext()
        context.evaluateScript(
            """
            messages = [];
            video.currentSrc = 'https://media.example/v2';
            video.currentTime = 0;
            dispatch('loadedmetadata');
            video.currentTime = 30;
            dispatch('timeupdate');
            video.currentTime = 5;
            dispatch('seeked');
            currentDataVideoId = 'v2';
            titleElement.textContent = 'v2';
            dispatch('waiting');
            video.paused = true;
            video.ended = true;
            dispatch('ended');
            """
        )

        #expect(context.evaluateScript("video.__kasetBoundVideoId").toString() == "v2")
        #expect(context.evaluateScript(
            "messages.filter(function(message) { return message.type === 'TRACK_ENDED'; })[0].videoId"
        ).toString() == "v2")
    }
}

// MARK: - MusicPlaybackClockJSTests

@Suite(.tags(.service))
struct MusicPlaybackClockJSTests {
    private func makeContext() -> JSContext {
        let context = JSContext()!
        context.evaluateScript(SingletonPlayerWebView.playbackClockFunctionJS)
        return context
    }

    @Test("Ready media clock wins over a lagging player bar")
    func readyMediaClockWins() {
        let context = self.makeContext()
        context.evaluateScript(
            """
            var media = { currentTime: 1.75, duration: 182 };
            var progressBar = {
                getAttribute: function(name) {
                    return name === 'value' ? '0' : '183';
                }
            };
            globalThis.clock = __kasetPlaybackClock(media, progressBar, true);
            """
        )

        #expect(context.evaluateScript("clock.progress").toDouble() == 1.75)
        #expect(context.evaluateScript("clock.duration").toDouble() == 182)
    }

    @Test("Unready media falls back to player bar clock")
    func unreadyMediaFallsBackToPlayerBar() {
        let context = self.makeContext()
        context.evaluateScript(
            """
            var media = { currentTime: 0, duration: Number.NaN };
            var progressBar = {
                getAttribute: function(name) {
                    return name === 'value' ? '42' : '180';
                }
            };
            globalThis.clock = __kasetPlaybackClock(media, progressBar, false);
            """
        )

        #expect(context.evaluateScript("clock.progress").toDouble() == 42)
        #expect(context.evaluateScript("clock.duration").toDouble() == 180)
    }

    @Test("Clock restoration script pauses and seeks physical media")
    func restorationScriptSeeksPhysicalMedia() throws {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            var pauseCount = 0;
            var media = {
                currentTime: 30,
                pause: function() { pauseCount += 1; }
            };
            var document = {
                querySelector: function(selector) {
                    return selector === 'video' ? media : null;
                }
            };
            """
        )

        let result = context.evaluateScript(
            SingletonPlayerWebView.seekAndPauseScript(to: 10)
        )

        #expect(result?.toString() == "seeked-paused")
        #expect(context.evaluateScript("media.currentTime").toDouble() == 10)
        #expect(context.evaluateScript("pauseCount").toInt32() == 2)
    }

    @Test("Invalid clocks degrade to zero")
    func invalidClocksDegradeToZero() {
        let context = self.makeContext()
        context.evaluateScript(
            """
            var media = { currentTime: Number.NaN, duration: Number.POSITIVE_INFINITY };
            var progressBar = { getAttribute: function() { return 'not-a-number'; } };
            globalThis.clock = __kasetPlaybackClock(media, progressBar, true);
            """
        )

        #expect(context.evaluateScript("clock.progress").toDouble() == 0)
        #expect(context.evaluateScript("clock.duration").toDouble() == 0)
    }
}

// MARK: - MusicPlaybackBridgeDecodingTests

@Suite(.tags(.service))
struct MusicPlaybackBridgeDecodingTests {
    @Test("Playback bridge preserves fractional media clocks")
    func preservesFractionalClocks() {
        #expect(SingletonPlayerWebView.finitePlaybackBridgeDouble(from: NSNumber(value: 1.75)) == 1.75)
        #expect(SingletonPlayerWebView.finitePlaybackBridgeDouble(from: 42) == 42)
    }

    @Test("Playback bridge rejects non-finite and Boolean clocks")
    func rejectsInvalidClocks() {
        #expect(SingletonPlayerWebView.finitePlaybackBridgeDouble(from: Double.infinity) == nil)
        #expect(SingletonPlayerWebView.finitePlaybackBridgeDouble(from: true) == nil)
        #expect(SingletonPlayerWebView.finitePlaybackBridgeDouble(from: "1.75") == nil)
    }
}
