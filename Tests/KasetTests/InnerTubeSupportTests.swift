import Foundation
import Testing
@testable import Kaset

/// Tests for shared InnerTube helpers — especially SAPISIDHASH origin
/// sensitivity, where a wrong origin produces silent 401s.
@Suite("InnerTubeSupport", .tags(.api))
struct InnerTubeSupportTests {
    @Test("SAPISIDHASH matches known vector for the YouTube origin")
    func sapisidHashYouTubeOrigin() {
        let hash = InnerTubeSupport.sapisidHash(
            sapisid: "test-sapisid",
            origin: "https://www.youtube.com",
            timestamp: 1_700_000_000
        )
        #expect(hash == "1700000000_14963cac63f39c9532ddd26bf69ca8d5e4d8aab6")
    }

    @Test("SAPISIDHASH matches known vector for the music origin")
    func sapisidHashMusicOrigin() {
        let hash = InnerTubeSupport.sapisidHash(
            sapisid: "test-sapisid",
            origin: "https://music.youtube.com",
            timestamp: 1_700_000_000
        )
        #expect(hash == "1700000000_17d748c166afd876ceb872a291e5befdca771528")
    }

    @Test("Different origins produce different hashes for the same SAPISID")
    func originChangesHash() {
        let youtube = InnerTubeSupport.sapisidHash(
            sapisid: "abc",
            origin: "https://www.youtube.com",
            timestamp: 1_700_000_000
        )
        let music = InnerTubeSupport.sapisidHash(
            sapisid: "abc",
            origin: "https://music.youtube.com",
            timestamp: 1_700_000_000
        )
        #expect(youtube != music)
    }

    @Test("Timestamp is embedded as the hash prefix")
    func timestampPrefix() {
        let hash = InnerTubeSupport.sapisidHash(
            sapisid: "abc",
            origin: "https://www.youtube.com",
            timestamp: 42
        )
        #expect(hash.hasPrefix("42_"))
    }
}
