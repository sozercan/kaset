import Testing
@testable import Kaset

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
}
