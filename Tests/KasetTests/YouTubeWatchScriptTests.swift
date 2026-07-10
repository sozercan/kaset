import Foundation
import JavaScriptCore
import Testing
@testable import Kaset

// MARK: - YouTubeWatchScriptTests

@Suite("YouTubeWatchWebView scripts", .tags(.service))
@MainActor
struct YouTubeWatchScriptTests {
    @Test("Observer script posts to the youtubePlayer bridge with both message types")
    func observerScriptContract() {
        let script = YouTubeWatchWebView.observerScript
        #expect(script.contains("webkit.messageHandlers.youtubePlayer"))
        #expect(script.contains("STATE_UPDATE"))
        #expect(script.contains("VIDEO_ENDED"))
        #expect(script.contains("movie_player"))
        #expect(script.contains("__kasetTargetVolume"))
    }

    @Test("Extraction script defines the callable hook and visibility chain")
    func extractionScriptContract() {
        let script = YouTubeWatchWebView.extractionScript
        #expect(script.contains("__kasetExtractVideo"))
        #expect(script.contains("kaset-yt-video-style"))
        #expect(script.contains("kaset-visible"))
        #expect(script.contains("ytp-chrome-bottom"))
    }

    @Test("Caption track script falls back to player response tracks")
    func captionTrackScriptUsesPlayerResponseFallback() {
        let script = YouTubeWatchWebView.availableCaptionTracksScript
        #expect(script.contains("playerCaptionsTracklistRenderer"))
        #expect(script.contains("captionTracks"))
        #expect(script.contains("track.name"))
        #expect(script.contains("track.vssId || track.languageCode"))
    }

    @Test("Caption selection script selects the full player response track")
    func captionSelectionUsesFullTrackObject() {
        let script = YouTubeWatchWebView.setCaptionTrackScript(languageCode: "en")
        #expect(script.contains("playerCaptionsTracklistRenderer"))
        #expect(script.contains("track.vssId === requested"))
        #expect(script.contains("requested.indexOf('.') !== -1"))
        #expect(script.contains("{ vssId: requested }"))
        #expect(script.contains("setOption('captions', 'track', selected)"))
    }

