import JavaScriptCore
import Testing
@testable import Kaset

/// Tests for singleton media-control script generation and scheduling.
@Suite(.serialized, .tags(.service))
@MainActor
struct MediaControlScriptTests {
    @Test("Bootstrap script reflects pending media-control style changes")
    func bootstrapScriptReflectsPendingStyleChanges() throws {
        let singleton = SingletonPlayerWebView.shared
        let originalUseNextPrev = SettingsManager.shared.mediaControlStyle == .nextPreviousTrack
        defer {
            singleton.setMediaControlStyle(useNextPrev: originalUseNextPrev)
        }

        singleton.setMediaControlStyle(useNextPrev: true)

        let context = try #require(JSContext())
        self.evaluateBootstrapStateScript(in: context)
        self.evaluate(singleton.mediaControlBootstrapScript(), in: context)

        let storedPreference = context.evaluateScript("localStorageValues.kasetUseNextPrev")?.toString()
        let windowPreference = context.evaluateScript("String(window.__kasetUseNextPrev)")?.toString()

        #expect(storedPreference == "true")
        #expect(windowPreference == "true")
    }

    @Test("Bootstrap wrapper blocks seekforward/seekbackward registrations when nextPrev is enabled")
    func bootstrapWrapperBlocksSeekHandlersInNextPrevMode() throws {
        let context = try #require(self.makeBootstrapWrapperContext())

        self.evaluate(SingletonPlayerWebView.mediaControlStyleBootstrapScript(useNextPrev: true), in: context)
        self.evaluate(
            """
            navigator.mediaSession.setActionHandler('seekforward', function() {});
            navigator.mediaSession.setActionHandler('seekbackward', function() {});
            navigator.mediaSession.setActionHandler('nexttrack', function() {});
            """,
            in: context
        )

        let calls = context.evaluateScript("mediaSessionCalls.join(',')")?.toString() ?? ""
        #expect(calls == "seekforward:clear,seekbackward:clear,nexttrack:set")
    }

    @Test("Bootstrap wrapper passes seekforward/seekbackward through when nextPrev is disabled")
    func bootstrapWrapperPassesSeekHandlersInSkipMode() throws {
        let context = try #require(self.makeBootstrapWrapperContext())

        self.evaluate(SingletonPlayerWebView.mediaControlStyleBootstrapScript(useNextPrev: false), in: context)
        self.evaluate(
            """
            navigator.mediaSession.setActionHandler('seekforward', function() {});
            navigator.mediaSession.setActionHandler('seekbackward', function() {});
            """,
            in: context
        )

        let calls = context.evaluateScript("mediaSessionCalls.join(',')")?.toString() ?? ""
        #expect(calls == "seekforward:set,seekbackward:set")
    }

    @Test("Bootstrap wrapper honors runtime toggle skip → nextPrev")
    func bootstrapWrapperHonorsRuntimeToggleToNextPrev() throws {
        let context = try #require(self.makeBootstrapWrapperContext())

        self.evaluate(SingletonPlayerWebView.mediaControlStyleBootstrapScript(useNextPrev: false), in: context)
        self.evaluate("navigator.mediaSession.setActionHandler('seekforward', function() {});", in: context)
        self.evaluate("window.__kasetUseNextPrev = true;", in: context)
        self.evaluate("navigator.mediaSession.setActionHandler('seekforward', function() {});", in: context)

        let calls = context.evaluateScript("mediaSessionCalls.join(',')")?.toString() ?? ""
        #expect(calls == "seekforward:set,seekforward:clear")
    }

    @Test("Bootstrap wrapper honors runtime toggle nextPrev → skip")
    func bootstrapWrapperHonorsRuntimeToggleToSkip() throws {
        let context = try #require(self.makeBootstrapWrapperContext())

        self.evaluate(SingletonPlayerWebView.mediaControlStyleBootstrapScript(useNextPrev: true), in: context)
        self.evaluate("navigator.mediaSession.setActionHandler('seekforward', function() {});", in: context)
        self.evaluate("window.__kasetUseNextPrev = false;", in: context)
        self.evaluate("navigator.mediaSession.setActionHandler('seekforward', function() {});", in: context)

        let calls = context.evaluateScript("mediaSessionCalls.join(',')")?.toString() ?? ""
        #expect(calls == "seekforward:clear,seekforward:set")
    }

    @Test("Bootstrap wrapper installs only once per page even on repeat injection")
    func bootstrapWrapperInstallsOnlyOnce() throws {
        let context = try #require(self.makeBootstrapWrapperContext())

        self.evaluate(SingletonPlayerWebView.mediaControlStyleBootstrapScript(useNextPrev: true), in: context)
        self.evaluate(SingletonPlayerWebView.mediaControlStyleBootstrapScript(useNextPrev: true), in: context)
        self.evaluate("navigator.mediaSession.setActionHandler('seekforward', function() {});", in: context)

        let clearCount = context.evaluateScript("""
            mediaSessionCalls.filter(function(c) { return c === 'seekforward:clear'; }).length
        """)?.toInt32() ?? -1
        #expect(clearCount == 1)
    }

