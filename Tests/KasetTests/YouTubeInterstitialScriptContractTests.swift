import Testing
@testable import Kaset

@Suite("YouTube interstitial script contracts", .tags(.service))
@MainActor
struct YouTubeInterstitialScriptContractTests {
    @Test("Reveal matches the blackout and extraction contracts")
    func interstitialRevealContract() {
        let reveal = YouTubeWatchWebView.revealInterstitialScript
        let blackout = YouTubeWatchWebView.blackoutScript
        let extraction = YouTubeWatchWebView.extractionScript

        #expect(blackout.contains("style.id = 'kaset-yt-blackout'"))
        #expect(extraction.contains("const styleId = 'kaset-yt-video-style'"))
        #expect(extraction.contains("window.__kasetStopYTExtraction = stopExtraction"))
        #expect(reveal.contains("typeof window.__kasetStopYTExtraction === 'function'"))
        #expect(reveal.contains("'kaset-yt-blackout', 'kaset-yt-video-style'"))
    }
}
