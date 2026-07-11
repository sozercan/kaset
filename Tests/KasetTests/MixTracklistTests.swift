import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.model))
struct MixTracklistTests {
    // MARK: - Artist/Title Parsing

    @Test("Chapter title splits into artist and title on the first ' - '")
    func parsesArtistAndTitle() {
        let parsed = MixTrackEntry.parseArtistTitle(from: "Deepbass - Canna (Luigi Tozzi rmx)")
        #expect(parsed.artist == "Deepbass")
        #expect(parsed.title == "Canna (Luigi Tozzi rmx)")
    }

    @Test("Only the first ' - ' separates artist from title")
    func splitsOnFirstDashOnly() {
        let parsed = MixTrackEntry.parseArtistTitle(from: "Octo Aeterna - Opath - Reprise")
        #expect(parsed.artist == "Octo Aeterna")
        #expect(parsed.title == "Opath - Reprise")
    }

    @Test("A spaced separator wins over an earlier dash inside the artist")
    func spacedSeparatorHasPriority() {
        let parsed = MixTrackEntry.parseArtistTitle(from: "A–B - Song")
        #expect(parsed.artist == "A–B")
        #expect(parsed.title == "Song")
    }

    @Test("Title without a dash yields nil artist and the whole string as title")
    func noDashLeavesArtistNil() {
        let parsed = MixTrackEntry.parseArtistTitle(from: "Untitled Jam")
        #expect(parsed.artist == nil)
        #expect(parsed.title == "Untitled Jam")
    }

    @Test("Surrounding whitespace is trimmed from both parts")
    func trimsWhitespace() {
        let parsed = MixTrackEntry.parseArtistTitle(from: "  Skoll  -  Defenestration  ")
        #expect(parsed.artist == "Skoll")
        #expect(parsed.title == "Defenestration")
    }

    @Test("Common Unicode dash separators are recognized with or without spaces", arguments: [
        "Artist – Title",
        "Artist—Title",
        "Artist−Title",
    ])
    func parsesCommonDashSeparators(raw: String) {
        let parsed = MixTrackEntry.parseArtistTitle(from: raw)
        #expect(parsed.artist == "Artist")
        #expect(parsed.title == "Title")
    }

    @Test("An unspaced ASCII hyphen remains ambiguous rather than inventing an artist")
    func unspacedASCIIHyphenIsNotASeparator() {
        let parsed = MixTrackEntry.parseArtistTitle(from: "Part-1")
        #expect(parsed.artist == nil)
        #expect(parsed.title == "Part-1")
    }

    @Test("Empty artist side falls back to nil")
    func emptyArtistFallsBackToNil() {
        let parsed = MixTrackEntry.parseArtistTitle(from: " - Just A Title")
        #expect(parsed.artist == nil)
        #expect(parsed.title == "Just A Title")
    }

    @Test("Chapter-title initializer uses the shared parser")
    func chapterInitParsesArtistTitle() {
        let entry = MixTrackEntry(fromChapterTitle: "Einox - Monk", startTime: 100, endTime: 200)
        #expect(entry.artist == "Einox")
        #expect(entry.title == "Monk")
        #expect(entry.source == .chapters)
        #expect(entry.duration == 100)
    }