    @Test("Bootstrap wrapper preserves passed-through handler reference for nexttrack")
    func bootstrapWrapperPreservesHandlerReference() throws {
        let context = try #require(self.makeBootstrapWrapperContext())

        self.evaluate(SingletonPlayerWebView.mediaControlStyleBootstrapScript(useNextPrev: true), in: context)
        self.evaluate(
            """
            window.__handlerInvoked = false;
            navigator.mediaSession.setActionHandler('nexttrack', function() {
                window.__handlerInvoked = true;
            });
            mediaSessionHandlers.nexttrack();
            """,
            in: context
        )

        let invoked = context.evaluateScript("String(window.__handlerInvoked)")?.toString()
        #expect(invoked == "true")
    }

    @Test("Bootstrap wrapper coexists with the override script's seek-handler clearing")
    func bootstrapWrapperCoexistsWithOverrideScript() throws {
        let context = try #require(self.makeOverrideScriptContext(useNextPrev: true))

        self.evaluate(SingletonPlayerWebView.mediaControlStyleBootstrapScript(useNextPrev: true), in: context)
        self.evaluate(SingletonPlayerWebView.mediaControlOverrideScript, in: context)
        self.evaluate("runNextAnimationFrame();", in: context)
        self.evaluate(
            """
            navigator.mediaSession.setActionHandler('seekforward', function() {});
            navigator.mediaSession.setActionHandler('seekbackward', function() {});
            """,
            in: context
        )

        let seekForwardClearCount = context.evaluateScript("""
            mediaSessionCalls.filter(function(c) { return c === 'seekforward:clear'; }).length
        """)?.toInt32() ?? 0
        let seekForwardSetCount = context.evaluateScript("""
            mediaSessionCalls.filter(function(c) { return c === 'seekforward:set'; }).length
        """)?.toInt32() ?? -1
        #expect(seekForwardClearCount > 0)
        #expect(seekForwardSetCount == 0)
    }

    @Test("Override script keeps a single animation-frame loop active")
    func overrideScriptKeepsSingleAnimationFrameLoop() throws {
        let context = try #require(self.makeOverrideScriptContext(useNextPrev: true))

        self.evaluate(SingletonPlayerWebView.mediaControlOverrideScript, in: context)

        let initialPendingCallbacks = context.evaluateScript("pendingRafCallbacks.length")?.toInt32() ?? -1
        let nextTrackSetCount = context.evaluateScript("""
            mediaSessionCalls.filter(function(call) {
                return call === 'nexttrack:set';
            }).length
        """)?.toInt32() ?? 0

        #expect(initialPendingCallbacks == 1)
        #expect(nextTrackSetCount > 0)

        self.evaluate("""
            videoListeners.playing();
            videoListeners.loadedmetadata();
            videoListeners.loadeddata();
            videoListeners.canplay();
            videoListeners.seeked();
        """, in: context)

        let callbacksAfterVideoEvents = context.evaluateScript("pendingRafCallbacks.length")?.toInt32() ?? -1
        #expect(callbacksAfterVideoEvents == 1)

        self.evaluate("runNextAnimationFrame();", in: context)
        let callbacksAfterFrameDrain = context.evaluateScript("pendingRafCallbacks.length")?.toInt32() ?? -1
        #expect(callbacksAfterFrameDrain == 1)
    }

    @Test("Playback audio quality bootstrap script stores selected quality")
    func playbackAudioQualityBootstrapStoresSelectedQuality() throws {
        let context = try #require(JSContext())
        self.evaluateBootstrapStateScript(in: context)

        self.evaluate(
            SingletonPlayerWebView.playbackAudioQualityBootstrapScript(quality: .high),
            in: context
        )

        let storedQuality = context.evaluateScript("localStorageValues.kasetPlaybackAudioQuality")?.toString()
        let windowQuality = context.evaluateScript("window.__kasetPlaybackAudioQuality")?.toString()

        #expect(storedQuality == "high")
        #expect(windowQuality == "high")
    }

    @Test("Playback audio quality sync script updates state and applies when available")
    func playbackAudioQualitySyncUpdatesStateAndApplies() throws {
        let context = try #require(JSContext())
        self.evaluateBootstrapStateScript(in: context)
        self.evaluate(
            """
            var applyCallCount = 0;
            window.__kasetApplyPlaybackAudioQuality = function() {
                applyCallCount += 1;
            };
            """,
            in: context
        )

        self.evaluate(
            SingletonPlayerWebView.playbackAudioQualitySyncScript(quality: .low),
            in: context
        )

        let storedQuality = context.evaluateScript("localStorageValues.kasetPlaybackAudioQuality")?.toString()
        let windowQuality = context.evaluateScript("window.__kasetPlaybackAudioQuality")?.toString()
        let applyCallCount = context.evaluateScript("applyCallCount")?.toInt32() ?? -1

        #expect(storedQuality == "low")
        #expect(windowQuality == "low")
        #expect(applyCallCount == 1)
    }