    @Test("Bootstrap script clamps the volume target")
    func bootstrapClampsVolume() {
        #expect(YouTubeWatchWebView.pageBootstrapScript(targetVolume: 2.0)
            .contains("__kasetTargetVolume = 1.0"))
        #expect(YouTubeWatchWebView.pageBootstrapScript(targetVolume: -1)
            .contains("__kasetTargetVolume = 0.0"))
    }

    @Test("Bootstrap carries a pending resume-seek when present")
    func bootstrapCarriesPendingSeek() {
        #expect(YouTubeWatchWebView.pageBootstrapScript(targetVolume: 1, pendingSeek: 42.5)
            .contains("__kasetPendingSeek = 42.5"))
        #expect(YouTubeWatchWebView.pageBootstrapScript(targetVolume: 1, pendingSeek: 0)
            .contains("__kasetPendingSeek = 0.0"))
        // No seek pending → no marker injected.
        #expect(!YouTubeWatchWebView.pageBootstrapScript(targetVolume: 1, pendingSeek: nil)
            .contains("__kasetPendingSeek"))
        // Negative is not a valid seek position.
        #expect(!YouTubeWatchWebView.pageBootstrapScript(targetVolume: 1, pendingSeek: -1)
            .contains("__kasetPendingSeek"))
    }

    @Test("Observer applies the pending seek gated on a seekable element")
    func observerAppliesPendingSeekWhenReady() {
        let script = YouTubeWatchWebView.observerScript
        // The seek is applied by the observer (not a one-shot at didFinish),
        // gated on readyState so it survives YouTube creating <video> late.
        #expect(script.contains("__kasetPendingSeek"))
        #expect(script.contains("applyPendingSeek"))
        #expect(script.contains("readyState"))
    }

    @Test("Observer skips the pending seek while an ad is showing")
    func observerSkipsPendingSeekDuringAd() {
        let script = YouTubeWatchWebView.observerScript
        // applyPendingSeek must bail on isAdShowing() so a preroll-ad element
        // doesn't consume the seek and leave content starting from 0.
        #expect(script.contains("isAdShowing()"))
    }

    @Test("A normal loadVideo clears a stale pending seek from an interrupted reload")
    func normalLoadClearsStalePendingSeek() {
        let webView = YouTubeWatchWebView.shared
        webView.pendingSeek = 99
        // loadVideo (the non-reload path) must drop the leftover seek so it can't
        // be injected into a different video. (No webView attached in tests, so
        // the load is a no-op beyond clearing the field.)
        webView.loadVideo(videoId: "different-video")
        #expect(webView.pendingSeek == nil)
    }

    @Test("Paused observer steady state does not install an interval update loop")
    func pausedObserverDoesNotInstallIntervalLoop() throws {
        let context = try self.makeObserverContext(paused: true)

        try self.evaluate(YouTubeWatchWebView.observerScript, in: context)

        #expect(context.evaluateScript("intervalCalls.length").toInt32() == 0)
        #expect(context.evaluateScript("postedMessages.length").toInt32() == 1)
        #expect(context.evaluateScript("postedMessages[0].type").toString() == "STATE_UPDATE")
        #expect(context.evaluateScript("postedMessages[0].isPlaying").toBool() == false)
    }

    @Test("Pause event sends one final forced state update without starting an interval")
    func pauseEventSendsFinalUpdateWithoutInterval() throws {
        let context = try self.makeObserverContext(paused: false)
        try self.evaluate(YouTubeWatchWebView.observerScript, in: context)
        try self.evaluate(
            """
            postedMessages = [];
            video.paused = true;
            fireVideoEvent('pause');
            """,
            in: context
        )

        #expect(context.evaluateScript("intervalCalls.length").toInt32() == 0)
        #expect(context.evaluateScript("postedMessages.length").toInt32() == 1)
        #expect(context.evaluateScript("postedMessages[0].type").toString() == "STATE_UPDATE")
        #expect(context.evaluateScript("postedMessages[0].isPlaying").toBool() == false)
    }

    @Test("Rediscovered attached video only posts when video identity changes")
    func rediscoveredAttachedVideoPostsOnlyWhenIdentityChanges() throws {
        let context = try self.makeObserverContext(paused: true)
        try self.evaluate(YouTubeWatchWebView.observerScript, in: context)

        try self.evaluate(
            """
            postedMessages = [];
            mutationCallbacks[0]();
            timeoutCalls[0].callback();
            """,
            in: context
        )

        #expect(context.evaluateScript("postedMessages.length").toInt32() == 0)

        try self.evaluate(
            """
            moviePlayer.getVideoData = function() { return { video_id: 'def456', title: 'Next Video' }; };
            mutationCallbacks[0]();
            timeoutCalls[1].callback();
            """,
            in: context
        )

        #expect(context.evaluateScript("postedMessages.length").toInt32() == 1)
        #expect(context.evaluateScript("postedMessages[0].videoId").toString() == "def456")
    }

    @Test("Extraction observer re-marks the video chain after attribute-only marker loss")
    func extractionObserverRepairsAttributeMarkerLoss() throws {
        let context = try self.makeExtractionContext()

        try self.evaluate(YouTubeWatchWebView.extractionScript, in: context)
        try self.evaluate("window.__kasetExtractVideo(); drainAnimationFrames(100);", in: context)
        #expect(context.evaluateScript("video.classList.contains('kaset-visible')").toBool())

        try self.evaluate(
            """
            video.classList.remove('kaset-visible');
            mutationCallbacks[1]();
            """,
            in: context
        )
        #expect(context.evaluateScript("rafQueue.length").toInt32() == 1)

        try self.evaluate("drainAnimationFrames(10);", in: context)
        #expect(context.evaluateScript("video.classList.contains('kaset-visible')").toBool())
    }

    @Test("Extraction stop prevents later mutation enforcement and clears markers")
    func extractionStopPreventsLaterMutationEnforcement() throws {
        let context = try self.makeExtractionContext()

        try self.evaluate(YouTubeWatchWebView.extractionScript, in: context)
        try self.evaluate("window.__kasetExtractVideo(); drainAnimationFrames(100);", in: context)
        #expect(context.evaluateScript("document.querySelectorAll('.kaset-visible').length").toInt32() > 0)

        try self.evaluate(
            """
            window.__kasetStopYTExtraction();
            mutationCallbacks[0]();
            """,
            in: context
        )

        #expect(context.evaluateScript("window.__kasetYTVideoActive").toBool() == false)
        #expect(context.evaluateScript("rafQueue.length").toInt32() == 0)
        #expect(context.evaluateScript("document.querySelectorAll('.kaset-visible').length").toInt32() == 0)
    }

    @Test("Extraction enforcement drains bounded RAF work instead of scheduling forever")
    func extractionEnforcementDoesNotScheduleEndlessRAF() throws {
        let context = try self.makeExtractionContext()

        try self.evaluate(YouTubeWatchWebView.extractionScript, in: context)
        try self.evaluate("window.__kasetExtractVideo(); drainAnimationFrames(100);", in: context)

        #expect(context.evaluateScript("rafQueue.length").toInt32() == 0)
        #expect(context.evaluateScript("rafScheduledCount").toInt32() <= 16)

        try self.evaluate(
            """
            mutationCallbacks[0]();
            drainAnimationFrames(100);
            """,
            in: context
        )

        #expect(context.evaluateScript("rafQueue.length").toInt32() == 0)
        #expect(context.evaluateScript("rafScheduledCount").toInt32() <= 32)
    }
}

