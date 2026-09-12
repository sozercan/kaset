import JavaScriptCore
import Testing
import WebKit
@testable import Kaset

// MARK: - AirPlayNavigationScriptTests

@Suite("AirPlay navigation recovery", .tags(.service))
@MainActor
struct AirPlayNavigationScriptTests {
    @Test("A confirmed AirPlay failure retries after YouTube's error handlers settle", arguments: ["150", "{ data: 150 }"])
    func confirmedFailureRetriesAfterErrorHandlersSettle(error: String) throws {
        let context = try Self.makeContext()
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("""
        video.webkitCurrentPlaybackTargetIsWireless = false;
        emitState(-1);
        advance(100);
        emitError(\(error));
        advance(249);
        """, in: context)
        #expect(Self.requests(in: context) == ["target"])

        Self.evaluate("advance(1);", in: context)
        #expect(Self.requests(in: context) == ["target", "target"])

        Self.evaluate("emitError(150); advance(2000);", in: context)
        #expect(Self.requests(in: context) == ["target", "target"])
        #expect(context.evaluateScript("errorListeners.length")?.toInt32() == 0)
    }

    @Test("An initial HTML5 error keeps the normal stalled-player settling window")
    func initialSourceErrorKeepsNormalSettlingWindow() throws {
        let context = try Self.makeContext()
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("emitState(-1); emitError(5); advance(350);", in: context)
        #expect(Self.requests(in: context) == ["target"])

        Self.evaluate("advance(650);", in: context)
        #expect(Self.requests(in: context) == ["target", "target"])
    }

    @Test("A late failure does not extend the original stalled-player wait")
    func confirmedFailureDoesNotDelayExistingRecovery() throws {
        let context = try Self.makeContext()
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("emitState(-1); advance(900); emitError(150); advance(100);", in: context)
        #expect(Self.requests(in: context) == ["target", "target"])
    }

    @Test("Resumed buffering resets the shorter error recovery window")
    func resumedBufferingClearsConfirmedFailure() throws {
        let context = try Self.makeContext()
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("""
        emitState(-1); emitError(150); advance(100);
        emitState(3); emitState(-1); advance(250);
        """, in: context)
        #expect(Self.requests(in: context) == ["target"])

        Self.evaluate("advance(750);", in: context)
        #expect(Self.requests(in: context) == ["target", "target"])
    }

    @Test("A failed source still revalidates media identity and advertisement state", arguments: [
        "video.readyState = 1;",
        "video = Object.assign({}, video);",
        "currentVideoId = 'other';",
        "api.getPresentingPlayerType = () => 2;",
    ])
    func confirmedFailureRevalidatesMedia(setup: String) throws {
        let context = try Self.makeContext()
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("emitState(-1); emitError(150); advance(100); \(setup) advance(2000);", in: context)
        #expect(Self.requests(in: context) == ["target"])
    }

    @Test("An older error callback cannot accelerate a newer navigation")
    func staleErrorDoesNotAccelerateNewNavigation() throws {
        let context = try Self.makeContext()
        Self.navigate(to: "first", generation: 1, in: context)
        Self.evaluate("""
        const oldError = errorListeners[0];
        emitState(-1); emitError(150); advance(100);
        video.webkitCurrentPlaybackTargetIsWireless = false;
        window.__kasetNativePlaybackGeneration += 1;
        """, in: context)
        Self.navigate(to: "second", generation: 2, in: context)
        Self.evaluate("emitState(-1); oldError(150); advance(250);", in: context)
        #expect(Self.requests(in: context) == ["first", "second"])

        Self.evaluate("advance(750);", in: context)
        #expect(Self.requests(in: context) == ["first", "second", "second"])
    }

