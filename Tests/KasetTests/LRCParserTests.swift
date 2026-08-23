import Testing
@testable import Kaset

struct LRCParserTests {
    @Test("Parse basic LRC")
    func parseBasicLRC() throws {
        let lrc = """
        [00:12.00]Line 1
        [00:15.30]Line 2
        """

        let synced = try #require(LRCParser.parse(lrc))

        #expect(synced.lines.count == 3) // 0ms + 2 lines
        #expect(synced.lines[0].timeInMs == 0) // Auto-inserted
        #expect(synced.lines[0].duration == 12000)

        #expect(synced.lines[1].timeInMs == 12000)
        #expect(synced.lines[1].duration == 3300)
        #expect(synced.lines[1].text == "Line 1")

        #expect(synced.lines[2].timeInMs == 15300)
        #expect(synced.lines[2].duration == 5000)
        #expect(synced.lines[2].text == "Line 2")
    }

    @Test("Parse offset and multiple timestamps")
    func parseAdvancedLRC() throws {
        let lrc = """
        [offset:500]
        [00:10.00][00:20.00]Chorus
        """

        let synced = try #require(LRCParser.parse(lrc))

        #expect(synced.lines.count == 3)
        // Offset 500ms means 10.00 becomes 9.50 (9500)
        // 0 line inserted (first line > 300ms)
        #expect(synced.lines[0].timeInMs == 0)
        #expect(synced.lines[1].timeInMs == 9500)
        #expect(synced.lines[2].timeInMs == 19500)
    }

    @Test("Parse word-level timing")
    func parseWordLevelTiming() throws {
        let lrc = "[00:00.12]<00:00.12>Hello <00:00.45>world"

        let synced = try #require(LRCParser.parse(lrc))
        let line = try #require(synced.lines.first)

        #expect(line.timeInMs == 120)
        #expect(line.text == "Hello world")
        #expect(line.words == [
            TimedWord(timeInMs: 120, word: "Hello "),
            TimedWord(timeInMs: 450, word: "world"),
        ])
    }

    @Test("Parse three digit milliseconds")
    func parseThreeDigitMilliseconds() throws {
        let synced = try #require(LRCParser.parse("[00:01.234]Line"))

        #expect(synced.lines.first?.timeInMs == 0)
        #expect(synced.lines.dropFirst().first?.timeInMs == 1234)
    }

    @Test("Offset clamps negative timestamps to zero")
    func offsetClampsNegativeTimestamp() throws {
        let synced = try #require(LRCParser.parse("[offset:500]\n[00:00.10]Early"))

        #expect(synced.lines.first?.timeInMs == 0)
        #expect(synced.lines.first?.text == "Early")
    }

    @Test("Pure metadata only returns nil")
    func pureMetadataOnlyReturnsNil() {
        #expect(LRCParser.parse("[ar:Artist]\n[ti:Title]") == nil)
    }

    @Test("First line blank insertion threshold")
    func firstLineBlankInsertionThreshold() throws {
        let noBlank = try #require(LRCParser.parse("[00:00.30]No blank"))
        let blank = try #require(LRCParser.parse("[00:00.31]Blank"))

        #expect(noBlank.lines.count == 1)
        #expect(noBlank.lines.first?.text == "No blank")
        #expect(blank.lines.count == 2)
        #expect(blank.lines.first?.text.isEmpty == true)
        #expect(blank.lines.last?.text == "Blank")
    }
}
