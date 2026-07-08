import Foundation
import Testing
@testable import Kaset

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
}
