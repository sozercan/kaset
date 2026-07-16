import Testing
@testable import Kaset

@available(macOS 26.0, *)

@Suite(.serialized, .timeLimit(.minutes(1)))
struct CommandIntentParserTests {
    private let parser = CommandIntentParser()

    @Test("Deterministic controls are parsed locally", arguments: [
        ("pause", CommandExecutor.Request.pause),
        ("resume", CommandExecutor.Request.resume),
        ("skip this song", CommandExecutor.Request.skip),
        ("previous track", CommandExecutor.Request.previous),
        ("i like this", CommandExecutor.Request.like),
        ("dislike this song", CommandExecutor.Request.dislike),
        ("clear queue", CommandExecutor.Request.clearQueue),
        ("shuffle my queue", CommandExecutor.Request.shuffleQueue),
    ])
    func deterministicParsing(query: String, expected: CommandExecutor.Request) {
        #expect(self.parser.deterministicRequest(for: query) == expected)
    }

    @Test("Fallback parser extracts searchable playback queries")
    func fallbackPlaybackQueryExtraction() {
        #expect(
            self.parser.fallbackRequest(for: "Play something chill") ==
                .playSearch(query: "chill music", description: "something chill")
        )
    }

    @Test("Fallback parser routes explicit searches without AI")
    func fallbackExplicitSearchExtraction() {
        #expect(
            self.parser.fallbackRequest(for: "Search for Billie Eilish") ==
                .openSearch(query: "Billie Eilish")
        )
    }

    @Test("Fallback parser extracts queue additions")
    func fallbackQueueExtraction() {
        #expect(
            self.parser.fallbackRequest(for: "Add jazz to queue") ==
                .queueSearch(query: "jazz", description: "jazz")
        )
    }

    @Test("Queue inspection phrases are detected without being treated as commands")
    func queueInspectionDetection() {
        #expect(self.parser.isQueueInspectionQuery("What's in my queue?"))
        #expect(self.parser.isQueueInspectionQuery("show my queue"))
        #expect(self.parser.isQueueInspectionQuery("What's playing next?"))
        #expect(self.parser.isQueueInspectionQuery("Tell me what's coming up"))
        #expect(!self.parser.isQueueInspectionQuery("clear my queue"))
        #expect(!self.parser.isQueueInspectionQuery("add jazz to queue"))
        #expect(!self.parser.isQueueInspectionQuery("show me Coming Up"))
        #expect(!self.parser.isQueueInspectionQuery("next track"))
    }

    @Test("Radio phrases resolve to queueRadio deterministically", arguments: [
        "more like this",
        "songs like this",
        "start a radio",
        "keep it going",
        "similar songs",
    ])
    func radioDeterministic(query: String) {
        #expect(self.parser.deterministicRequest(for: query) == .queueRadio)
    }

    @Test("Dislike phrasing is never treated as a current-track radio request")
    func dislikeIsNotRadio() {
        #expect(self.parser.fallbackRequest(for: "i dislike this") == .dislike)
        #expect(self.parser.fallbackRequest(for: "don't like this") != .queueRadio)
    }

    @Test("More-like-this inside a longer sentence still routes to radio")
    func radioFallbackFromSentence() {
        #expect(self.parser.fallbackRequest(for: "add more songs like this to the queue") == .queueRadio)
    }

    @Test("Similar-to-an-artist is not hijacked into current-track radio")
    func similarToArtistIsNotRadio() {
        #expect(self.parser.fallbackRequest(for: "play similar songs to daft punk") != .queueRadio)
    }

    @Test("Remove-duplicates phrases resolve to removeDuplicates", arguments: [
        "remove duplicates",
        "remove duplicates from queue",
        "dedupe queue",
        "remove duplicate songs",
    ])
    func removeDuplicatesDeterministic(query: String) {
        #expect(self.parser.deterministicRequest(for: query) == .removeDuplicates)
    }

    @Test("A duplicate-removal request is not misparsed as removing a song named 'duplicates'")
    func removeDuplicatesTakesPrecedenceOverRemove() {
        #expect(self.parser.fallbackRequest(for: "please remove the duplicate tracks") == .removeDuplicates)
    }

    @Test("Fallback extracts the removal subject from a remove command")
    func removeSubjectExtraction() {
        #expect(
            self.parser.fallbackRequest(for: "remove daft punk songs from the queue") ==
                .removeFromQueue(query: "daft punk")
        )
    }
}
