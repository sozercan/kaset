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

    @Test("utcOffsetMinutes is negative for a UTC-behind zone (matches YouTube web)")
    func utcOffsetMinutesBehindUTC() throws {
        // Fixed UTC-5 offset (DST-independent) so the assertion is stable on any
        // run date; secondsFromGMT() == -18_000 → -18_000 / 60 == -300.
        let tz = try #require(TimeZone(secondsFromGMT: -18000))
        #expect(InnerTubeSupport.utcOffsetMinutes(for: tz) == -300)
    }

    @Test("utcOffsetMinutes is positive for a UTC-ahead zone (matches YouTube web)")
    func utcOffsetMinutesAheadOfUTC() throws {
        // Fixed UTC+1 offset (DST-independent); secondsFromGMT() == 3600 → 3600 / 60 == 60.
        let tz = try #require(TimeZone(secondsFromGMT: 3600))
        #expect(InnerTubeSupport.utcOffsetMinutes(for: tz) == 60)
    }

    @Test("utcOffsetMinutes is zero for UTC")
    func utcOffsetMinutesUTC() throws {
        let tz = try #require(TimeZone(identifier: "UTC"))
        #expect(InnerTubeSupport.utcOffsetMinutes(for: tz) == 0)
    }

    @Test("utcOffsetMinutes carries the fractional half-hour sign for India")
    func utcOffsetMinutesHalfHour() throws {
        let tz = try #require(TimeZone(identifier: "Asia/Kolkata")) // IST UTC+5:30 (no DST) → +19_800s
        #expect(InnerTubeSupport.utcOffsetMinutes(for: tz) == 330)
    }

    @Test("utcOffsetMinutes pins the Los Angeles datum YouTube's web client sends")
    func utcOffsetMinutesLosAngelesReference() throws {
        // YouTube's web client sends `-Date.getTimezoneOffset()` (YouTube.js,
        // Session.ts), which equals `secondsFromGMT() / 60` in Foundation's opposite
        // sign convention. Los Angeles on daylight time is UTC-7: -25_200s → -420,
        // the datum in the review discussion. A fixed offset is used rather than the
        // named zone so DST cannot move the assertion.
        let tz = try #require(TimeZone(secondsFromGMT: -25200))
        #expect(InnerTubeSupport.utcOffsetMinutes(for: tz) == -420)
    }
}
