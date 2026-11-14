import Foundation
import Testing
@testable import Kaset

// MARK: - BetterLyricsProviderTests

@Suite(.tags(.model))
struct BetterLyricsProviderTests {
    private static func entry(
        lyrics: String,
        format: String? = "lrc",
        videoId: String = "video-id"
    ) -> BetterLyricsEntry {
        BetterLyricsEntry(
            id: 1,
            videoId: videoId,
            song: "Song",
            artist: "Artist",
            lyrics: lyrics,
            format: format,
            language: "en",
            syncType: "linesync",
            score: 5,
            effectiveScore: 4.2,
            voteCount: 12,
            confidence: "high"
        )
    }

    @Test("LRC lyrics convert to synced result")
    func lrcConvertsToSynced() {
        let result = BetterLyricsProvider.lyricResult(from: Self.entry(
            lyrics: "[00:00.20]First line\n[00:05.00]Second line"
        ))

        guard case let .synced(lyrics) = result else {
            Issue.record("Expected a synced result, got \(result)")
            return
        }
        #expect(lyrics.source == "BetterLyrics")
        #expect(lyrics.lines.count == 2)
        #expect(lyrics.lines[0].text == "First line")
        #expect(lyrics.lines[0].timeInMs == 200)
        #expect(lyrics.lines[1].text == "Second line")
        #expect(lyrics.lines[1].timeInMs == 5000)
    }

    @Test("Plain lyrics convert to plain result")
    func plainConvertsToPlain() {
        let result = BetterLyricsProvider.lyricResult(from: Self.entry(
            lyrics: "Just some plain\nlyrics text",
            format: "plain"
        ))

        guard case let .plain(lyrics) = result else {
            Issue.record("Expected a plain result, got \(result)")
            return
        }
        #expect(lyrics.text == "Just some plain\nlyrics text")
        #expect(lyrics.source == "Source: BetterLyrics")
    }

    @Test("TTML lyrics convert to plain result with tags stripped")
    func ttmlConvertsToPlain() {
        let result = BetterLyricsProvider.lyricResult(from: Self.entry(
            lyrics: "<tt><body><p>Line one</p><p>Line two</p></body></tt>",
            format: "ttml"
        ))

        guard case let .plain(lyrics) = result else {
            Issue.record("Expected a plain result, got \(result)")
            return
        }
        #expect(lyrics.text == "Line one\nLine two")
    }

    @Test("Empty lyrics convert to unavailable")
    func emptyLyricsAreUnavailable() {
        let result = BetterLyricsProvider.lyricResult(from: Self.entry(lyrics: ""))
        #expect(result == .unavailable)
    }

    @Test("LRC timestamp stripping leaves clean text")
    func stripLRTimestamps() {
        let cleaned = BetterLyricsProvider.stripLRTimestamps(
            "[00:00.20]First line\n[ar:Artist]\n[00:05.00]Second line"
        )
        #expect(cleaned == "First line\nSecond line")
    }

    @Test("TTML tag stripping preserves line boundaries and decodes entities")
    func stripTTMLTags() {
        let encoded = "<p>Hello \u{26}amp; goodbye</p><p>World</p>"
        let cleaned = BetterLyricsProvider.stripTTMLTags(encoded)
        #expect(cleaned == "Hello & goodbye\nWorld")
    }

    @Test("Unparsable LRC degrades to plain text")
    func unparsableLrcDegradesToPlain() {
        // No valid timestamp lines -> LRCParser returns nil -> degrade to plain.
        let result = BetterLyricsProvider.lyricResult(from: Self.entry(
            lyrics: "Just plain words here",
            format: "lrc"
        ))

        guard case let .plain(lyrics) = result else {
            Issue.record("Expected a plain result, got \(result)")
            return
        }
        #expect(lyrics.text == "Just plain words here")
    }
}
