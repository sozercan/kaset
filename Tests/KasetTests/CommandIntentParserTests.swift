import Testing
@testable import Kaset

@Suite(.serialized, .timeLimit(.minutes(1)))
struct CommandIntentParserTests {
    @Test("Deterministic controls are parsed locally")
    func deterministicParsing() {
        guard #available(macOS 26.0, *) else { return }
        let parser = CommandIntentParser()
        let cases: [(String, CommandExecutor.Request)] = [
            ("pause", .pause),
            ("resume", .resume),
            ("skip this song", .skip),
            ("previous track", .previous),
            ("i like this", .like),
            ("dislike this song", .dislike),
            ("clear queue", .clearQueue),
            ("shuffle my queue", .shuffleQueue),
        ]
        for (query, expected) in cases {
            #expect(parser.deterministicRequest(for: query) == expected)
        }
    }

    @Test("Fallback parser extracts searchable playback queries")
    func fallbackPlaybackQueryExtraction() {
        guard #available(macOS 26.0, *) else { return }
        let parser = CommandIntentParser()
        #expect(
            parser.fallbackRequest(for: "Play something chill") ==
                .playSearch(query: "chill music", description: "something chill")
        )
    }

    @Test("Fallback parser routes explicit searches without AI")
    func fallbackExplicitSearchExtraction() {
        guard #available(macOS 26.0, *) else { return }
        let parser = CommandIntentParser()
        #expect(
            parser.fallbackRequest(for: "Search for Billie Eilish") ==
                .openSearch(query: "Billie Eilish")
        )
    }

    @Test("Fallback parser extracts queue additions")
    func fallbackQueueExtraction() {
        guard #available(macOS 26.0, *) else { return }
        let parser = CommandIntentParser()
        #expect(
            parser.fallbackRequest(for: "Add jazz to queue") ==
                .queueSearch(query: "jazz", description: "jazz")
        )
    }

    @Test("Queue inspection phrases are detected without being treated as commands")
    func queueInspectionDetection() {
        guard #available(macOS 26.0, *) else { return }
        let parser = CommandIntentParser()
        #expect(parser.isQueueInspectionQuery("What's in my queue?"))
        #expect(parser.isQueueInspectionQuery("show my queue"))
        #expect(parser.isQueueInspectionQuery("What's playing next?"))
        #expect(parser.isQueueInspectionQuery("Tell me what's coming up"))
        #expect(!parser.isQueueInspectionQuery("clear my queue"))
        #expect(!parser.isQueueInspectionQuery("add jazz to queue"))
        #expect(!parser.isQueueInspectionQuery("show me Coming Up"))
        #expect(!parser.isQueueInspectionQuery("next track"))
    }
}