    @Test("An unstarted AirPlay target is retried once inside the existing document")
    func retriesUnstartedTarget() throws {
        let context = try Self.makeContext()
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("""
        video.webkitCurrentPlaybackTargetIsWireless = false;
        emitState({ data: -1 });
        emitState(-1);
        advance(1000);
        emitState(-1);
        advance(1000);
        """, in: context)

        #expect(Self.requests(in: context) == ["target", "target"])
        #expect(context.evaluateScript("stateListeners.length")?.toInt32() == 0)
        #expect(context.evaluateScript("video === originalVideo")?.toBool() == true)
    }

    @Test("Local playback and unavailable player APIs keep normal router behavior", arguments: [
        "video.webkitCurrentPlaybackTargetIsWireless = false;",
        "api.getVideoData = null;",
        "api.getPlayerState = null;",
        "api.addEventListener = null;",
        "api.removeEventListener = null;",
    ])
    func normalNavigationDoesNotInstallRetry(setup: String) throws {
        let context = try Self.makeContext(setup: setup)
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("emitState(-1); advance(1000);", in: context)

        #expect(Self.requests(in: context) == ["target"])
        #expect(context.evaluateScript("stateListeners.length")?.toInt32() == 0)
    }

    @Test("Buffering, paused, playing, and loaded media cancel the stalled-state retry", arguments: [
        "emitState(3);", "emitState(2);", "emitState(1);", "video.readyState = 1;",
    ])
    func resumedLoadingDoesNotRetry(setup: String) throws {
        let context = try Self.makeContext()
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("emitState(-1); \(setup) advance(1000);", in: context)

        #expect(Self.requests(in: context) == ["target"])
    }

    @Test("A later stall gets its own settling window after buffering resumes")
    func resumedBufferingResetsSettlingWindow() throws {
        let context = try Self.makeContext()
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("""
        emitState(-1);
        advance(800);
        emitState(3);
        emitState(-1);
        advance(200);
        """, in: context)
        #expect(Self.requests(in: context) == ["target"])

        Self.evaluate("advance(800);", in: context)
        #expect(Self.requests(in: context) == ["target", "target"])
    }

    @Test("An unstarted outgoing track does not retry the incoming track")
    func outgoingUnstartedStateDoesNotRetry() throws {
        let context = try Self.makeContext()
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("""
        currentVideoId = 'source';
        emitState(-1);
        advance(2000);
        """, in: context)

        #expect(Self.requests(in: context) == ["target"])
    }

    @Test("Track identity and media readiness may settle after the unstarted event", arguments: [
        ("currentVideoId = 'source';", "currentVideoId = 'target';"),
        ("video.readyState = 4;", "video.readyState = 0;"),
    ])
    func delayedTargetStateRecovers(setup: String, settle: String) throws {
        let context = try Self.makeContext()
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("\(setup) emitState(-1); advance(1000);", in: context)
        #expect(Self.requests(in: context) == ["target"])

        Self.evaluate("\(settle) advance(1250);", in: context)
        #expect(Self.requests(in: context) == ["target", "target"])
    }

    @Test("A persistent unstarted target is recovered without a state callback")
    func missingStateCallbackStillRecovers() throws {
        let context = try Self.makeContext()
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("playerState = -1; advance(1250);", in: context)

        #expect(Self.requests(in: context) == ["target", "target"])
    }

    @Test("Loaded media resets the settling window without a player state callback")
    func mediaReadinessResetsSettlingWindow() throws {
        let context = try Self.makeContext()
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("""
        emitState(-1);
        advance(750);
        video.readyState = 1;
        advance(250);
        video.readyState = 0;
        advance(1000);
        """, in: context)
        #expect(Self.requests(in: context) == ["target"])

        Self.evaluate("advance(250);", in: context)
        #expect(Self.requests(in: context) == ["target", "target"])
    }

