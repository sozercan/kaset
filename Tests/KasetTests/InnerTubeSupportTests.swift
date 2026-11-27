import Foundation
import Testing
@testable import Kaset

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
        let tz = try #require(TimeZone(secondsFromGMT: -18000))
        #expect(InnerTubeSupport.utcOffsetMinutes(for: tz) == -300)
    }

    @Test("utcOffsetMinutes is positive for a UTC-ahead zone (matches YouTube web)")
    func utcOffsetMinutesAheadOfUTC() throws {
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
        let tz = try #require(TimeZone(identifier: "Asia/Kolkata"))
        #expect(InnerTubeSupport.utcOffsetMinutes(for: tz) == 330)
    }

    @Test("utcOffsetMinutes pins the Los Angeles datum YouTube's web client sends")
    func utcOffsetMinutesLosAngelesReference() throws {
        let tz = try #require(TimeZone(secondsFromGMT: -25200))
        #expect(InnerTubeSupport.utcOffsetMinutes(for: tz) == -420)
    }
}