private extension YouTubeWatchScriptTests {
    func makeObserverContext(paused: Bool) throws -> JSContext {
        let context = try #require(JSContext())
        try self.evaluate(
            """
            var postedMessages = [];
            var intervalCalls = [];
            var timeoutCalls = [];
            var now = 1000;
            Date.now = function() { return now; };

            function setInterval(callback, milliseconds) {
                intervalCalls.push({ callback: callback, milliseconds: milliseconds });
                return intervalCalls.length;
            }
            function clearInterval(id) {}
            function setTimeout(callback, milliseconds) {
                timeoutCalls.push({ callback: callback, milliseconds: milliseconds });
                return timeoutCalls.length;
            }
            function clearTimeout(id) {}

            var window = {
                webkit: {
                    messageHandlers: {
                        youtubePlayer: {
                            postMessage: function(message) { postedMessages.push(message); }
                        }
                    }
                }
            };
            var console = { log: function() {} };

            var videoListeners = {};
            var video = {
                paused: \(paused ? "true" : "false"),
                ended: false,
                currentTime: 12,
                duration: 120,
                readyState: 4,
                muted: false,
                volume: 1,
                addEventListener: function(name, handler) {
                    if (!videoListeners[name]) { videoListeners[name] = []; }
                    videoListeners[name].push(handler);
                }
            };
            function fireVideoEvent(name) {
                (videoListeners[name] || []).forEach(function(handler) { handler(); });
            }

            var moviePlayer = {
                classList: { contains: function() { return false; } },
                getVideoData: function() { return { video_id: 'abc123', title: 'Test Video' }; },
                unMute: function() {}
            };
            var documentListeners = {};
            var document = {
                title: 'Test Video - YouTube',
                readyState: 'complete',
                body: {},
                documentElement: {},
                getElementById: function(id) { return id === 'movie_player' ? moviePlayer : null; },
                querySelector: function(selector) {
                    if (selector === '#movie_player video' || selector === 'video') { return video; }
                    if (selector === '.ytp-autonav-toggle-button') { return null; }
                    return null;
                },
                addEventListener: function(name, handler) { documentListeners[name] = handler; }
            };
            var mutationCallbacks = [];
            function MutationObserver(callback) {
                this.callback = callback;
                mutationCallbacks.push(callback);
            }
            MutationObserver.prototype.observe = function() {};
            MutationObserver.prototype.disconnect = function() {};
            """,
            in: context
        )
        return context
    }

    func makeExtractionContext() throws -> JSContext {
        let context = try #require(JSContext())
        try self.evaluate(
            """
            var window = {};
            var console = { log: function() {} };

            function makeElement(name, parent) {
                var element = { name: name, parentElement: parent, classes: {}, id: '', textContent: '' };
                element.classList = {
                    add: function(value) { element.classes[value] = true; },
                    remove: function(value) { delete element.classes[value]; },
                    contains: function(value) { return !!element.classes[value]; }
                };
                return element;
            }

            var elementsById = {};
            var html = makeElement('html', null);
            var body = makeElement('body', html);
            var player = makeElement('movie_player', body);
            var video = makeElement('video', player);
            var allElements = [html, body, player, video];

            var document = {
                documentElement: html,
                body: body,
                head: {
                    appendChild: function(element) {
                        if (element.id) { elementsById[element.id] = element; }
                    }
                },
                createElement: function(name) {
                    var element = makeElement(name, null);
                    return element;
                },
                getElementById: function(id) { return elementsById[id] || null; },
                querySelector: function(selector) {
                    if (selector === '#movie_player video' || selector === 'video') { return video; }
                    return null;
                },
                querySelectorAll: function(selector) {
                    if (selector !== '.kaset-visible') { return []; }
                    return allElements.filter(function(element) {
                        return element.classList.contains('kaset-visible');
                    });
                }
            };

            var mutationCallbacks = [];
            function MutationObserver(callback) {
                this.callback = callback;
                mutationCallbacks.push(callback);
            }
            MutationObserver.prototype.observe = function() {};
            MutationObserver.prototype.disconnect = function() {};

            var rafQueue = [];
            var rafScheduledCount = 0;
            function requestAnimationFrame(callback) {
                rafScheduledCount += 1;
                rafQueue.push(callback);
                return rafScheduledCount;
            }
            function drainAnimationFrames(limit) {
                var ran = 0;
                while (rafQueue.length && ran < limit) {
                    var callback = rafQueue.shift();
                    callback();
                    ran += 1;
                }
                return ran;
            }
            """,
            in: context
        )
        return context
    }

    func evaluate(_ script: String, in context: JSContext) throws {
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
