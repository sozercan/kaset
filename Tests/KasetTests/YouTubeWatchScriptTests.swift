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

    @Test("Bootstrap script clamps the volume target")
    func bootstrapClampsVolume() {
        #expect(YouTubeWatchWebView.pageBootstrapScript(targetVolume: 2.0)
            .contains("__kasetTargetVolume = 1.0"))
        #expect(YouTubeWatchWebView.pageBootstrapScript(targetVolume: -1)
            .contains("__kasetTargetVolume = 0.0"))
    }

    @Test("Bootstrap carries a pending resume-seek only when present and positive")
    func bootstrapCarriesPendingSeek() {
        #expect(YouTubeWatchWebView.pageBootstrapScript(targetVolume: 1, pendingSeek: 42.5)
            .contains("__kasetPendingSeek = 42.5"))
        // No seek pending → no marker injected.
        #expect(!YouTubeWatchWebView.pageBootstrapScript(targetVolume: 1, pendingSeek: nil)
            .contains("__kasetPendingSeek"))
        // Zero/negative is not a resume position.
        #expect(!YouTubeWatchWebView.pageBootstrapScript(targetVolume: 1, pendingSeek: 0)
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
}
