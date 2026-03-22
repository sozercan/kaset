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
}
