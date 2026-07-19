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
        let payloads = self.objectPayloads(
            in: script,
            marker: "bridge.postMessage({",
            terminator: "});"
        )
        #expect(self.occurrenceCount(of: "postMessage(", in: script) == 2)
        #expect(payloads.count == 2)
        for payload in payloads {
            #expect(payload.contains("documentGeneration: window.__kasetDocumentGeneration"))
            #expect(payload.contains("mediaGeneration:"))
        }
        #expect(payloads.contains { $0.contains("type: 'STATE_UPDATE'") })
        #expect(payloads.contains { $0.contains("type: 'VIDEO_ENDED'") })
        let statePayload = payloads.first { $0.contains("type: 'STATE_UPDATE'") }
        #expect(statePayload?.contains("hasReadyMedia: hasReadyMedia") == true)
        #expect(statePayload?.contains("pendingSeekApplied: pendingSeekApplied") == true)
        #expect(statePayload?.contains("pendingSeekFailed: pendingSeekFailed") == true)
        #expect(statePayload?.contains("pendingSeekVideoId: pendingSeekVideoId") == true)
        #expect(statePayload?.contains("nativePausePending: nativePausePending") == true)
        #expect(statePayload?.contains("pendingSeekAttempt: pendingSeekAttempt") == true)
        let endedPayload = payloads.first { $0.contains("type: 'VIDEO_ENDED'") }
        #expect(endedPayload?.contains(
            "pendingSeekAttempt: window.__kasetPendingSeekAttempt"
        ) == true)
    }

    @Test("Observer rejects ended callbacks from stale video elements")
    func observerRejectsEndedCallbacksFromStaleVideoElements() {
        let script = YouTubeWatchWebView.observerScript
        #expect(script.contains("function sendEnded(video)"))
        #expect(script.contains("if (video !== videoEl() || !video.ended"))
        #expect(script.contains("function bindVideoIdentity(video, transitionEvidence)"))
        #expect(script.contains("video.__kasetBoundVideoId = resolvedVideoId"))
        #expect(script.contains("video.__kasetEndedReported = true"))
        #expect(script.contains("const endedVideo = event.currentTarget;"))
        #expect(script.contains("sendEnded(endedVideo);"))
        #expect(!script.contains("lastVideoId"))
        #expect(!script.contains("__kasetContentVideoId"))
    }

    @Test("VIDEO_ENDED reports generation, bound video identity, and event-time ad state")
    func endedPayloadIncludesBoundIdentityAndAdState() {
        let payloads = self.objectPayloads(
            in: YouTubeWatchWebView.observerScript,
            marker: "bridge.postMessage({",
            terminator: "});"
        )
        let endedPayload = payloads.first { $0.contains("type: 'VIDEO_ENDED'") }
        #expect(endedPayload?.contains(
            "documentGeneration: window.__kasetDocumentGeneration"
        ) == true)
        #expect(endedPayload?.contains(
            "videoId: video.__kasetBoundVideoId || currentVideoId()"
        ) == true)
        #expect(endedPayload?.contains(
            "mediaGeneration: video.__kasetMediaGeneration || mediaGeneration"
        ) == true)
        #expect(endedPayload?.contains("isAd: isAdShowing()") == true)
    }

    @Test("VIDEO_ENDED is executable-idempotent per playback occurrence")
    func endedEventIsIdempotentPerOccurrence() throws {
        let context = try self.makeGenerationObserverContext(videoId: "abc")
        context.evaluateScript(
            """
            messages = [];
            video.paused = true;
            video.ended = true;
            listeners.ended({ currentTarget: video });
            currentDataVideoId = 'def';
            listeners.pause({ currentTarget: video });
            listeners.ended({ currentTarget: video });
            """
        )

        #expect(context.evaluateScript(
            "messages.filter(function(message) { return message.type === 'VIDEO_ENDED'; }).length"
        ).toInt32() == 1)

        context.evaluateScript(
            """
            currentDataVideoId = 'ghi';
            video.currentSrc = 'https://media.example/ghi';
            video.paused = false;
            video.ended = false;
            listeners.playing({ currentTarget: video });
            video.paused = true;
            video.ended = true;
            listeners.ended({ currentTarget: video });
            """
        )

        #expect(context.evaluateScript(
            """
            messages.filter(function(message) { return message.type === 'VIDEO_ENDED'; })
                .map(function(message) { return message.videoId; }).join(',')
            """
        ).toString() == "abc,ghi")
        #expect(context.evaluateScript(
            """
            messages.filter(function(message) { return message.type === 'VIDEO_ENDED'; })
                .map(function(message) { return message.mediaGeneration; }).join(',')
            """
        ).toString() == "1,2")
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
        #expect(YouTubeWatchWebView.pageBootstrapScript(targetVolume: 2.0, documentGeneration: 0)
            .contains("__kasetTargetVolume = 1.0"))
        #expect(YouTubeWatchWebView.pageBootstrapScript(targetVolume: -1, documentGeneration: 0)
            .contains("__kasetTargetVolume = 0.0"))
    }

    @Test("Main-frame playback responses reject expected-origin HTTP failures")
    func mainFramePlaybackResponsesRejectHTTPFailures() throws {
        let url = try #require(URL(string: "https://www.youtube.com/watch?v=abc"))
        let success = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        let notFound = try #require(HTTPURLResponse(
            url: url,
            statusCode: 404,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        let serverError = try #require(HTTPURLResponse(
            url: url,
            statusCode: 503,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        let documentGeneration = WebPlaybackDocumentGeneration()

        #expect(YouTubeWatchWebView.acceptsMainFrameResponse(
            success,
            expectedVideoID: "abc",
            documentGeneration: documentGeneration
        ))
        #expect(!YouTubeWatchWebView.acceptsMainFrameResponse(
            notFound,
            expectedVideoID: "abc",
            documentGeneration: documentGeneration
        ))
        #expect(!YouTubeWatchWebView.acceptsMainFrameResponse(
            serverError,
            expectedVideoID: "abc",
            documentGeneration: documentGeneration
        ))
    }

    @Test("Bootstrap carries its document generation")
    func bootstrapCarriesDocumentGeneration() {
        let script = YouTubeWatchWebView.pageBootstrapScript(
            targetVolume: 1,
            documentGeneration: 42
        )
        #expect(script.contains("window.location.search"))
        #expect(script.contains(".get('kasetDocumentGeneration')"))
        #expect(script.contains("rawGeneration === null"))
        #expect(script.contains("window.location.hash"))
        #expect(script.contains("window.__kasetDocumentGeneration = -1;"))
    }

    @Test("Bootstrap carries a pending resume-seek when present")
    func bootstrapCarriesPendingSeek() {
        #expect(YouTubeWatchWebView.pageBootstrapScript(
            targetVolume: 1,
            documentGeneration: 0,
            pendingSeek: 42.5,
            pendingSeekVideoId: "video-id"
        ).contains("__kasetPendingSeek = 42.5"))
        #expect(YouTubeWatchWebView.pageBootstrapScript(
            targetVolume: 1,
            documentGeneration: 0,
            pendingSeek: 42.5,
            pendingSeekVideoId: "video-id"
        ).contains("__kasetPendingSeekVideoId = \"video-id\""))
        #expect(YouTubeWatchWebView.pageBootstrapScript(
            targetVolume: 1,
            documentGeneration: 0,
            pendingSeek: 0
        ).contains("__kasetPendingSeek = 0.0"))
        // No seek pending → no marker injected.
        #expect(!YouTubeWatchWebView.pageBootstrapScript(
            targetVolume: 1,
            documentGeneration: 0,
            pendingSeek: nil
        ).contains("__kasetPendingSeek"))
        // Negative is not a valid seek position.
        #expect(!YouTubeWatchWebView.pageBootstrapScript(
            targetVolume: 1,
            documentGeneration: 0,
            pendingSeek: -1
        ).contains("__kasetPendingSeek"))
    }

    @Test("Observer applies the pending seek gated on a seekable element")
    func observerAppliesPendingSeekWhenReady() {
        let script = YouTubeWatchWebView.observerScript
        // The seek is applied by the observer (not a one-shot at didFinish),
        // gated on readyState so it survives YouTube creating <video> late.
        #expect(script.contains("__kasetPendingSeek"))
        #expect(script.contains("video.seekable.length === 0"))
        #expect(script.contains("boundVideoId !== expectedVideoId"))
        #expect(
            script.range(of: "if (isAdShowing()) { return; }")?.lowerBound
                ?? script.startIndex
                < (script.range(of: "boundVideoId !== expectedVideoId")?.lowerBound ?? script.endIndex)
        )
        #expect(
            script.range(of: "!video.currentSrc")?.lowerBound
                ?? script.startIndex
                < (script.range(of: "boundVideoId !== expectedVideoId")?.lowerBound ?? script.endIndex)
        )
        #expect(script.contains("const hasFiniteDuration = video.duration && isFinite(video.duration)"))
        #expect(script.contains("function stillOwnsSeekOperation()"))
        #expect(script.contains("video.__kasetMediaGeneration || 0) === seekMediaGeneration"))
        #expect(script.contains("video.currentSrc === seekSource"))
        #expect(script.contains("window.__kasetPendingSeekApplied = true"))
        #expect(script.contains("window.__kasetPendingSeekFailed = true"))
        #expect(script.contains("applyPendingSeek"))
        #expect(script.contains("readyState"))
    }

    @Test("Pending-seek acknowledgement carries identity before getVideoData is ready")
    func pendingSeekAcknowledgementCarriesExpectedIdentity() throws {
        let context = try self.makeGenerationObserverContext(
            videoId: "",
            pendingSeek: 42,
            pendingSeekVideoId: "abc"
        )

        context.evaluateScript("runNextTimeout();")

        #expect(context.evaluateScript("messages[messages.length - 1].videoId").toString().isEmpty)
        #expect(context.evaluateScript(
            "messages[messages.length - 1].pendingSeekApplied"
        ).toBool())
        #expect(context.evaluateScript(
            "messages[messages.length - 1].pendingSeekVideoId"
        ).toString() == "abc")
        #expect(context.evaluateScript("window.__kasetPendingSeekVideoId === null").toBool())
    }

    @Test("Pending-seek cancellation only mutates the matching document generation")
    func pendingSeekCancellationIsGenerationGated() throws {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            var window = globalThis;
            window.__kasetDocumentGeneration = 8;
            window.__kasetPendingSeek = 42;
            window.__kasetPendingSeekVideoId = 'abc';
            window.__kasetPendingSeekAttempt = 5;
            window.__kasetPendingSeekApplied = true;
            window.__kasetPendingSeekFailed = true;
            window.__kasetPendingSeekResultTarget = 42;
            window.__kasetPendingSeekResultVideoId = 'abc';
            """
        )

        context.evaluateScript(
            YouTubeWatchWebView.pendingSeekCancellationScript(documentGeneration: 7)
        )
        #expect(context.evaluateScript("window.__kasetPendingSeek").toDouble() == 42)

        context.evaluateScript(
            YouTubeWatchWebView.pendingSeekCancellationScript(documentGeneration: 8)
        )
        #expect(context.evaluateScript("window.__kasetPendingSeek === null").toBool())
        #expect(context.evaluateScript("window.__kasetPendingSeekVideoId === null").toBool())
        #expect(!context.evaluateScript("window.__kasetPendingSeekApplied").toBool())
        #expect(!context.evaluateScript("window.__kasetPendingSeekFailed").toBool())
    }

    @Test("Pending-seek completion is keyed by generation, target, and video")
    func pendingSeekCompletionIsKeyed() throws {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            var window = globalThis;
            window.__kasetDocumentGeneration = 8;
            window.__kasetPendingSeek = 42;
            window.__kasetPendingSeekVideoId = 'abc';
            window.__kasetPendingSeekAttempt = 5;
            """
        )

        context.evaluateScript(YouTubeWatchWebView.pendingSeekCompletionScript(
            documentGeneration: 8,
            attemptID: 5,
            target: 43,
            videoId: "abc"
        ))
        #expect(context.evaluateScript("window.__kasetPendingSeek").toDouble() == 42)

        context.evaluateScript(YouTubeWatchWebView.pendingSeekCompletionScript(
            documentGeneration: 8,
            attemptID: 5,
            target: 42,
            videoId: "other"
        ))
        #expect(context.evaluateScript("window.__kasetPendingSeek").toDouble() == 42)

        context.evaluateScript(YouTubeWatchWebView.pendingSeekCompletionScript(
            documentGeneration: 8,
            attemptID: 4,
            target: 42,
            videoId: "abc"
        ))
        #expect(context.evaluateScript("window.__kasetPendingSeek").toDouble() == 42)

        context.evaluateScript(YouTubeWatchWebView.pendingSeekCompletionScript(
            documentGeneration: 8,
            attemptID: 5,
            target: 42,
            videoId: "abc"
        ))
        #expect(context.evaluateScript("window.__kasetPendingSeek === null").toBool())
        #expect(context.evaluateScript("window.__kasetPendingSeekVideoId === null").toBool())
    }

    @Test("Observer skips the pending seek while an ad is showing")
    func observerSkipsPendingSeekDuringAd() {
        let script = YouTubeWatchWebView.observerScript
        // applyPendingSeek must bail on isAdShowing() so a preroll-ad element
        // doesn't consume the seek and leave content starting from 0.
        #expect(script.contains("isAdShowing()"))
    }

    @Test("Pending seek waits for the bound media identity instead of leading metadata")
    func pendingSeekWaitsForBoundMediaIdentity() throws {
        let context = try self.makeGenerationObserverContext(
            videoId: "abc",
            pendingSeek: 42,
            pendingSeekVideoId: "def"
        )

        context.evaluateScript(
            """
            currentDataVideoId = 'def';
            listeners.pause({ currentTarget: video });
            """
        )

        #expect(context.evaluateScript("video.currentTime").toDouble() == 0)
        #expect(context.evaluateScript("window.__kasetPendingSeek").toDouble() == 42)
        #expect(!context.evaluateScript("window.__kasetPendingSeekApplied").toBool())
        #expect(!context.evaluateScript("window.__kasetPendingSeekFailed").toBool())
    }

    @Test("Direct seek arming gates the eager write on bound content media")
    func directSeekArmingIsMediaGated() {
        let script = YouTubeWatchWebView.seekWithRecoveryScript(
            documentGeneration: 7,
            target: 42,
            videoIdLiteral: "'abc'",
            attemptID: 9
        )

        #expect(script.contains("classList.contains('ad-showing')"))
        #expect(script.contains("video.readyState < 1"))
        #expect(script.contains("video.__kasetBoundVideoId"))
        #expect(script.contains("video.seekable.length === 0"))
    }

    @Test("A source transition clears stale identity and repairs it when metadata arrives")
    func sourceTransitionRepairsUnknownIdentity() throws {
        let context = try self.makeGenerationObserverContext(videoId: "abc")
        context.evaluateScript(
            """
            currentDataVideoId = '';
            video.currentSrc = 'https://media.example/replacement';
            listeners.loadedmetadata({ currentTarget: video });
            """
        )
        #expect(context.evaluateScript("video.__kasetBoundVideoId").toString().isEmpty)

        context.evaluateScript(
            """
            currentDataVideoId = 'def';
            listeners.pause({ currentTarget: video });
            """
        )
        #expect(context.evaluateScript("video.__kasetBoundVideoId").toString() == "def")
    }

    @Test("Deferred pending-seek work stops after the media occurrence changes")
    func pendingSeekDeferredWorkIsOccurrenceGated() throws {
        let context = try self.makeGenerationObserverContext(
            videoId: "abc",
            pendingSeek: 42,
            pendingSeekVideoId: "abc"
        )
        context.evaluateScript(
            """
            video.currentTime = 0;
            video.currentSrc = 'https://media.example/replacement';
            video.__kasetMediaGeneration += 1;
            runNextTimeout();
            """
        )

        #expect(context.evaluateScript("video.currentTime").toDouble() == 0)
        #expect(context.evaluateScript("window.__kasetPendingSeek").toDouble() == 42)
        #expect(!context.evaluateScript("window.__kasetPendingSeekApplied").toBool())
    }

    @Test("Pending seek serializes one timer per retry attempt")
    func pendingSeekSerializesRetryAttempts() throws {
        let context = try self.makeGenerationObserverContext(
            videoId: "abc",
            pendingSeek: 42,
            pendingSeekVideoId: "abc"
        )
        #expect(context.evaluateScript("scheduledTimeouts.length").toInt32() == 1)

        context.evaluateScript("listeners.seeked({ currentTarget: video });")
        #expect(context.evaluateScript("scheduledTimeouts.length").toInt32() == 1)

        context.evaluateScript(
            """
            window.__kasetPendingSeek = 42;
            window.__kasetPendingSeekVideoId = 'abc';
            window.__kasetPendingSeekAttempt += 1;
            window.__kasetPendingSeekInFlightAttempt = null;
            listeners.seeked({ currentTarget: video });
            """
        )
        #expect(context.evaluateScript("scheduledTimeouts.length").toInt32() == 2)

        context.evaluateScript("runNextTimeout();")
        #expect(context.evaluateScript("window.__kasetPendingSeek").toDouble() == 42)
        #expect(!context.evaluateScript("window.__kasetPendingSeekApplied").toBool())
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

    private func objectPayloads(in script: String, marker: String, terminator: String) -> [String] {
        script.components(separatedBy: marker).dropFirst().compactMap { suffix in
            suffix.components(separatedBy: terminator).first
        }
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func makeGenerationObserverContext(
        videoId: String,
        pendingSeek: Double? = nil,
        pendingSeekVideoId: String? = nil
    ) throws -> JSContext {
        let context = try #require(JSContext())
        let videoIdLiteral = YouTubeWatchWebView.jsStringLiteral(videoId)
        let pendingSeekScript = pendingSeek.map {
            "window.__kasetPendingSeek = \($0);"
        } ?? ""
        let pendingSeekVideoIdScript = pendingSeekVideoId.map {
            "window.__kasetPendingSeekVideoId = \(YouTubeWatchWebView.jsStringLiteral($0));"
        } ?? ""
        context.evaluateScript(
            """
            var window = globalThis;
            var messages = [];
            var scheduledTimeouts = [];
            var listeners = {};
            var currentDataVideoId = \(videoIdLiteral);
            var console = { log: function() {} };
            function setInterval() { return 0; }
            function setTimeout(callback) {
                scheduledTimeouts.push(callback);
                return scheduledTimeouts.length;
            }
            function runNextTimeout() {
                var callback = scheduledTimeouts.shift();
                if (callback) { callback(); }
            }
            var video = {
                paused: false,
                ended: false,
                currentTime: 0,
                duration: 100,
                readyState: 1,
                currentSrc: 'https://media.example/abc',
                volume: 1,
                muted: false,
                seekable: {
                    length: 1,
                    start: function() { return 0; },
                    end: function() { return 100; }
                },
                addEventListener: function(name, callback) { listeners[name] = callback; },
                play: function() {
                    this.paused = false;
                    this.ended = false;
                    if (listeners.play) { listeners.play({ currentTarget: this }); }
                    if (listeners.playing) { listeners.playing({ currentTarget: this }); }
                },
                pause: function() {
                    this.paused = true;
                    if (listeners.pause) { listeners.pause({ currentTarget: this }); }
                }
            };
            var player = {
                classList: { contains: function() { return false; } },
                getVideoData: function() {
                    return { video_id: currentDataVideoId, title: 'Title' };
                },
                unMute: function() {}
            };
            var document = {
                title: 'Title - YouTube',
                getElementById: function(id) { return id === 'movie_player' ? player : null; },
                querySelector: function(selector) {
                    if (selector === '.ytp-autonav-toggle-button') { return null; }
                    return video;
                }
            };
            window.webkit = {
                messageHandlers: {
                    youtubePlayer: {
                        postMessage: function(message) { messages.push(message); }
                    }
                }
            };
            window.__kasetDocumentGeneration = 7;
            \(pendingSeekScript)
            \(pendingSeekVideoIdScript)
            """
        )
        context.evaluateScript(YouTubeWatchWebView.observerScript)
        return context
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