    @Test("A rapid skip inherits the pending AirPlay handoff and invalidates older retries", arguments: [false, true])
    func newerNavigationOwnsRetry(firstRetryRan: Bool) throws {
        let context = try Self.makeContext()
        Self.navigate(to: "first", generation: 1, in: context)
        Self.evaluate("""
        emitState(-1);
        const staleTimer = Array.from(timers.values())[0].callback;
        """, in: context)
        if firstRetryRan {
            Self.evaluate("advance(1000);", in: context)
        }
        Self.evaluate("""
        video.webkitCurrentPlaybackTargetIsWireless = false;
        window.__kasetNativePlaybackGeneration += 1;
        """, in: context)
        Self.navigate(to: "second", generation: 2, in: context)
        Self.evaluate("staleTimer(); emitState(-1); advance(1000);", in: context)

        let expected = firstRetryRan
            ? ["first", "first", "second", "second"]
            : ["first", "second", "second"]
        #expect(Self.requests(in: context) == expected)
    }

    @Test("A new playback occurrence invalidates a retry even for the same track")
    func playbackOccurrenceChangeInvalidatesRetry() throws {
        let context = try Self.makeContext()
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("""
        emitState(-1);
        window.__kasetNativePlaybackGeneration += 1;
        advance(1000);
        """, in: context)

        #expect(Self.requests(in: context) == ["target"])
        #expect(context.evaluateScript("timers.size")?.toInt32() == 0)
        #expect(context.evaluateScript("window.__kasetAirPlayNavigationRetry === null")?.toBool() == true)
    }

    @Test("Media confirmation cancels pending recovery")
    func confirmationCancelsRetry() throws {
        let context = try Self.makeContext()
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("emitState(-1); emitError(150);", in: context)
        Self.evaluate(SingletonPlayerWebView.routerNavigationRetryCancellationScript(generation: 1), in: context)
        Self.evaluate("advance(1000);", in: context)

        #expect(Self.requests(in: context) == ["target"])
        #expect(context.evaluateScript("stateListeners.length")?.toInt32() == 0)
        #expect(context.evaluateScript("errorListeners.length")?.toInt32() == 0)
        #expect(context.evaluateScript("timers.size")?.toInt32() == 0)
        #expect(context.evaluateScript("window.__kasetAirPlayNavigationRetry === null")?.toBool() == true)
    }

    @Test("A confirmed handoff cannot grant AirPlay recovery to later local playback")
    func confirmationReleasesAirPlayHandoff() throws {
        let context = try Self.makeContext()
        Self.navigate(to: "first", generation: 1, in: context)
        Self.evaluate("emitState(-1); advance(1000);", in: context)
        Self.evaluate(SingletonPlayerWebView.routerNavigationRetryCancellationScript(generation: 1), in: context)
        Self.evaluate("video.webkitCurrentPlaybackTargetIsWireless = false;", in: context)
        Self.navigate(to: "second", generation: 2, in: context)
        Self.evaluate("emitState(-1); advance(1000);", in: context)

        #expect(Self.requests(in: context) == ["first", "first", "second"])
    }

    @Test("An older confirmation cannot cancel the current retry")
    func olderConfirmationDoesNotCancelNewerRetry() throws {
        let context = try Self.makeContext()
        Self.navigate(to: "first", generation: 1, in: context)
        Self.navigate(to: "second", generation: 2, in: context)
        Self.evaluate("emitState(-1);", in: context)
        Self.evaluate(SingletonPlayerWebView.routerNavigationRetryCancellationScript(generation: 1), in: context)
        Self.evaluate("advance(1000);", in: context)

        #expect(Self.requests(in: context) == ["first", "second", "second"])
    }

    @Test("The delayed retry revalidates the current media and readable player state", arguments: [
        "video.readyState = 1;",
        "video = Object.assign({}, video);",
        "currentVideoId = 'other';",
        "api.getVideoData = () => { throw new Error('replaced'); };",
        "api.getPlayerState = () => { throw new Error('replaced'); };",
    ])
    func delayedRetryRevalidatesMedia(setup: String) throws {
        let context = try Self.makeContext()
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("emitState(-1); \(setup) advance(1000);", in: context)

        #expect(Self.requests(in: context) == ["target"])
    }

