import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct CommandBarViewModelTests {
    @MainActor
    final class Recorder {
        var routedQueries: [String] = []
        var dismissCount = 0
    }

    actor Counter {
        private var value = 0

        func increment() {
            self.value += 1
        }

        func get() -> Int {
            self.value
        }
    }

    actor Flag {
        private var value = false

        func setTrue() {
            self.value = true
        }

        func get() -> Bool {
            self.value
        }
    }

    private func makeViewModel(
        client: MockYTMusicClient = MockYTMusicClient(),
        playerService: MockPlayerService = MockPlayerService(),
        aiClient: CommandBarViewModel.AIClient,
        recorder: Recorder,
        requestTimeout: Duration = .milliseconds(50),
        autoDismissDelay: Duration = .zero
    ) -> CommandBarViewModel {
        CommandBarViewModel(
            client: client,
            playerService: playerService,
            searchRouter: { query in
                recorder.routedQueries.append(query)
            },
            dismissAction: {
                recorder.dismissCount += 1
            },
            aiClient: aiClient,
            requestTimeout: requestTimeout,
            autoDismissDelay: autoDismissDelay
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while clock.now < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeSong(title: String, artist: String, videoId: String) -> Song {
        Song(
            id: videoId,
            title: title,
            artists: [Artist(id: "artist-\(videoId)", name: artist)],
            videoId: videoId
        )
    }

    nonisolated static func makeParsedCommand(
        action: CommandBarAction,
        subject: String = "",
        shuffleScope: String = "",
        artist: String = "",
        genre: String = "",
        mood: String = "",
        era: String = "",
        version: String = "",
        activity: String = ""
    ) -> CommandBarParseResult {
        CommandBarParseResult(
            action: action,
            subject: subject,
            shuffleScope: shuffleScope,
            artist: artist,
            genre: genre,
            mood: mood,
            era: era,
            version: version,
            activity: activity
        )
    }

    nonisolated static func makeQueueAnalysis(
        opening: String = "Now you're in a reflective stretch.",
        vibe: String = "late-night and warm",
        highlights: [String] = ["Dreams", "Pink + White"],
        summary: String = "You're starting from a soft center and letting the queue drift into something dreamy and nocturnal."
    ) -> QueueAnalysisSummary {
        QueueAnalysisSummary(
            opening: opening,
            vibe: vibe,
            highlights: highlights,
            summary: summary
        )
    }

    private func makeAIClient(
        isAvailable: Bool = true,
        supportsCurrentLocale: Bool = true,
        resolveCommand: @escaping @Sendable (_ query: String, _ instructions: String) async throws -> CommandBarParseResult,
        describeQueue: @escaping @Sendable (
            _ prompt: String,
            _ instructions: String,
            _ onPartial: @escaping @MainActor (QueueAnalysisSummary.PartiallyGenerated) -> Void
        ) async throws -> QueueAnalysisSummary = { _, _, _ in
            QueueAnalysisSummary(
                opening: "",
                vibe: "",
                highlights: [],
                summary: ""
            )
        },
        fittedQueueLineCount: @escaping @Sendable (
            _ lines: [String],
            _ totalTracks: Int,
            _ instructions: String,
            _ version: FoundationModelsPromptVersion
        ) async -> Int = { lines, _, _, _ in
            lines.count
        }
    ) -> CommandBarViewModel.AIClient {
        CommandBarViewModel.AIClient(
            refreshAvailability: {},
            isAvailable: { isAvailable },
            supportsCurrentLocale: { supportsCurrentLocale },
            prewarm: { _ in },
            resolveCommand: resolveCommand,
            describeQueue: describeQueue,
            fittedQueueLineCount: fittedQueueLineCount
        )
    }

    @Test("Deterministic commands bypass Apple Intelligence")
    func deterministicCommandsBypassAI() async {
        let playerService = MockPlayerService()
        let recorder = Recorder()
        let aiCallCounter = Counter()

        let aiClient = self.makeAIClient { _, _ in
            await aiCallCounter.increment()
            return Self.makeParsedCommand(action: .play)
        }

        let viewModel = self.makeViewModel(
            playerService: playerService,
            aiClient: aiClient,
            recorder: recorder
        )

        viewModel.inputText = "Skip this song"
        viewModel.submit()

        await self.waitUntil {
            playerService.nextCallCount == 1
        }

        #expect(await aiCallCounter.get() == 0)
        #expect(playerService.nextCallCount == 1)
        #expect(viewModel.resultMessage == "Skipped")
    }

    @Test("Single-flight ignores overlapping submissions")
    func singleFlightIgnoresOverlappingSubmissions() async {
        let playerService = MockPlayerService()
        let recorder = Recorder()
        let aiCallCounter = Counter()

        let aiClient = self.makeAIClient { _, _ in
            await aiCallCounter.increment()
            try await Task.sleep(for: .milliseconds(200))
            return Self.makeParsedCommand(action: .search, subject: "slow request")
        }

        let viewModel = self.makeViewModel(
            playerService: playerService,
            aiClient: aiClient,
            recorder: recorder,
            requestTimeout: .seconds(1)
        )

        viewModel.inputText = "Search for slow request"
        viewModel.submit()
        viewModel.submit()

        await self.waitUntil {
            await aiCallCounter.get() == 1
        }
        #expect(await aiCallCounter.get() == 1)

        viewModel.cancelActiveRequest()
    }

    @Test("Timeout falls back to deterministic search routing")
    func timeoutFallsBackToSearchRouting() async {
        let playerService = MockPlayerService()
        let recorder = Recorder()

        let aiClient = self.makeAIClient { _, _ in
            try await Task.sleep(for: .seconds(1))
            return Self.makeParsedCommand(action: .play)
        }

        let viewModel = self.makeViewModel(
            playerService: playerService,
            aiClient: aiClient,
            recorder: recorder,
            requestTimeout: .milliseconds(20)
        )

        viewModel.inputText = "Search for Billie Eilish"
        viewModel.submit()

        await self.waitUntil {
            !recorder.routedQueries.isEmpty
        }

        #expect(recorder.routedQueries == ["Billie Eilish"])
        #expect(viewModel.lastFallbackReason == .timedOut)
    }

    @Test("Dismiss cancels an in-flight request")
    func dismissCancelsInFlightRequest() async {
        let playerService = MockPlayerService()
        let recorder = Recorder()
        let wasCancelled = Flag()

        let aiClient = self.makeAIClient { _, _ in
            try await withTaskCancellationHandler(operation: {
                try await Task.sleep(for: .seconds(1))
                return Self.makeParsedCommand(action: .play)
            }, onCancel: {
                Task { await wasCancelled.setTrue() }
            })
        }

        let viewModel = self.makeViewModel(
            playerService: playerService,
            aiClient: aiClient,
            recorder: recorder,
            requestTimeout: .seconds(2)
        )

        viewModel.inputText = "Play something chill"
        viewModel.submit()
        try? await Task.sleep(for: .milliseconds(20))
        viewModel.dismiss()

        await self.waitUntil {
            recorder.dismissCount == 1
        }

        await self.waitUntil {
            await wasCancelled.get()
        }

        #expect(await wasCancelled.get())
        #expect(viewModel.isInteractionDisabled == false)
    }

    @Test("Dismiss cancels an in-flight queue analysis")
    func dismissCancelsInFlightQueueAnalysis() async {
        let playerService = MockPlayerService()
        playerService.queue = [
            self.makeSong(title: "Dreams", artist: "Fleetwood Mac", videoId: "song-1"),
            self.makeSong(title: "Pink + White", artist: "Frank Ocean", videoId: "song-2"),
        ]
        playerService.currentIndex = 0
        playerService.state = .playing

        let recorder = Recorder()
        let wasCancelled = Flag()

        let aiClient = self.makeAIClient(
            resolveCommand: { _, _ in
                Self.makeParsedCommand(action: .play)
            },
            describeQueue: { _, _, _ in
                try await withTaskCancellationHandler(operation: {
                    try await Task.sleep(for: .seconds(1))
                    return Self.makeQueueAnalysis()
                }, onCancel: {
                    Task { await wasCancelled.setTrue() }
                })
            }
        )

        let viewModel = self.makeViewModel(
            playerService: playerService,
            aiClient: aiClient,
            recorder: recorder
        )

        viewModel.inputText = "What's in my queue?"
        viewModel.submit()
        try? await Task.sleep(for: .milliseconds(20))
        viewModel.dismiss()

        await self.waitUntil {
            recorder.dismissCount == 1
        }

        await self.waitUntil {
            await wasCancelled.get()
        }

        #expect(await wasCancelled.get())
        #expect(viewModel.isInteractionDisabled == false)
        #expect(viewModel.resultMessage == nil)
    }

    @Test("Queue inspection uses Apple Intelligence description without clearing the queue")
    func queueInspectionUsesAIDescription() async {
        let playerService = MockPlayerService()
        playerService.queue = [
            self.makeSong(title: "Dreams", artist: "Fleetwood Mac", videoId: "song-1"),
            self.makeSong(title: "Pink + White", artist: "Frank Ocean", videoId: "song-2"),
            self.makeSong(title: "Night Drive", artist: "Chromatics", videoId: "song-3"),
        ]
        playerService.currentIndex = 0
        playerService.state = .playing

        let recorder = Recorder()
        let resolveCommandCalls = Counter()
        let describeQueueCalls = Counter()

        let aiClient = self.makeAIClient(
            resolveCommand: { _, _ in
                await resolveCommandCalls.increment()
                return Self.makeParsedCommand(action: .inspectQueue)
            },
            describeQueue: { prompt, _, _ in
                await describeQueueCalls.increment()
                #expect(prompt.contains("Dreams"))
                #expect(prompt.contains("NOW PLAYING"))
                #expect(
                    prompt.contains("Analyze the queue's momentum") ||
                        prompt.contains("Give a short, specific analysis of the queue's flow and vibe.")
                )
                return Self.makeQueueAnalysis(
                    summary: "You're starting with Fleetwood Mac, then easing into Frank Ocean and Chromatics for a dreamy late-night run."
                )
            }
        )

        let viewModel = self.makeViewModel(
            playerService: playerService,
            aiClient: aiClient,
            recorder: recorder
        )

        viewModel.inputText = "What's in my queue?"
        viewModel.submit()

        await self.waitUntil {
            viewModel.resultMessage != nil
        }

        #expect(await resolveCommandCalls.get() == 0)
        #expect(await describeQueueCalls.get() == 1)
        #expect(playerService.clearQueueCallCount == 0)
        #expect(
            viewModel.resultMessage ==
                "You're starting with Fleetwood Mac, then easing into Frank Ocean and Chromatics for a dreamy late-night run."
        )
        #expect(recorder.dismissCount == 0)
    }

    @Test("AI stage-1 inspect-queue action routes into queue analysis")
    func aiInspectQueueActionRoutesIntoQueueAnalysis() async {
        let playerService = MockPlayerService()
        playerService.queue = [
            self.makeSong(title: "Dreams", artist: "Fleetwood Mac", videoId: "song-1"),
            self.makeSong(title: "Pink + White", artist: "Frank Ocean", videoId: "song-2"),
        ]
        playerService.currentIndex = 0
        playerService.state = .playing

        let recorder = Recorder()
        let resolveCommandCalls = Counter()
        let describeQueueCalls = Counter()
        let aiClient = self.makeAIClient(
            resolveCommand: { _, _ in
                await resolveCommandCalls.increment()
                return Self.makeParsedCommand(action: .inspectQueue)
            },
            describeQueue: { _, _, _ in
                await describeQueueCalls.increment()
                return Self.makeQueueAnalysis(summary: "This queue opens gently and stays warm, with Fleetwood Mac melting into Frank Ocean.")
            }
        )

        let viewModel = self.makeViewModel(
            playerService: playerService,
            aiClient: aiClient,
            recorder: recorder
        )

        viewModel.inputText = "give me a read on the queue"
        viewModel.submit()

        await self.waitUntil {
            viewModel.resultMessage != nil
        }

        #expect(await resolveCommandCalls.get() == 1)
        #expect(await describeQueueCalls.get() == 1)
        #expect(playerService.clearQueueCallCount == 0)
        #expect(viewModel.resultMessage?.contains("Fleetwood Mac") == true)
        #expect(recorder.dismissCount == 0)
    }

    @Test("Queue inspection falls back to a local summary when Apple Intelligence is unavailable")
    func queueInspectionFallsBackLocally() async {
        let playerService = MockPlayerService()
        playerService.queue = [
            self.makeSong(title: "Dreams", artist: "Fleetwood Mac", videoId: "song-1"),
            self.makeSong(title: "Pink + White", artist: "Frank Ocean", videoId: "song-2"),
            self.makeSong(title: "Night Drive", artist: "Chromatics", videoId: "song-3"),
            self.makeSong(title: "Roads", artist: "Portishead", videoId: "song-4"),
        ]
        playerService.currentIndex = 1
        playerService.state = .paused

        let recorder = Recorder()
        let aiClient = self.makeAIClient(
            isAvailable: false,
            resolveCommand: { _, _ in
                Self.makeParsedCommand(action: .play)
            }
        )

        let viewModel = self.makeViewModel(
            playerService: playerService,
            aiClient: aiClient,
            recorder: recorder
        )

        viewModel.inputText = "whats in my queue"
        viewModel.submit()

        await self.waitUntil {
            viewModel.resultMessage != nil
        }

        #expect(playerService.clearQueueCallCount == 0)
        #expect(viewModel.lastFallbackReason == .aiUnavailable)
        #expect(
            viewModel.resultMessage?.hasPrefix(
                "Apple Intelligence wasn't available for a fuller queue analysis, so here's a quick summary:"
            ) == true
        )
        #expect(viewModel.resultMessage?.contains("Currently on \"Pink + White\" by Frank Ocean.") == true)
        #expect(viewModel.resultMessage?.contains("Up next: \"Night Drive\" by Chromatics, \"Roads\" by Portishead.") == true)
        #expect(recorder.dismissCount == 0)
    }

    @Test("AI clear-queue action no longer depends on the old queue sentinel")
    func aiClearQueueActionUsesDedicatedParseAction() async {
        let playerService = MockPlayerService()
        playerService.queue = [
            self.makeSong(title: "Dreams", artist: "Fleetwood Mac", videoId: "song-1"),
            self.makeSong(title: "Pink + White", artist: "Frank Ocean", videoId: "song-2"),
        ]
        let recorder = Recorder()
        let aiClient = self.makeAIClient { _, _ in
            Self.makeParsedCommand(action: .clearQueue)
        }

        let viewModel = self.makeViewModel(
            playerService: playerService,
            aiClient: aiClient,
            recorder: recorder
        )

        viewModel.inputText = "please wipe the queue"
        viewModel.submit()

        await self.waitUntil {
            playerService.clearQueueCallCount == 1
        }

        #expect(playerService.clearQueueCallCount == 1)
        #expect(viewModel.resultMessage == "Queue cleared")
    }
}