    @Test("Playback audio quality override script does not throw without YouTube APIs")
    func playbackAudioQualityOverrideDoesNotThrowWithoutYouTubeApis() throws {
        let context = try #require(JSContext())
        self.evaluate(
            """
            var localStorageValues = { kasetPlaybackAudioQuality: 'high' };
            var localStorage = {
                getItem: function(key) { return localStorageValues[key] || null; },
                setItem: function(key, value) { localStorageValues[key] = value; }
            };
            var window = {};
            var document = {
                documentElement: {},
                querySelector: function() { return null; },
                getElementById: function() { return null; }
            };
            function MutationObserver(callback) { this.callback = callback; }
            MutationObserver.prototype.observe = function() {};
            """,
            in: context
        )

        self.evaluate(SingletonPlayerWebView.playbackAudioQualityOverrideScript, in: context)

        let hasApplyFunction = context.evaluateScript(
            "typeof window.__kasetApplyPlaybackAudioQuality === 'function'"
        )?.toBool() ?? false

        #expect(hasApplyFunction)
    }

    @Test("Playback audio quality override applies mocked player API quality")
    func playbackAudioQualityOverrideAppliesMockedPlayerApiQuality() throws {
        let context = try #require(JSContext())
        self.evaluate(
            """
            var localStorageValues = { kasetPlaybackAudioQuality: 'high' };
            var localStorage = {
                getItem: function(key) { return localStorageValues[key] || null; },
                setItem: function(key, value) { localStorageValues[key] = value; }
            };
            var audioQualityCalls = [];
            var playbackQualityCalls = [];
            var playbackQualityRangeCalls = [];
            var optionCalls = [];
            var playerApi = {
                setAudioQuality: function(value) { audioQualityCalls.push(value); },
                setPlaybackQuality: function(value) { playbackQualityCalls.push(value); },
                setPlaybackQualityRange: function() {
                    playbackQualityRangeCalls.push(Array.prototype.slice.call(arguments));
                },
                setOption: function(module, option, value) {
                    optionCalls.push(module + ':' + option + ':' + value);
                }
            };
            var ytmusicPlayer = { playerApi: playerApi };
            var video = {
                addEventListener: function() {}
            };
            var document = {
                documentElement: {},
                querySelector: function(selector) {
                    if (selector === 'ytmusic-player') return ytmusicPlayer;
                    if (selector === 'video') return video;
                    return null;
                },
                getElementById: function() { return null; }
            };
            var window = {};
            function MutationObserver(callback) { this.callback = callback; }
            MutationObserver.prototype.observe = function() {};
            """,
            in: context
        )

        self.evaluate(SingletonPlayerWebView.playbackAudioQualityOverrideScript, in: context)

        let audioQuality = context.evaluateScript("audioQualityCalls[0]")?.toString()
        let playbackQualityCallCount = context.evaluateScript("playbackQualityCalls.length")?.toInt32() ?? -1
        let playbackQualityRangeCallCount = context.evaluateScript("playbackQualityRangeCalls.length")?.toInt32() ?? -1
        let optionCount = context.evaluateScript("optionCalls.length")?.toInt32() ?? -1

        #expect(audioQuality == "AUDIO_QUALITY_HIGH")
        #expect(playbackQualityCallCount == 0)
        #expect(playbackQualityRangeCallCount == 0)
        #expect(optionCount > 0)
    }

