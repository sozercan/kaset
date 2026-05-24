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
        #expect(ctx.evaluateScript("window.__kasetAutoplayPending").toBool() == false)
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
        #expect(ctx.evaluateScript("window.__kasetAutoplayPending").toBool() == false)
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
        #expect(ctx.evaluateScript("window.__kasetAutoplayPending").toBool() == false)
    }

    @Test("Observer script embeds the recovery function")
    func observerScriptEmbedsRecoveryFunction() {
        #expect(SingletonPlayerWebView.observerScript.contains("__kasetAttemptAutoplayRecovery"))
    }

    @Test("Observer script clears autoplay intent on successful playback")
    func observerScriptClearsAutoplayIntentOnPlayback() {
        #expect(SingletonPlayerWebView.observerScript.contains("window.__kasetAutoplayPending = false;"))
    }

    @Test("Observer script retries recovery when media is already ready")
    func observerScriptRetriesRecoveryWhenMediaAlreadyReady() {
        #expect(SingletonPlayerWebView.observerScript.contains("video.readyState >= 3"))
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

    @Test("Page bootstrap seeds autoplay intent and target volume")
    func pageBootstrapSeedsIntentAndTargetVolume() {
        let script = SingletonPlayerWebView.pageBootstrapScript(
            isRestoringPlaybackSession: false,
            targetVolume: 0.42
        )

        #expect(script.contains("window.__kasetAutoplayPending = true;"))
        #expect(script.contains("window.__kasetTargetVolume = 0.42;"))
    }

    @Test("Page bootstrap clamps invalid target volume")
    func pageBootstrapClampsInvalidTargetVolume() {
        let script = SingletonPlayerWebView.pageBootstrapScript(
            isRestoringPlaybackSession: false,
            targetVolume: .infinity
        )

        #expect(script.contains("window.__kasetTargetVolume = 1.0;"))
    }
}
