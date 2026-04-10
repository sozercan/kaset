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

        #expect(trackList.contains("[id:video-1]"))
        #expect(!trackList.contains(String(repeating: "T", count: 60)))
        #expect(!trackList.contains(String(repeating: "A", count: 40)))
        #expect(trackLines.count == 1)
        #expect(trackLines[0].contains("[id:video-1]"))
    }

    @Test("26.4 playlist prompt asks for minimal changes only")
    func optimizedPlaylistPromptNarrowsTheTask() {
        let prompt = FoundationModelsPromptLibrary.playlistRefinementPrompt(
            trackList: "1. Song - Artist [id:abc]",
            totalTracks: 10,
            shownTracks: 1,
            request: "Remove duplicates",
            version: .optimized26_4AndLater
        )

        #expect(prompt.contains("Total songs: 10"))
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