    @MainActor
    @Test("Chapter parser preserves the final chapter's explicit end time")
    func finalChapterEndTime() async {
        let chapters = [
            YouTubeChapter(videoId: "mix", title: "A - One", startTime: 0, endTime: 100, timeText: nil, thumbnailURL: nil),
            YouTubeChapter(videoId: "mix", title: "B - Two", startTime: 100, endTime: 200, timeText: nil, thumbnailURL: nil),
            YouTubeChapter(videoId: "mix", title: "C - Three", startTime: 200, endTime: 290, timeText: nil, thumbnailURL: nil),
        ]
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Mix",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            chapters: chapters
        )

        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube).parseTracklist(videoId: "mix")

        #expect(tracklist?.entries.last?.endTime == 290)
        #expect(tracklist?.entries.last?.duration == 90)
    }

    @MainActor
    @Test("Chapter parser caches non-mix results until invalidated")
    func cachesNoTracklistResult() async {
        let chapters = ["Setup", "Demo", "Questions"].enumerated().map { index, title in
            YouTubeChapter(
                videoId: "regular",
                title: title,
                startTime: TimeInterval(index) * 60,
                endTime: TimeInterval(index + 1) * 60,
                timeText: nil,
                thumbnailURL: nil
            )
        }
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Regular Video",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            chapters: chapters
        )
        let parser = MixTracklistParser(youTubeClient: mockYouTube)

        let first = await parser.parseTracklist(videoId: "regular")
        let second = await parser.parseTracklist(videoId: "regular")
        #expect(first == nil)
        #expect(second == nil)
        #expect(mockYouTube.getWatchNextCallCount == 1)

        parser.invalidate(videoId: "regular")
        _ = await parser.parseTracklist(videoId: "regular")
        #expect(mockYouTube.getWatchNextCallCount == 2)

        parser.invalidateAll()
        _ = await parser.parseTracklist(videoId: "regular")
        #expect(mockYouTube.getWatchNextCallCount == 3)
    }

    @MainActor
    @Test("Chapter parser does not cache transient request failures")
    func transientFailureRemainsRetryable() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.error = URLError(.timedOut)
        let parser = MixTracklistParser(youTubeClient: mockYouTube)

        let first = await parser.parseTracklist(videoId: "mix")
        #expect(first == nil)

        mockYouTube.error = nil
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Mix",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            chapters: [
                YouTubeChapter(videoId: "mix", title: "A - One", startTime: 0, endTime: 60, timeText: nil, thumbnailURL: nil),
                YouTubeChapter(videoId: "mix", title: "B - Two", startTime: 60, endTime: 120, timeText: nil, thumbnailURL: nil),
                YouTubeChapter(videoId: "mix", title: "C - Three", startTime: 120, endTime: 180, timeText: nil, thumbnailURL: nil),
            ]
        )

        let retried = await parser.parseTracklist(videoId: "mix")
        #expect(retried?.entries.count == 3)
        #expect(mockYouTube.getWatchNextCallCount == 2)
    }

    // MARK: - Description Timestamp Parsing

    @MainActor
    @Test("Description tracklist lines parse into chained entries")
    func descriptionEntriesParseTracklist() {
        let description = """
        Enjoy the vibes everyone!

        Tracklist:
        00:00 511Lazuli - Doors
        01:10 ALISON - Subtract
        06:15 Decisive Koala - Release

        A mix of the best chillwave.
        """
        let entries = MixTracklistParser.descriptionEntries(from: description)

        #expect(entries.count == 3)
        #expect(entries[0].artist == "511Lazuli")
        #expect(entries[0].title == "Doors")
        #expect(entries[0].startTime == 0)
        #expect(entries[0].endTime == 70)
        #expect(entries[1].endTime == 375)
        #expect(entries[2].startTime == 375)
        #expect(entries[2].endTime == nil)
        #expect(entries.allSatisfy { $0.source == .description })
    }

    @MainActor
    @Test("Description timestamp formats are recognized", arguments: [
        "0:00 A - One\n1:02:03 B - Two\n2:00:00 C - Three",
        "A - One 0:00\nB - Two 1:02:03\nC - Three 2:00:00",
        "[0:00] A - One\n[1:02:03] B - Two\n[2:00:00] C - Three",
        "(0:00) A - One\n(1:02:03) B - Two\n(2:00:00) C - Three",
        "1. A - One 0:00\n2. B - Two 1:02:03\n3. C - Three 2:00:00",
    ])
    func descriptionEntriesRecognizeCommonFormats(description: String) {
        let entries = MixTracklistParser.descriptionEntries(from: description)

        #expect(entries.map(\.startTime) == [0, 3723, 7200])
        #expect(entries.map(\.artist) == ["A", "B", "C"])
        #expect(entries.map(\.title) == ["One", "Two", "Three"])
    }

    @MainActor
    @Test("Stray timestamps outside the monotonic tracklist run are ignored")
    func descriptionEntriesKeepLongestMonotonicRun() {
        let description = """
        Premiere started at 12:00 sharp!
        00:00 A - One
        03:20 B - Two
        07:45 C - Three
        10:00 D - Four
        Rebroadcast at 9:30 next week.
        """
        let entries = MixTracklistParser.descriptionEntries(from: description)

        #expect(entries.map(\.title) == ["One", "Two", "Three", "Four"])
        #expect(entries.first?.startTime == 0)
    }

    @MainActor
    @Test("Clock times glued to letters are not tracklist timestamps")
    func descriptionEntriesRejectClockTimes() {
        let entries = MixTracklistParser.descriptionEntries(from: "Premiere at 3:45pm")
        #expect(entries.isEmpty)
    }

    @MainActor
    @Test("An invalid H:MM:SS timestamp does not hide a later valid one on the same line")
    func descriptionEntriesSkipInvalidTimestampWithinLine() {
        let description = """
        1:75:00 typo then 0:00 A - One
        1:00 B - Two
        2:00 C - Three
        """
        let entries = MixTracklistParser.descriptionEntries(from: description)

        #expect(entries.count == 3)
        #expect(entries.first?.startTime == 0)
        #expect(entries.first?.artist == "A")
        #expect(entries.first?.title == "One")
    }

    @MainActor
    @Test("Timestamps scattered across prose sections do not stitch into a tracklist")
    func descriptionEntriesRequireContiguousLines() {
        let description = """
        Show starts 0:30 - doors open early
        Thanks to everyone who joined the premiere chat.
        Highlight at 5:00 - special guest appearance
        Full VOD stays up all week for members.
        Ends around 10:00 - afterparty on discord
        """
        let entries = MixTracklistParser.descriptionEntries(from: description)

        #expect(entries.count == 1)
    }

    @MainActor
    @Test("Blank lines between tracklist entries do not break the block")
    func descriptionEntriesAllowBlankLinesWithinTracklist() {
        let description = """
        00:00 A - One

        01:00 B - Two

        02:00 C - Three
        """
        let entries = MixTracklistParser.descriptionEntries(from: description)

        #expect(entries.map(\.title) == ["One", "Two", "Three"])
    }

    @MainActor
    @Test("Description without timestamped lines yields no entries")
    func descriptionEntriesEmptyWithoutTimestamps() {
        let entries = MixTracklistParser.descriptionEntries(from: "Just a regular description.\nNo tracklist here.")
        #expect(entries.isEmpty)
    }

    // MARK: - Tier 2: Description Fallback

    @MainActor
    @Test("Parser falls back to description timestamps when chapters are absent")
    func descriptionFallbackParsesTracklist() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Mix",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            chapters: [],
            descriptionText: """
            Tracklist:
            00:00 A - One
            10:00 B - Two
            20:00 C - Three
            """
        )
        let parser = MixTracklistParser(youTubeClient: mockYouTube)

        let tracklist = await parser.parseTracklist(videoId: "mix")

        #expect(tracklist?.source == .description)
        #expect(tracklist?.entries.count == 3)
        #expect(tracklist?.entries.first?.artist == "A")

        _ = await parser.parseTracklist(videoId: "mix")
        #expect(mockYouTube.getWatchNextCallCount == 1)
    }

    @MainActor
    @Test("Qualifying chapters win over a description tracklist")
    func chaptersTakePriorityOverDescription() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Mix",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            chapters: [
                YouTubeChapter(videoId: "mix", title: "A - One", startTime: 0, endTime: 60, timeText: nil, thumbnailURL: nil),
                YouTubeChapter(videoId: "mix", title: "B - Two", startTime: 60, endTime: 120, timeText: nil, thumbnailURL: nil),
                YouTubeChapter(videoId: "mix", title: "C - Three", startTime: 120, endTime: 180, timeText: nil, thumbnailURL: nil),
            ],
            descriptionText: "00:00 X - Other\n01:00 Y - Other\n02:00 Z - Other"
        )

        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube).parseTracklist(videoId: "mix")

        #expect(tracklist?.source == .chapters)
        #expect(tracklist?.entries.first?.artist == "A")
    }

    @MainActor
    @Test("Title-only description timestamps stay non-mix and cache the miss")
    func titleOnlyDescriptionCachesMiss() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Podcast",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            chapters: [],
            descriptionText: "00:00 Welcome\n10:00 Interview\n50:00 Wrap up"
        )
        let parser = MixTracklistParser(youTubeClient: mockYouTube)

        let first = await parser.parseTracklist(videoId: "podcast")
        let second = await parser.parseTracklist(videoId: "podcast")

        #expect(first == nil)
        #expect(second == nil)
        #expect(mockYouTube.getWatchNextCallCount == 1)
    }

    // MARK: - isMix Threshold

    @Test("Three or more entries is a mix; fewer is not")
    func isMixThreshold() {
        func tracklist(entryCount: Int) -> MixTracklist {
            let entries = (0 ..< entryCount).map {
                MixTrackEntry(
                    startTime: TimeInterval($0) * 60, endTime: nil,
                    title: "T\($0)", artist: "A\($0)", source: .chapters
                )
            }
            return MixTracklist(videoId: "v", entries: entries, source: .chapters)
        }

        #expect(tracklist(entryCount: MixTracklist.minEntryCount - 1).isMix == false)
        #expect(tracklist(entryCount: MixTracklist.minEntryCount).isMix == true)
        #expect(tracklist(entryCount: MixTracklist.minEntryCount + 5).isMix == true)
    }

    @Test("Generic navigation chapters are not treated as a song mix")
    func isMixRequiresStructuredTrackLabels() {
        func tracklist(artists: [String?]) -> MixTracklist {
            let entries = artists.enumerated().map { index, artist in
                MixTrackEntry(
                    startTime: TimeInterval(index) * 60,
                    endTime: TimeInterval(index + 1) * 60,
                    title: artist == nil ? ["Intro", "Main section", "Outro"][index % 3] : "Track \(index)",
                    artist: artist,
                    source: .chapters
                )
            }
            return MixTracklist(videoId: "v", entries: entries, source: .chapters)
        }

        #expect(!tracklist(artists: [nil, nil, nil]).isMix)
        #expect(tracklist(artists: ["A", "B", "C", nil, nil]).isMix)
        #expect(tracklist(artists: ["A", "B", "C", nil, nil, nil, nil]).isMix)
    }

    @Test("Title-only chapter labels do not establish a song mix")
    func titleOnlyChapterTracklistIsNotMix() {
        let entries = ["Track One", "Track Two", "Track Three"].enumerated().map { index, title in
            MixTrackEntry(
                startTime: TimeInterval(index) * 60,
                endTime: TimeInterval(index + 1) * 60,
                title: title,
                artist: nil,
                source: .chapters
            )
        }
        #expect(!MixTracklist(videoId: "v", entries: entries, source: .chapters).isMix)
    }

    @Test("Description timestamps alone do not establish a song mix")
    func titleOnlyDescriptionTracklistIsNotMix() {
        let entries = ["Track One", "Track Two", "Track Three"].enumerated().map { index, title in
            MixTrackEntry(
                startTime: TimeInterval(index) * 60,
                endTime: TimeInterval(index + 1) * 60,
                title: title,
                artist: nil,
                source: .description
            )
        }
        #expect(!MixTracklist(videoId: "v", entries: entries, source: .description).isMix)
    }

    @Test("Structured description labels can establish a song mix")
    func structuredDescriptionTracklistIsMix() {
        let entries = [
            MixTrackEntry(startTime: 0, endTime: 60, title: "One", artist: "Artist One", source: .description),
            MixTrackEntry(startTime: 60, endTime: 120, title: "Two", artist: "Artist Two", source: .description),
            MixTrackEntry(startTime: 120, endTime: 180, title: "Three", artist: nil, source: .description),
        ]
        #expect(MixTracklist(videoId: "v", entries: entries, source: .description).isMix)
    }

    @Test("Structured and title-only song labels can coexist in a mix")
    func mixedTrackLabelFormatsAreMix() {
        let entries = [
            MixTrackEntry(startTime: 0, endTime: 60, title: "One", artist: "Artist One", source: .chapters),
            MixTrackEntry(startTime: 60, endTime: 120, title: "Track Two", artist: "Artist Two", source: .chapters),
            MixTrackEntry(startTime: 120, endTime: 180, title: "Track Three", artist: nil, source: .chapters),
        ]
        #expect(MixTracklist(videoId: "v", entries: entries, source: .chapters).isMix)
    }

    @Test("Artist-qualified generic-looking song titles are retained")
    func artistQualifiedIntroIsRetained() {
        let entries = ["Intro", "Song", "Outro"].enumerated().map { index, title in
            MixTrackEntry(
                startTime: TimeInterval(index) * 60,
                endTime: TimeInterval(index + 1) * 60,
                title: title,
                artist: "Artist",
                source: .chapters
            )
        }
        let list = MixTracklist(videoId: "v", entries: entries, source: .chapters)
        #expect(list.entries.count == 3)
        #expect(list.isMix)
    }

    @Test("Generic title-only chapter names are not a mix")
    func genericTitleOnlyChaptersAreNotMix() {
        let entries = ["Setup", "Demo", "Questions"].enumerated().map { index, title in
            MixTrackEntry(
                startTime: TimeInterval(index) * 60,
                endTime: TimeInterval(index + 1) * 60,
                title: title,
                artist: nil,
                source: .chapters
            )
        }
        #expect(!MixTracklist(videoId: "v", entries: entries, source: .chapters).isMix)
    }

    @Test("Navigation-like words in song titles are not removed without a numeric suffix")
    func navigationWordSongTitlesAreRetained() {
        let entries = ["Part Time Lover", "Chapter Civil", "Section Mild"].enumerated().map { index, title in
            MixTrackEntry(
                startTime: TimeInterval(index) * 60,
                endTime: TimeInterval(index + 1) * 60,
                title: title,
                artist: nil,
                source: .chapters
            )
        }
        let list = MixTracklist(videoId: "v", entries: entries, source: .chapters)
        #expect(list.entries.count == 3)
        #expect(!list.isMix)
    }

    @Test("Canonical numeric navigation labels are still removed")
    func canonicalNavigationLabelsAreRemoved() {
        let entries = ["Part IV", "Chapter 2", "Actual Song"].enumerated().map { index, title in
            MixTrackEntry(
                startTime: TimeInterval(index) * 60,
                endTime: TimeInterval(index + 1) * 60,
                title: title,
                artist: nil,
                source: .chapters
            )
        }
        let list = MixTracklist(videoId: "v", entries: entries, source: .chapters)
        #expect(list.entries.map(\.title) == ["Actual Song"])
    }

    // MARK: - entry(at:) Lookup

    @Test("entry(at:) returns the active sub-track and nil before the first entry")
    func entryLookupByProgress() {
        let entries = [
            MixTrackEntry(startTime: 0, endTime: 600, title: "A", artist: "1", source: .chapters),
            MixTrackEntry(startTime: 600, endTime: 1200, title: "B", artist: "2", source: .chapters),
            MixTrackEntry(startTime: 1200, endTime: nil, title: "C", artist: "3", source: .chapters),
        ]
        let list = MixTracklist(videoId: "v", entries: entries, source: .chapters)

        #expect(list.entry(at: 0)?.title == "A")
        #expect(list.entry(at: 599)?.title == "A")
        #expect(list.entry(at: 600)?.title == "B")
        #expect(list.entry(at: 5000)?.title == "C")
    }

    @Test("entry(at:) respects explicit end times and gaps")
    func entryLookupRespectsEndTimes() {
        let entries = [
            MixTrackEntry(startTime: 0, endTime: 100, title: "A", artist: "1", source: .chapters),
            MixTrackEntry(startTime: 120, endTime: 200, title: "B", artist: "2", source: .chapters),
            MixTrackEntry(startTime: 200, endTime: 250, title: "C", artist: "3", source: .chapters),
        ]
        let list = MixTracklist(videoId: "v", entries: entries, source: .chapters)

        #expect(list.entry(at: 99)?.title == "A")
        #expect(list.entry(at: 100) == nil)
        #expect(list.entry(at: 119) == nil)
        #expect(list.entry(at: 120)?.title == "B")
        #expect(list.entry(at: 250) == nil)
        #expect(list.entry(at: 5000) == nil)
    }

    @Test("Final entry duration falls back to the parent video duration")
    func finalEntryDurationFallback() {
        let first = MixTrackEntry(startTime: 0, endTime: 100, title: "A", artist: "1", source: .chapters)
        let middle = MixTrackEntry(startTime: 100, endTime: nil, title: "B", artist: "2", source: .chapters)
        let final = MixTrackEntry(startTime: 200, endTime: nil, title: "C", artist: "3", source: .chapters)
        let list = MixTracklist(videoId: "v", entries: [first, middle, final], source: .chapters)

        #expect(list.effectiveDuration(for: first, videoDuration: 290) == 100)
        #expect(list.effectiveDuration(for: middle, videoDuration: 290) == 100)
        #expect(list.effectiveDuration(for: final, videoDuration: 290) == 90)
        #expect(list.effectiveDuration(for: final, videoDuration: 200) == nil)
    }

    @Test("Tracklist timestamps provide a parent-duration lower bound")
    func knownDurationLowerBound() {
        let entries = [
            MixTrackEntry(startTime: 0, endTime: 100, title: "A", artist: "1", source: .chapters),
            MixTrackEntry(startTime: 100, endTime: nil, title: "B", artist: "2", source: .chapters),
            MixTrackEntry(startTime: 700, endTime: nil, title: "C", artist: "3", source: .chapters),
        ]
        let list = MixTracklist(videoId: "v", entries: entries, source: .chapters)

        #expect(list.knownDurationLowerBound == 700)
    }
}