    @Test("Advertisement playback is not restarted by AirPlay recovery", arguments: [false, true])
    func advertisementsDoNotRetry(adStartsDuringDelay: Bool) throws {
        let context = try Self.makeContext()
        Self.navigate(to: "target", generation: 1, in: context)
        if adStartsDuringDelay {
            Self.evaluate("emitState(-1);", in: context)
        }
        Self.evaluate("""
        api.getPresentingPlayerType = () => 2;
        emitState(-1);
        advance(1000);
        """, in: context)

        #expect(Self.requests(in: context) == ["target"])
    }

    @Test("Leaving the page cancels the listener and pending retry")
    func pageHideCancelsRetry() throws {
        let context = try Self.makeContext()
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("emitState(-1); emitError(150); hidePage(); advance(1000);", in: context)

        #expect(Self.requests(in: context) == ["target"])
        #expect(context.evaluateScript("stateListeners.length")?.toInt32() == 0)
        #expect(context.evaluateScript("errorListeners.length")?.toInt32() == 0)
        #expect(context.evaluateScript("timers.size")?.toInt32() == 0)
    }

    @Test("Stopping or suppressing a document cancels a pending AirPlay retry", arguments: [false, true], [false, true])
    func documentSuppressionCancelsPendingRetry(explicitStop: Bool, confirmedFailure: Bool) async throws {
        let context = try Self.makeContext(setup: """
        video.paused = true;
        video.pause = () => { video.paused = true; };
        document.addEventListener = () => {};
        document.querySelectorAll = () => [video];
        """)
        let webView = AirPlayRetryTestWebView(context: context)
        let singleton = SingletonPlayerWebView.makeTestInstance(webView: webView)
        defer { singleton.tearDown() }
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("emitState(-1); const staleError = errorListeners[0];", in: context)
        if confirmedFailure {
            Self.evaluate("emitError(150);", in: context)
        }
        Self.evaluate("advance(100); const staleTimer = Array.from(timers.values())[0].callback;", in: context)

        if explicitStop {
            await singleton.cancelPendingPlayback()
        } else {
            singleton.suppressSurvivingDocumentMedia(webView)
        }
        Self.evaluate("staleTimer(); staleError(150); advance(2000);", in: context)

        #expect(Self.requests(in: context) == ["target"])
        #expect(context.evaluateScript("window.__kasetAirPlayNavigationRetry === null")?.toBool() == true)
        #expect(context.evaluateScript("stateListeners.length + errorListeners.length + pageHideListeners.length")?.toInt32() == 0)
        #expect(context.evaluateScript("timers.size")?.toInt32() == 0)
        #expect(context.evaluateScript("window.__kasetPlaybackSuppressed && !window.__kasetAutoplayPending")?.toBool() == true)
    }

    @Test("Recovery preserves autoplay suppression received during the handoff")
    func retryKeepsCurrentAutoplaySuppression() throws {
        let context = try Self.makeContext()
        Self.navigate(to: "target", generation: 1, in: context)
        Self.evaluate("""
        emitState(-1);
        window.__kasetAutoplayPending = false;
        window.__kasetBlockAutoplay = true;
        window.__kasetPlaybackSuppressed = true;
        advance(1000);
        """, in: context)

        #expect(Self.requests(in: context) == ["target", "target"])
        #expect(context.evaluateScript("window.__kasetAutoplayPending")?.toBool() == false)
        #expect(context.evaluateScript("window.__kasetBlockAutoplay && window.__kasetPlaybackSuppressed")?.toBool() == true)
    }

    @Test("Rejected router commands clean up and retain full-page fallback eligibility")
    func rejectedNavigationCleansUp() throws {
        let context = try Self.makeContext(setup: "app.resolveCommand = () => { throw new Error('unavailable'); };")
        let result = context.evaluateScript(SingletonPlayerWebView.routerNavigationScript(videoId: "target", generation: 1))

        #expect(result?.toBool() == false)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("stateListeners.length")?.toInt32() == 0)
        #expect(context.evaluateScript("window.__kasetAirPlayNavigationRetry === null")?.toBool() == true)
    }

