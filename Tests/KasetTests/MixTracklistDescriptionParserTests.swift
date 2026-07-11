import Foundation
import Testing
@testable import Kaset

// MARK: - MixTracklistDescriptionParserTests

@Suite(.tags(.model))
struct MixTracklistDescriptionParserTests {
    @MainActor
    @Test("Description timestamp fallback builds a structured mix tracklist")
    func parsesDescriptionTimestampFallback() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Description Mix",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            Notes before the tracklist block.

            Tracklist:
            00:00 - Artist A - Track One
            03:15 Artist B – Track Two
            [06:30] Artist C — Track Three

            More links after the tracklist.
            """
        )
        let parser = MixTracklistParser(youTubeClient: mockYouTube)

        let tracklist = await parser.parseTracklist(videoId: "description-mix")

        #expect(tracklist?.source == .description)
        #expect(tracklist?.entries.map(\.startTime) == [0, 195, 390])
        #expect(tracklist?.entries.map(\.endTime) == [195, 390, nil])
        #expect(tracklist?.entries.map(\.artist) == ["Artist A", "Artist B", "Artist C"])
        #expect(tracklist?.entries.map(\.title) == ["Track One", "Track Two", "Track Three"])
        if let tracklist, let finalEntry = tracklist.entries.last {
            #expect(tracklist.effectiveDuration(for: finalEntry, videoDuration: 450) == 60)
        }
        #expect(mockYouTube.getWatchNextCallCount == 1)
    }

    @MainActor
    @Test("Description timestamp fallback preserves common timestamp layouts")
    func preservesCommonDescriptionTimestampLayouts() async {
        let descriptions = [
            "0:00 A - One\n1:02:03 B - Two\n2:00:00 C - Three",
            "A - One 0:00\nB - Two 1:02:03\nC - Three 2:00:00",
            "[0:00] A - One\n[1:02:03] B - Two\n[2:00:00] C - Three",
            "(0:00) A - One\n(1:02:03) B - Two\n(2:00:00) C - Three",
            "1. A - One 0:00\n2. B - Two 1:02:03\n3. C - Three 2:00:00",
        ]

        for (index, description) in descriptions.enumerated() {
            let mockYouTube = MockYouTubeClient()
            mockYouTube.watchNextData = WatchNextData(
                videoTitle: "Description Mix",
                viewCountText: nil,
                publishedText: nil,
                channel: nil,
                related: [],
                descriptionText: "Tracklist:\n\(description)"
            )

            let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
                .parseTracklist(videoId: "description-format-\(index)")

            #expect(tracklist?.entries.map(\.startTime) == [0, 3723, 7200])
            #expect(tracklist?.entries.map(\.artist) == ["A", "B", "C"])
            #expect(tracklist?.entries.map(\.title) == ["One", "Two", "Three"])
        }
    }

    @MainActor
    @Test("Description timestamp fallback keeps the longest increasing run")
    func keepsLongestIncreasingDescriptionRun() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Techno Mix",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            Tracklist:
            12:00 Premiere starts
            00:00 Artist A - Track One
            03:00 Artist B - Track Two
            06:00 Artist C - Track Three
            09:00 Artist D - Track Four
            15:00 Artist E - Track Five
            """
        )

        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "increasing-description-run")

        #expect(tracklist?.entries.map(\.startTime) == [0, 180, 360, 540, 900])
        #expect(tracklist?.entries.map(\.title) == [
            "Track One", "Track Two", "Track Three", "Track Four", "Track Five",
        ])
    }

    @MainActor
    @Test("The longest valid description block wins before artist count")
    func prefersLongestValidDescriptionBlock() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Progressive Session",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            00:00 Short Artist A - Short One
            04:00 Short Artist B - Short Two
            08:00 Short Artist C - Short Three
            12:00 Short Artist D - Short Four
            16:00 Short Artist E - Short Five
            Alternate sequence:
            00:00 Long Artist A - Long One
            03:00 Long Artist B - Long Two
            06:00 Long Artist C - Long Three
            09:00 Long Artist D - Long Four
            12:00 Drift
            15:00 Glow
            18:00 Horizon
            21:00 Finale
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "longest-valid-description-block")

        #expect(tracklist?.entries.count == 8)
        #expect(tracklist?.entries.first?.artist == "Long Artist A")
        #expect(tracklist?.entries.last?.title == "Finale")
    }

    @MainActor
    @Test("An invalid description timestamp does not hide a later valid timestamp")
    func skipsInvalidTimestampWithinDescriptionLine() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Description Mix",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            Tracklist:
            1:75:00 typo then 0:00 A - One
            1:00 B - Two
            2:00 C - Three
            """
        )

        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "invalid-then-valid-description-time")

        #expect(tracklist?.entries.map(\.startTime) == [0, 60, 120])
        #expect(tracklist?.entries.first?.artist == "A")
        #expect(tracklist?.entries.first?.title == "One")
    }

    @MainActor
    @Test("Description timestamp fallback prefers structured duplicate rows")
    func prefersStructuredDuplicateDescriptionRows() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Duplicated Description Mix",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            Summary:
            00:00 Intro - Welcome
            03:00 Host - Segment
            06:00 Outro - Closing

            Tracklist:
            00:00 Artist A - Track One
            03:00 Artist B - Track Two
            06:00 Artist C - Track Three
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "duplicated-description-mix")

        #expect(tracklist?.entries.map(\.artist) == ["Artist A", "Artist B", "Artist C"])
        #expect(tracklist?.entries.map(\.title) == ["Track One", "Track Two", "Track Three"])
    }

    @MainActor
    @Test("Description timestamp fallback supports cumulative minutes above 99")
    func parsesCumulativeMinuteDescriptionTimestamps() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Long Description Mix",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            Tracklist:
            00:00 Artist A - Track One
            99:59 Artist B - Track Two
            100:05 Artist C - Track Three
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "long-description-mix")

        #expect(tracklist?.entries.map(\.startTime) == [0, 5999, 6005])
        #expect(tracklist?.entries.map(\.endTime) == [5999, 6005, nil])
    }

    @MainActor
    @Test("Description timestamp fallback rejects non-track agendas")
    func rejectsTimestampedAgenda() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Conference Agenda",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            00:00 Introduction
            01:00 Sponsor
            02:00 Q&A
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "agenda")

        #expect(tracklist == nil)
    }

    @MainActor
    @Test("Description timestamp fallback accepts a headed title-only tracklist")
    func acceptsHeadedTitleOnlyTracklist() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Title-only Mix",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            Tracklist:
            00:00 Intro
            03:00 First Song
            06:00 Finale
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "headed-title-only")

        #expect(tracklist?.entries.map(\.title) == ["Intro", "First Song", "Finale"])
        #expect(tracklist?.entries.allSatisfy { $0.artist == nil } == true)
    }

    @MainActor
    @Test("Inline description tracklist headings permit title-only entries")
    func acceptsInlineTracklistHeading() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Inline Tracklist",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            Tracklist: 00:00 Intro
            03:00 First Song
            06:00 Finale
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "inline-tracklist-heading")

        #expect(tracklist?.entries.map(\.title) == ["Intro", "First Song", "Finale"])
        #expect(tracklist?.entries.allSatisfy { $0.artist == nil } == true)
    }

    @MainActor
    @Test("A tracklist heading applies only to the first qualifying timestamp run")
    func doesNotPropagateHeadingAcrossTimestampReset() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Music and Talk",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            Tracklist:
            00:00 Artist A - Song One
            03:00 Artist B - Song Two
            06:00 Artist C - Song Three
            00:00 Welcome
            10:00 Keynote
            20:00 Q&A
            30:00 Closing
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "heading-timestamp-reset")

        #expect(tracklist?.entries.count == 3)
        #expect(tracklist?.entries.map(\.artist) == ["Artist A", "Artist B", "Artist C"])
        #expect(tracklist?.entries.map(\.title) == ["Song One", "Song Two", "Song Three"])
    }

    @MainActor
    @Test("Description timestamp fallback ignores negated tracklist prose")
    func ignoresNegatedTracklistProse() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Conference Agenda",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            No tracklist is available.
            00:00 Host - Welcome
            10:00 Jane Doe - Keynote
            30:00 Panel - Q&A
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "negated-tracklist-prose")

        #expect(tracklist == nil)
    }

    @MainActor
    @Test("Description tracklist headings do not cross intervening prose")
    func rejectsHeadingSeparatedByProse() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Conference Agenda",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            Tracklist:
            Unavailable
            00:00 Welcome
            10:00 Keynote
            30:00 Q&A
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "heading-separated-by-prose")

        #expect(tracklist == nil)
    }

    @MainActor
    @Test("Description timestamp fallback rejects dash-formatted agendas")
    func rejectsDashFormattedAgenda() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Conference Agenda",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            00:00 Host - Welcome
            10:00 Jane Doe - Keynote
            30:00 Panel - Q&A
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "dash-agenda")

        #expect(tracklist == nil)
    }

    @MainActor
    @Test("Description timestamp fallback rejects long dash-formatted agendas")
    func rejectsLongDashFormattedAgenda() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Conference Agenda",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            00:00 Host - Welcome
            10:00 Jane Doe - Keynote
            20:00 Panel - Q&A
            30:00 Sponsor - Demo
            40:00 Host - Closing
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "long-dash-agenda")

        #expect(tracklist == nil)
    }

    @MainActor
    @Test("Description timestamp fallback accepts a headingless music mix")
    func acceptsHeadinglessMusicMix() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Deep Progressive Techno #11",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            00:00 Artist A - Track One
            08:40 Artist B - Track Two
            15:15 Artist C - Track Three
            23:00 Artist D - Track Four
            30:00 Artist E - Track Five
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "headingless-techno-mix")

        #expect(tracklist?.entries.count == 5)
        #expect(tracklist?.entries.first?.artist == "Artist A")
    }

    @MainActor
    @Test("Short localized description tracklists remain supported")
    func acceptsShortLocalizedTracklist() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Sesión progresiva",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            Lista de canciones:
            00:00 Artista A - Canción Uno
            04:00 Artista B - Canción Dos
            08:00 Artista C - Canción Tres
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "short-localized-tracklist")

        #expect(tracklist?.entries.count == MixTracklist.minEntryCount)
        #expect(tracklist?.entries.map(\.artist) == ["Artista A", "Artista B", "Artista C"])
    }

    @MainActor
    @Test("Presentation title words do not veto structured song rows")
    func acceptsStructuredMusicPodcastTracklist() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Progressive House Podcast #42",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            00:00 Artist A - Welcome Home
            04:00 Artist B - Opening Night
            08:00 Artist C - Night Drive
            12:00 Artist D - Pulse
            16:00 Artist E - Afterglow
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "structured-music-podcast")

        #expect(tracklist?.entries.count == 5)
        #expect(tracklist?.entries.map(\.title) == [
            "Welcome Home", "Opening Night", "Night Drive", "Pulse", "Afterglow",
        ])
    }

    @MainActor
    @Test("Agenda-like song words do not veto unambiguous music rows")
    func acceptsAgendaWordsInSongTitles() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Deep House Mix",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            00:00 Artist A - Welcome Home
            04:00 Artist B - Opening Night
            08:00 Artist C - Closing Time
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "agenda-words-in-song-titles")

        #expect(tracklist?.entries.count == MixTracklist.minEntryCount)
        #expect(tracklist?.entries.map(\.title) == ["Welcome Home", "Opening Night", "Closing Time"])
    }

    @MainActor
    @Test("Headingless description tracklists may contain blank lines")
    func acceptsBlankSeparatedHeadinglessMix() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Techno Mix",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            00:00 Artist A - Track One

            08:40 Artist B - Track Two

            15:15 Artist C - Track Three

            23:00 Artist D - Track Four

            30:00 Artist E - Track Five
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "blank-separated-headingless-mix")

        #expect(tracklist?.entries.count == 5)
        #expect(tracklist?.entries.last?.title == "Track Five")
    }

    @MainActor
    @Test("Highly structured headingless tracklists do not require title keywords")
    func acceptsHighlyStructuredHeadinglessMix() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Progressive House Session",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            00:00 Artist A - Track One
            05:00 Artist B - Track Two
            10:00 Artist C - Track Three
            15:00 Artist D - Track Four
            20:00 Artist E - Track Five
            25:00 Artist F - Track Six
            30:00 Artist G - Track Seven
            35:00 Artist H - Track Eight
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "structured-headingless-mix")

        #expect(tracklist?.entries.count == 8)
        #expect(tracklist?.entries.map(\.artist) == [
            "Artist A", "Artist B", "Artist C", "Artist D",
            "Artist E", "Artist F", "Artist G", "Artist H",
        ])
    }

    @MainActor
    @Test("Description timestamp fallback rejects music-topic agendas")
    func rejectsMusicTopicAgenda() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Techno Music Conference Discussion",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            00:00 Host - Welcome
            05:00 Guest - Context
            10:00 Panel - Discussion
            15:00 Sponsor - Demo
            20:00 Host - Closing
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "music-topic-agenda")

        #expect(tracklist == nil)
    }

    @MainActor
    @Test("Description timestamp fallback rejects electronic music workshops")
    func rejectsElectronicMusicWorkshop() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Electronic Music Workshop",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            00:00 Alice - Opening remarks
            05:00 Bob - Production context
            10:00 Carol - Sound design demo
            15:00 Dave - Panel discussion
            20:00 Alice - Closing remarks
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "electronic-music-workshop")

        #expect(tracklist == nil)
    }

    @MainActor
    @Test("Description timestamp fallback rejects partial timestamp components")
    func rejectsPartialTimestampComponent() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Description Mix",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            Tracklist:
            00:00 Artist A - Track One
            03:00 Artist B - Track Two
            06:00 Artist C - Track Three
            12:345 Fake Artist - Fake Track
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "partial-timestamp")

        #expect(tracklist?.entries.map(\.startTime) == [0, 180, 360])
        #expect(tracklist?.entries.map(\.title) == ["Track One", "Track Two", "Track Three"])
    }

    @MainActor
    @Test("Description timestamp fallback keeps blank-separated headed groups together")
    func keepsBlankSeparatedTracklistGroups() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Description Mix",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            Tracklist:
            00:00 Artist A - Track One
            03:00 Artist B - Track Two
            06:00 Artist C - Track Three

            09:00 Artist D - Track Four
            12:00 Artist E - Track Five
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "blank-separated-tracklist")

        #expect(tracklist?.entries.count == 5)
        #expect(tracklist?.entries.last?.title == "Track Five")
    }

    @MainActor
    @Test("Description timestamp fallback prioritizes an explicit tracklist heading")
    func prioritizesExplicitTracklistHeading() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Techno Music Discussion",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            00:00 Host - Welcome
            05:00 Guest - Context
            10:00 Panel - Discussion
            15:00 Sponsor - Demo
            20:00 Host - Closing

            Tracklist:
            00:00 Artist A - Track One
            08:00 Artist B - Track Two
            16:00 Artist C - Track Three
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "headed-tracklist-priority")

        #expect(tracklist?.entries.count == 3)
        #expect(tracklist?.entries.map(\.artist) == ["Artist A", "Artist B", "Artist C"])
    }

    @MainActor
    @Test("Description timestamp fallback rejects overflowing components atomically")
    func rejectsOverflowingDescriptionTimestamp() async {
        let mockYouTube = MockYouTubeClient()
        mockYouTube.watchNextData = WatchNextData(
            videoTitle: "Overflow Description",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            descriptionText: """
            Tracklist:
            00:00 Artist A - Track One
            03:15 Artist B - Track Two
            06:30 Artist C - Track Three
            9223372036854775808:03:15 Fake Artist - Fake Track
            """
        )
        let tracklist = await MixTracklistParser(youTubeClient: mockYouTube)
            .parseTracklist(videoId: "overflow-description")

        #expect(tracklist?.entries.map(\.startTime) == [0, 195, 390])
        #expect(tracklist?.entries.map(\.title) == ["Track One", "Track Two", "Track Three"])
    }
}
