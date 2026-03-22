import Testing
@testable import Kaset

struct SyncedLyricsTests {
    @Test("Line statuses computation")
    func lineStatuses() {
        let lines = [
            SyncedLyricLine(timeInMs: 0, duration: 10000, text: "Wait for it...", words: nil),
            SyncedLyricLine(timeInMs: 10000, duration: 5000, text: "Line 1", words: nil),
            SyncedLyricLine(timeInMs: 15000, duration: 5000, text: "Line 2", words: nil),
        ]
        let lyrics = SyncedLyrics(lines: lines, source: "Test")

        let statuses1 = lyrics.lineStatuses(at: 5000)
        #expect(statuses1 == [.current, .upcoming, .upcoming])

        let statuses2 = lyrics.lineStatuses(at: 12000)
        #expect(statuses2 == [.previous, .current, .upcoming])

        let statuses3 = lyrics.lineStatuses(at: 16000)
        #expect(statuses3 == [.previous, .previous, .current])

        let currentIdx = lyrics.currentLineIndex(at: 12000)
        #expect(currentIdx == 1)
    }
}