    private static func makeContext(setup: String = "") throws -> JSContext {
        let context = try #require(JSContext())
        Self.evaluate("""
        var window = globalThis;
        window.__kasetNativePlaybackGeneration = 1;
        var currentVideoId = 'source';
        var playerState = 1;
        var video = { readyState: 4, webkitCurrentPlaybackTargetIsWireless: true };
        var originalVideo = video;
        var requests = [];
        var stateListeners = [];
        var errorListeners = [];
        var pageHideListeners = [];
        var timers = new Map();
        var nextTimer = 0;
        var now = 0;
        var performance = { now: () => now };
        var api = {
            getVideoData: () => ({ video_id: currentVideoId }),
            getPlayerState: () => playerState,
            addEventListener: (event, handler) => {
                if (event === 'onStateChange') stateListeners.push(handler);
                if (event === 'onError') errorListeners.push(handler);
            },
            removeEventListener: (event, handler) => {
                if (event === 'onStateChange') stateListeners = stateListeners.filter(value => value !== handler);
                if (event === 'onError') errorListeners = errorListeners.filter(value => value !== handler);
            }
        };
        var app = {
            resolveCommand: command => {
                currentVideoId = command.watchEndpoint.videoId;
                requests.push(currentVideoId);
                video.readyState = 0;
                playerState = 3;
            }
        };
        var document = {
            querySelector: selector => {
                if (selector === 'ytmusic-app') return app;
                if (selector === 'video') return video;
                return null;
            },
            getElementById: id => id === 'movie_player' ? api : null
        };
        window.addEventListener = (event, handler) => {
            if (event === 'pagehide') pageHideListeners.push(handler);
        };
        window.removeEventListener = (event, handler) => {
            if (event === 'pagehide') pageHideListeners = pageHideListeners.filter(value => value !== handler);
        };
        function setTimeout(callback, delay) {
            const id = ++nextTimer;
            timers.set(id, { at: now + delay, callback: callback });
            return id;
        }
        function clearTimeout(id) { timers.delete(id); }
        function advance(milliseconds) {
            const deadline = now + milliseconds;
            while (timers.size) {
                const [id, timer] = Array.from(timers).sort((a, b) => a[1].at - b[1].at)[0];
                if (timer.at > deadline) break;
                timers.delete(id);
                now = timer.at;
                timer.callback();
            }
            now = deadline;
        }
        function emitState(event) {
            playerState = typeof event === 'number' ? event : event.data;
            stateListeners.slice().forEach(handler => handler(event));
        }
        function emitError(event) { errorListeners.slice().forEach(handler => handler(event)); }
        function hidePage() { pageHideListeners.slice().forEach(handler => handler()); }
        \(setup)
        """, in: context)
        return context
    }

    private static func navigate(to videoId: String, generation: Int, in context: JSContext) {
        self.evaluate(SingletonPlayerWebView.routerNavigationScript(videoId: videoId, generation: generation), in: context)
    }

    private static func evaluate(_ script: String, in context: JSContext) {
        context.evaluateScript(script)
        #expect(context.exception == nil)
    }

    private static func requests(in context: JSContext) -> [String] {
        context.evaluateScript("requests")?.toArray() as? [String] ?? []
    }
}

// MARK: - AirPlayRetryTestWebView

@MainActor
private final class AirPlayRetryTestWebView: WKWebView {
    private let context: JSContext

    init(context: JSContext) {
        self.context = context
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        super.init(frame: .zero, configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func evaluateJavaScript(
        _ javaScriptString: String,
        completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil
    ) {
        let result = self.context.evaluateScript(javaScriptString)
        #expect(self.context.exception == nil)
        completionHandler?(result?.toObject(), nil)
    }
}