    @Test("Playback audio quality override coalesces repeated reapply scheduling")
    func playbackAudioQualityOverrideCoalescesRepeatedReapplyScheduling() throws {
        let context = try #require(JSContext())
        self.evaluate(
            """
            var pendingRafCallbacks = [];
            function requestAnimationFrame(callback) {
                pendingRafCallbacks.push(callback);
                return pendingRafCallbacks.length;
            }
            function runNextAnimationFrame() {
                var callback = pendingRafCallbacks.shift();
                if (callback) {
                    callback();
                }
            }
            var localStorageValues = { kasetPlaybackAudioQuality: 'normal' };
            var localStorage = {
                getItem: function(key) { return localStorageValues[key] || null; },
                setItem: function(key, value) { localStorageValues[key] = value; }
            };
            var audioQualityCalls = [];
            var playerApi = {
                setAudioQuality: function(value) { audioQualityCalls.push(value); }
            };
            var ytmusicPlayer = { playerApi: playerApi };
            var videoListeners = {};
            var video = {
                addEventListener: function(name, handler) {
                    videoListeners[name] = handler;
                }
            };
            var document = {
                documentElement: {},
                querySelector: function(selector) {
                    if (selector === 'ytmusic-player') return ytmusicPlayer;
                    if (selector === 'video') return video;
                    return null;
                },
                getElementById: function() { return null; }
            };
            var window = {};
            var mutationCallback = null;
            function MutationObserver(callback) { mutationCallback = callback; }
            MutationObserver.prototype.observe = function() {};
            """,
            in: context
        )

        self.evaluate(SingletonPlayerWebView.playbackAudioQualityOverrideScript, in: context)
        self.evaluate(
            """
            videoListeners.loadedmetadata();
            videoListeners.loadeddata();
            videoListeners.canplay();
            mutationCallback();
            """,
            in: context
        )

        let pendingBeforeDrain = context.evaluateScript("pendingRafCallbacks.length")?.toInt32() ?? -1
        #expect(pendingBeforeDrain == 1)

        self.evaluate("runNextAnimationFrame();", in: context)

        let pendingAfterDrain = context.evaluateScript("pendingRafCallbacks.length")?.toInt32() ?? -1
        let audioQualityCallCount = context.evaluateScript("audioQualityCalls.length")?.toInt32() ?? -1

        #expect(pendingAfterDrain == 0)
        #expect(audioQualityCallCount == 2)
    }

    private func makeBootstrapWrapperContext() -> JSContext? {
        guard let context = JSContext() else { return nil }

        self.evaluate(
            """
            var localStorageValues = {};
            var localStorage = {
                getItem: function(key) {
                    return Object.prototype.hasOwnProperty.call(localStorageValues, key)
                        ? localStorageValues[key]
                        : null;
                },
                setItem: function(key, value) {
                    localStorageValues[key] = value;
                }
            };
            var window = {};
            var mediaSessionCalls = [];
            var mediaSessionHandlers = {};
            var navigator = {
                mediaSession: {
                    setActionHandler: function(name, handler) {
                        mediaSessionCalls.push(name + ':' + (handler ? 'set' : 'clear'));
                        mediaSessionHandlers[name] = handler;
                    }
                }
            };
            """,
            in: context
        )

        return context
    }

    private func evaluateBootstrapStateScript(in context: JSContext) {
        self.evaluate(
            """
            var localStorageValues = {};
            var localStorage = {
                getItem: function(key) {
                    return Object.prototype.hasOwnProperty.call(localStorageValues, key)
                        ? localStorageValues[key]
                        : null;
                },
                setItem: function(key, value) {
                    localStorageValues[key] = value;
                }
            };
            var window = {};
            """,
            in: context
        )
    }

    private func makeOverrideScriptContext(useNextPrev: Bool) -> JSContext? {
        guard let context = JSContext() else { return nil }

        self.evaluate(
            """
            var pendingRafCallbacks = [];
            var nextRafId = 1;
            function requestAnimationFrame(callback) {
                pendingRafCallbacks.push(callback);
                return nextRafId++;
            }
            function runNextAnimationFrame() {
                var callback = pendingRafCallbacks.shift();
                if (callback) {
                    callback();
                }
            }
            var mediaSessionCalls = [];
            var navigator = {
                mediaSession: {
                    setActionHandler: function(name, handler) {
                        mediaSessionCalls.push(name + ':' + (handler ? 'set' : 'clear'));
                    }
                }
            };
            var localStorageValues = { kasetUseNextPrev: '\(useNextPrev ? "true" : "false")' };
            var localStorage = {
                getItem: function(key) {
                    return Object.prototype.hasOwnProperty.call(localStorageValues, key)
                        ? localStorageValues[key]
                        : null;
                },
                setItem: function(key, value) {
                    localStorageValues[key] = value;
                }
            };
            var videoListeners = {};
            var video = {
                addEventListener: function(name, handler) {
                    videoListeners[name] = handler;
                }
            };
            var document = {
                documentElement: {},
                querySelector: function(selector) {
                    if (selector === 'video') {
                        return video;
                    }
                    return null;
                }
            };
            function MutationObserver(callback) {
                this.callback = callback;
            }
            MutationObserver.prototype.observe = function() {};
            var postedMessages = [];
            var window = {
                webkit: {
                    messageHandlers: {
                        singletonPlayer: {
                            postMessage: function(message) {
                                postedMessages.push(message);
                            }
                        }
                    }
                }
            };
            """,
            in: context
        )

        return context
    }

    private func evaluate(_ script: String, in context: JSContext) {
        context.exception = nil
        _ = context.evaluateScript(script)

        if let exception = context.exception?.toString() {
            Issue.record("JavaScript exception: \(exception)")
        }
    }
}
