import Testing
@testable import Kaset

@Suite(.tags(.model))
struct FoundationModelsPromptLibraryTests {
    @Test("26.4 command prompt is shorter than legacy prompt")
    func optimizedCommandPromptIsShorter() {
        let legacy = FoundationModelsPromptLibrary.commandBarInstructions(
            version: .legacy26_0To26_3
        )
        let latest = FoundationModelsPromptLibrary.commandBarInstructions(
            version: .optimized26_4AndLater
        )

        #expect(latest.count < legacy.count)
        #expect(latest.contains("resume only when the user clearly wants to continue current playback"))
        #expect(latest.contains("inspectQueue"))
        #expect(latest.contains("clearQueue"))
        #expect(latest.contains("CommandBarParseResult"))
    }

    @Test("26.4 lyrics prompt keeps the structured output guidance")
    func optimizedLyricsPromptIncludesStructuredGuidance() {
        let prompt = FoundationModelsPromptLibrary.lyricsExplanationPrompt(
            trackTitle: "Nights",
            artistsDisplay: "Frank Ocean",
            lyrics: "Round the city, round the clock",
            version: .optimized26_4AndLater
        )

        #expect(prompt.contains("Song: \"Nights\" by Frank Ocean"))
        #expect(prompt.contains("Identify 2-5 main themes"))
        #expect(prompt.contains("Explain what the song is saying in 2-4 sentences"))
    }

    @Test("26.4 queue prompt asks for vivid analysis instead of a dry listing")
    func optimizedQueuePromptPrefersAnalysis() {
        let instructions = FoundationModelsPromptLibrary.queueDescriptionInstructions(
            version: .optimized26_4AndLater
        )
        let prompt = FoundationModelsPromptLibrary.queueDescriptionPrompt(
            trackList: "8. [CURRENT] Nights - Frank Ocean\n9. [UP NEXT] Self Control - Frank Ocean",
            totalTracks: 100,
            shownTracks: 2,
            version: .optimized26_4AndLater
        )

        #expect(instructions.contains("radio host or tastemaker"))
        #expect(instructions.contains("Do not invent facts"))
        #expect(instructions.contains("QueueAnalysisSummary"))
        #expect(prompt.contains("focused slice around the current position"))
        #expect(prompt.contains("Analyze the queue's momentum"))
        #expect(prompt.contains("Fill the QueueAnalysisSummary fields"))
    }

    @Test("queue track lines keep the current song inside the visible window")
    func queueTrackLinesCenterOnCurrentSong() {
        let songs = (1 ... 10).map { index in
            Song(
                id: "video-\(index)",
                title: "Song \(index)",
                artists: [Artist(id: "artist-\(index)", name: "Artist \(index)")],
                videoId: "video-\(index)"
            )
        }

        let lines = FoundationModelsPromptLibrary.queueTrackLines(
            from: songs,
            currentIndex: 7,
            isPlaying: true,
            limit: 5
        )

        #expect(lines.count == 5)
        #expect(lines[0].hasPrefix("4. "))
        #expect(lines.contains { $0.contains("[NOW PLAYING] Song 8") })
        #expect(lines.last?.hasPrefix("8. ") == true)
    }

    @Test("middleTruncate preserves both ends of long text")
    func middleTruncatePreservesLeadingAndTrailingContext() {
        let text = "abcdefghij1234567890klmnopqrst"
        let truncated = FoundationModelsPromptLibrary.middleTruncate(
            text,
            targetLength: 20,
            marker: "..."
        )

        #expect(truncated.count == 20)
        #expect(truncated.hasPrefix("abcdefghi"))
        #expect(truncated.hasSuffix("mnopqrst"))
        #expect(truncated.contains("..."))
    }

    @Test("middleTruncate can drop content entirely")
    func middleTruncateAllowsEmptyFallback() {
        let truncated = FoundationModelsPromptLibrary.middleTruncate(
            "abcdefghij",
            targetLength: 0,
            marker: "..."
        )

        #expect(truncated.isEmpty)
    }

    @Test("playlist track list truncates titles and artists for prompt safety")
    func playlistTrackListTruncatesFields() {
        let song = Song(
            id: "video-1",
            title: String(repeating: "T", count: 60),
            artists: [
                Artist(id: "artist-1", name: String(repeating: "A", count: 40)),
            ],
            videoId: "video-1"
        )

        let trackList = FoundationModelsPromptLibrary.playlistTrackList(from: [song], limit: 1)
        let trackLines = FoundationModelsPromptLibrary.playlistTrackLines(from: [song], limit: 1)

        #expect(trackList.contains("(video ID: video-1)"))
        #expect(!trackList.contains("[id:"))
        #expect(!trackList.contains(String(repeating: "T", count: 60)))
        #expect(!trackList.contains(String(repeating: "A", count: 40)))
        #expect(trackLines.count == 1)
        #expect(trackLines[0].contains("(video ID: video-1)"))
    }

    @Test("26.4 playlist prompt asks for minimal changes only")
    func optimizedPlaylistPromptNarrowsTheTask() {
        let prompt = FoundationModelsPromptLibrary.playlistRefinementPrompt(
            trackList: "1. Song - Artist (video ID: abc)",
            totalTracks: 10,
            shownTracks: 1,
            request: "Remove duplicates",
            version: .optimized26_4AndLater
        )

        #expect(prompt.contains("Playlist has 10 songs. You can review details for 1 song."))
        #expect(prompt.contains("Return only the removals, optional reordering, and a brief reasoning string needed for the request."))
    }

    @Test("26.4 playlist prompt includes zero-track fallback guidance")
    func optimizedPlaylistPromptHandlesZeroTrackFallback() {
        let prompt = FoundationModelsPromptLibrary.playlistRefinementPrompt(
            trackList: "",
            totalTracks: 10,
            shownTracks: 0,
            request: "Remove duplicates",
            version: .optimized26_4AndLater
        )

        #expect(prompt.contains("No track details fit in the on-device context window."))
        #expect(prompt.contains("Return no removals or reordering"))
    }
}
