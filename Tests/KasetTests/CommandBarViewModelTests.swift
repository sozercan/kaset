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

    @Test("Deterministic commands bypass Apple Intelligence")
    func deterministicCommandsBypassAI() async {
        let playerService = MockPlayerService()
        let recorder = Recorder()
        let aiCallCounter = Counter()

        let aiClient = CommandBarViewModel.AIClient(
            refreshAvailability: {},
            isAvailable: { true },
            supportsCurrentLocale: { true },
            prewarm: { _ in },
            resolveIntent: { _, _ in
                await aiCallCounter.increment()
                return MusicIntent(
                    action: .play,
                    query: "",
                    shuffleScope: "",
                    artist: "",
                    genre: "",
                    mood: "",
                    era: "",
                    version: "",
                    activity: ""
                )
            }
        )

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

        let aiClient = CommandBarViewModel.AIClient(
            refreshAvailability: {},
            isAvailable: { true },
            supportsCurrentLocale: { true },
            prewarm: { _ in },
            resolveIntent: { _, _ in
                await aiCallCounter.increment()
                try await Task.sleep(for: .milliseconds(200))
                return MusicIntent(
                    action: .search,
                    query: "slow request",
                    shuffleScope: "",
                    artist: "",
                    genre: "",
                    mood: "",
                    era: "",
                    version: "",
                    activity: ""
                )
            }
        )

        let viewModel = self.makeViewModel(
            playerService: playerService,
            aiClient: aiClient,
            recorder: recorder,
            requestTimeout: .seconds(1)
        )

        viewModel.inputText = "Search for slow request"
        viewModel.submit()
        viewModel.submit()

        try? await Task.sleep(for: .milliseconds(30))
        #expect(await aiCallCounter.get() == 1)

        viewModel.cancelActiveRequest()
    }

    @Test("Timeout falls back to deterministic search routing")
    func timeoutFallsBackToSearchRouting() async {
        let playerService = MockPlayerService()
        let recorder = Recorder()

        let aiClient = CommandBarViewModel.AIClient(
            refreshAvailability: {},
            isAvailable: { true },
            supportsCurrentLocale: { true },
            prewarm: { _ in },
            resolveIntent: { _, _ in
                try await Task.sleep(for: .seconds(1))
                return MusicIntent(
                    action: .play,
                    query: "",
                    shuffleScope: "",
                    artist: "",
                    genre: "",
                    mood: "",
                    era: "",
                    version: "",
                    activity: ""
                )
            }
        )

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

        let aiClient = CommandBarViewModel.AIClient(
            refreshAvailability: {},
            isAvailable: { true },
            supportsCurrentLocale: { true },
            prewarm: { _ in },
            resolveIntent: { _, _ in
                try await withTaskCancellationHandler(operation: {
                    try await Task.sleep(for: .seconds(1))
                    return MusicIntent(
                        action: .play,
                        query: "",
                        shuffleScope: "",
                        artist: "",
                        genre: "",
                        mood: "",
                        era: "",
                        version: "",
                        activity: ""
                    )
                }, onCancel: {
                    Task { await wasCancelled.setTrue() }
                })
            }
        )

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
}
