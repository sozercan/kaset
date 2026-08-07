import Foundation
import Testing
@testable import Kaset

@Suite("YouTube Ask view models", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct YouTubeAskViewModelTests {
    @Test("Ask remains hidden and does not prepare until presented")
    func hiddenDefaultAndLazyPreparation() async {
        let client = MockYouTubeClient()
        let bootstrap = YouTubeAskBootstrap.testing(suggestions: ["Explain the main idea"])
        let sut = YouTubeAskViewModel(videoID: "fixture-video", client: client)

        sut.seed(bootstrap)

        #expect(sut.isAvailable)
        #expect(!sut.isExpanded)
        #expect(sut.activity == .idle)
        #expect(client.loadAskConversationCallCount == 0)

        sut.setExpanded(true)
        await self.waitUntil(client.loadAskConversationCallCount == 1 && sut.activity == .idle)

        #expect(sut.isExpanded)
        #expect(sut.messages.isEmpty)
        #expect(sut.suggestions.map(\.text) == ["Explain the main idea"])
        #expect(client.continueAskConversationCallCount == 0)
    }

    @Test("Dismissing and reopening preserves the prepared conversation")
    func dismissalPreservesPreparedConversation() async {
        let client = MockYouTubeClient()
        let sut = YouTubeAskViewModel(videoID: "fixture-video", client: client)
        sut.seed(YouTubeAskBootstrap.testing(suggestions: ["Explain the main idea"]))

        sut.setExpanded(true)
        await self.waitUntil(sut.activity == .idle && !sut.suggestions.isEmpty)

        sut.setExpanded(false)
        #expect(!sut.isExpanded)
        #expect(sut.suggestions.map(\.text) == ["Explain the main idea"])

        sut.setExpanded(true)
        await Task.yield()

        #expect(sut.isExpanded)
        #expect(client.loadAskConversationCallCount == 1)
        #expect(sut.suggestions.map(\.text) == ["Explain the main idea"])
    }

    @Test("Free text is single-flight and re-enables after successful responses")
    func freeTextSubmissionSupportsMultipleTurns() async {
        let client = MockYouTubeClient()
        let sut = YouTubeAskViewModel(videoID: "fixture-video", client: client)
        sut.seed(YouTubeAskBootstrap.testing(
            suggestions: ["Explain the main idea"],
            allowsFreeText: true
        ))
        sut.setExpanded(true)
        await self.waitUntil(sut.activity == .idle && sut.acceptsFreeTextInput)

        sut.inputText = String(repeating: "a", count: 16001)
        #expect(!sut.canSubmitInput)
        let oversizedUTF8 = String(repeating: "🇺🇸", count: 9000)
        #expect(oversizedUTF8.count <= 16000)
        #expect(oversizedUTF8.utf8.count > 64 * 1024)
        sut.inputText = oversizedUTF8
        #expect(!sut.canSubmitInput)
        sut.inputText = ""

        client.continuedAskConversation = YouTubeAskConversation.testing(
            messages: [
                YouTubeAskMessage(role: .user, text: "What is this video about?"),
                YouTubeAskMessage(role: .assistant, text: "A fixture answer."),
            ],
            suggestions: ["Ask a follow-up"],
            allowsFreeText: true
        )
        let gate = AsyncGate()
        client.beforeAskContinuationReturn = {
            await gate.wait()
        }
        sut.inputText = "  What is this video about?  "

        sut.submitInput(playerOffsetMilliseconds: 234_000)
        await self.waitUntil(client.continueAskFreeTextCallCount == 1)

        #expect(sut.activity == .sending)
        #expect(sut.inputText.isEmpty)
        #expect(sut.messages.map(\.text) == ["What is this video about?"])
        #expect(client.submittedAskFreeTextInputs == ["What is this video about?"])
        #expect(client.submittedAskPlayerOffsets == [234_000])

        sut.inputText = "Ignored second prompt"
        sut.submitInput(playerOffsetMilliseconds: 0)
        await Task.yield()
        #expect(client.continueAskFreeTextCallCount == 1)

        await gate.open()
        await self.waitUntil(sut.activity == .idle && sut.messages.count == 2)

        #expect(sut.messages.map(\.text) == [
            "What is this video about?",
            "A fixture answer.",
        ])
        #expect(sut.acceptsFreeTextInput)
        #expect(sut.canStartNewChat)
        #expect(sut.accessibilityAnnouncement == .responseReady)

        client.continuedAskConversation = YouTubeAskConversation.testing(
            messages: [
                YouTubeAskMessage(role: .user, text: "What is this video about?"),
                YouTubeAskMessage(role: .assistant, text: "A fixture answer."),
                YouTubeAskMessage(role: .user, text: "What should I know next?"),
                YouTubeAskMessage(role: .assistant, text: "A second fixture answer."),
            ],
            suggestions: ["Another follow-up"],
            allowsFreeText: true
        )
        sut.inputText = "What should I know next?"
        sut.submitInput(playerOffsetMilliseconds: 235_000)
        await self.waitUntil(
            sut.activity == .idle
                && client.continueAskFreeTextCallCount == 2
                && sut.messages.count == 4
        )

        #expect(client.submittedAskFreeTextInputs == [
            "What is this video about?",
            "What should I know next?",
        ])
        #expect(client.submittedAskPlayerOffsets == [234_000, 235_000])
        #expect(sut.acceptsFreeTextInput)
        #expect(sut.suggestions.map(\.text) == ["Another follow-up"])
    }

    @Test("Suggestion selection publishes the user turn, stays single-flight, and preserves server order")
    func selectionIsSingleFlightAndOrdered() async throws {
        let client = MockYouTubeClient()
        let bootstrap = YouTubeAskBootstrap.testing(suggestions: ["Explain this"])
        let sut = YouTubeAskViewModel(videoID: "fixture-video", client: client)
        sut.seed(bootstrap)
        sut.setExpanded(true)
        await self.waitUntil(sut.activity == .idle && !sut.suggestions.isEmpty)

        client.continuedAskConversation = YouTubeAskConversation.testing(
            messages: [
                YouTubeAskMessage(role: .user, text: "Explain this"),
                YouTubeAskMessage(role: .assistant, text: "First assistant message"),
                YouTubeAskMessage(role: .assistant, text: "Second assistant message"),
            ],
            suggestions: ["First follow-up", "Second follow-up"]
        )
        let gate = AsyncGate()
        client.beforeAskContinuationReturn = {
            await gate.wait()
        }

        let suggestion = try #require(sut.suggestions.first)
        sut.selectSuggestion(id: suggestion.id)
        await self.waitUntil(client.continueAskConversationCallCount == 1)

        #expect(sut.activity == .sending)
        #expect(sut.messages.map(\.text) == ["Explain this"])
        if let firstMessage = sut.messages.first {
            if case .user = firstMessage.role {
                // Expected visible optimistic user turn.
            } else {
                Issue.record("The optimistic turn must be a user message")
            }
        }

        sut.selectSuggestion(id: suggestion.id)
        await Task.yield()
        #expect(client.continueAskConversationCallCount == 1)

        await gate.open()
        await self.waitUntil(sut.activity == .idle && sut.messages.count == 3)

        #expect(sut.messages.map(\.text) == [
            "Explain this",
            "First assistant message",
            "Second assistant message",
        ])
        #expect(sut.suggestions.map(\.text) == ["First follow-up", "Second follow-up"])
        #expect(sut.accessibilityAnnouncement == .responseReady)
    }

    @Test("Submission failure consumes the session and requires New Chat")
    func submissionFailureRequiresNewChat() async throws {
        let client = MockYouTubeClient()
        let sut = YouTubeAskViewModel(videoID: "fixture-video", client: client)
        sut.seed(YouTubeAskBootstrap.testing(suggestions: ["Summarize this"]))
        sut.setExpanded(true)
        await self.waitUntil(sut.activity == .idle && !sut.suggestions.isEmpty)

        client.askError = YouTubeAskClientError.rateLimited
        let suggestion = try #require(sut.suggestions.first)
        sut.selectSuggestion(id: suggestion.id)
        await self.waitUntil(sut.activity == .idle && sut.requiresNewChat)

        #expect(sut.messages.map(\.text) == ["Summarize this"])
        #expect(sut.suggestions.isEmpty)
        #expect(sut.presentationError == .rateLimited)
        #expect(sut.canStartNewChat)

        sut.selectSuggestion(id: suggestion.id)
        await Task.yield()
        #expect(client.continueAskConversationCallCount == 1)
    }

    @Test("New Chat keeps the old conversation on failure and swaps only after preparation succeeds")
    func newChatIsTransactional() async throws {
        let client = MockYouTubeClient()
        let sut = YouTubeAskViewModel(videoID: "fixture-video", client: client)
        sut.seed(YouTubeAskBootstrap.testing(suggestions: ["Initial question"]))
        sut.setExpanded(true)
        await self.waitUntil(sut.activity == .idle && !sut.suggestions.isEmpty)

        client.continuedAskConversation = YouTubeAskConversation.testing(
            messages: [
                YouTubeAskMessage(role: .user, text: "Initial question"),
                YouTubeAskMessage(role: .assistant, text: "Initial answer"),
            ],
            suggestions: ["Continue old chat"]
        )
        let initialSuggestion = try #require(sut.suggestions.first)
        sut.selectSuggestion(id: initialSuggestion.id)
        await self.waitUntil(sut.activity == .idle && sut.hasStarted)

        let oldMessages = sut.messages.map(\.text)
        let oldSuggestions = sut.suggestions.map(\.text)
        let freshBootstrap = YouTubeAskBootstrap.testing(suggestions: ["Fresh question"])
        client.watchPages = [YouTubeWatchPage(data: .empty, askBootstrap: freshBootstrap)]
        client.askError = YouTubeAskClientError.unavailable

        sut.startNewChat()
        await self.waitUntil(sut.activity == .idle && client.getWatchPageCallCount == 1)

        #expect(sut.messages.map(\.text) == oldMessages)
        #expect(sut.suggestions.map(\.text) == oldSuggestions)
        #expect(sut.presentationError == .preparation)
        #expect(!sut.requiresNewChat)

        client.askError = nil
        client.askConversation = YouTubeAskConversation.testing(suggestions: ["Fresh question"])
        client.watchPages = [YouTubeWatchPage(data: .empty, askBootstrap: freshBootstrap)]

        sut.startNewChat()
        await self.waitUntil(
            sut.activity == .idle
                && client.getWatchPageCallCount == 2
                && sut.suggestions.map(\.text) == ["Fresh question"]
        )

        #expect(sut.messages.isEmpty)
        #expect(!sut.requiresNewChat)
        #expect(sut.presentationError == nil)
        #expect(sut.accessibilityAnnouncement == .newChatReady)
    }

    @Test("Dismissing during New Chat keeps the prepared replacement hidden")
    func dismissalDuringNewChatPreservesVisibilityIntent() async throws {
        let client = MockYouTubeClient()
        let sut = YouTubeAskViewModel(videoID: "fixture-video", client: client)
        sut.seed(YouTubeAskBootstrap.testing(suggestions: ["Initial question"]))
        sut.setExpanded(true)
        await self.waitUntil(sut.activity == .idle && !sut.suggestions.isEmpty)

        client.continuedAskConversation = YouTubeAskConversation.testing(
            messages: [
                YouTubeAskMessage(role: .user, text: "Initial question"),
                YouTubeAskMessage(role: .assistant, text: "Initial answer"),
            ],
            suggestions: ["Continue"]
        )
        let initialSuggestion = try #require(sut.suggestions.first)
        sut.selectSuggestion(id: initialSuggestion.id)
        await self.waitUntil(sut.activity == .idle && sut.hasStarted)

        let gate = AsyncGate()
        client.watchPages = [YouTubeWatchPage(
            data: .empty,
            askBootstrap: YouTubeAskBootstrap.testing(suggestions: ["Fresh question"])
        )]
        client.askConversation = YouTubeAskConversation.testing(suggestions: ["Fresh question"])
        client.beforeAskPreparationReturn = {
            await gate.wait()
        }

        sut.startNewChat()
        await self.waitUntil(sut.activity == .preparing && client.loadAskConversationCallCount == 2)
        sut.setExpanded(false)

        await gate.open()
        await self.waitUntil(sut.activity == .idle && sut.suggestions.map(\.text) == ["Fresh question"])

        #expect(!sut.isExpanded)
        #expect(sut.presentationError == nil)
        #expect(sut.accessibilityAnnouncement == .newChatReady)
    }

    @Test("A repeated watch task preserves the active conversation")
    func repeatedWatchTaskPreservesConversation() async throws {
        let client = MockYouTubeClient()
        client.askBootstrap = YouTubeAskBootstrap.testing(suggestions: ["Explain this video"])
        let video = MockYouTubeClient.makeVideo(videoId: "fixture-video")
        let sut = YouTubeWatchViewModel(video: video, client: client)

        await sut.load()
        sut.ask.setExpanded(true)
        await self.waitUntil(sut.ask.activity == .idle && !sut.ask.suggestions.isEmpty)

        client.continuedAskConversation = YouTubeAskConversation.testing(
            messages: [
                YouTubeAskMessage(role: .user, text: "Explain this video"),
                YouTubeAskMessage(role: .assistant, text: "Fixture answer"),
            ],
            suggestions: ["Continue"]
        )
        let suggestion = try #require(sut.ask.suggestions.first)
        sut.ask.selectSuggestion(id: suggestion.id)
        await self.waitUntil(sut.ask.activity == .idle && sut.ask.hasStarted)

        await sut.load()

        #expect(client.getWatchPageCallCount == 1)
        #expect(sut.ask.messages.map(\.text) == ["Explain this video", "Fixture answer"])
        #expect(sut.ask.suggestions.map(\.text) == ["Continue"])
    }

    @Test("A restarted watch task coalesces the pending initial comment load")
    func restartedWatchTaskResumesInitialComments() async {
        let client = MockYouTubeClient()
        let commentsGate = AsyncGate()
        client.watchNextData = WatchNextData(
            videoTitle: "Fixture title",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            commentsContinuation: "fixture-comments"
        )
        client.askBootstrap = YouTubeAskBootstrap.testing(suggestions: ["Explain this video"])
        client.commentsPage = YouTubeCommentsPage(
            comments: [
                YouTubeComment(
                    id: "fixture-comment",
                    author: "Fixture author",
                    authorAvatarURL: nil,
                    text: "Fixture comment",
                    publishedText: nil,
                    likeCountText: nil
                ),
            ],
            continuation: "fixture-comments-page-2",
            createCommentParams: nil
        )
        client.beforeCommentsReturn = { _ in
            await commentsGate.wait()
        }
        let video = MockYouTubeClient.makeVideo(videoId: "fixture-video")
        let sut = YouTubeWatchViewModel(video: video, client: client)
        let accountScope = self.accountScope(sequence: 1)

        let initialTask = Task {
            await sut.load(accountScope: accountScope)
        }
        await self.waitUntil(sut.loadingState == .loaded && client.getCommentsCallCount == 1)

        sut.ask.setExpanded(true)
        await self.waitUntil(sut.ask.activity == .idle && !sut.ask.suggestions.isEmpty)
        initialTask.cancel()
        let restartedTask = Task {
            await sut.load(accountScope: accountScope)
        }
        await Task.yield()

        #expect(client.getWatchPageCallCount == 1)
        #expect(client.getCommentsCallCount == 1)
        #expect(sut.data.videoTitle == "Fixture title")
        #expect(sut.ask.suggestions.map(\.text) == ["Explain this video"])

        await commentsGate.open()
        await initialTask.value
        await restartedTask.value
        await sut.load(accountScope: accountScope)

        #expect(client.getWatchPageCallCount == 1)
        #expect(client.getCommentsCallCount == 1)
        #expect(sut.comments.map(\.id) == ["fixture-comment"])
        #expect(sut.canLoadMoreComments)
        #expect(sut.data.videoTitle == "Fixture title")
        #expect(sut.ask.suggestions.map(\.text) == ["Explain this video"])
    }

    @Test("A repeated watch task does not paginate beyond the initial comments page")
    func repeatedWatchTaskDoesNotPaginateComments() async {
        let client = MockYouTubeClient()
        client.watchNextData = WatchNextData(
            videoTitle: "Fixture title",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [],
            commentsContinuation: "fixture-initial-comments"
        )
        client.commentsPage = YouTubeCommentsPage(
            comments: [
                YouTubeComment(
                    id: "fixture-initial-comment",
                    author: "Fixture author",
                    authorAvatarURL: nil,
                    text: "Initial comment",
                    publishedText: nil,
                    likeCountText: nil
                ),
            ],
            continuation: "fixture-next-comments",
            createCommentParams: nil
        )
        let video = MockYouTubeClient.makeVideo(videoId: "fixture-video")
        let sut = YouTubeWatchViewModel(video: video, client: client)

        await sut.load()
        await sut.load()

        #expect(client.getWatchPageCallCount == 1)
        #expect(client.getCommentsCallCount == 1)
        #expect(sut.comments.map(\.id) == ["fixture-initial-comment"])
        #expect(sut.canLoadMoreComments)

        client.commentsPage = YouTubeCommentsPage(
            comments: [
                YouTubeComment(
                    id: "fixture-next-comment",
                    author: "Fixture author",
                    authorAvatarURL: nil,
                    text: "Next comment",
                    publishedText: nil,
                    likeCountText: nil
                ),
            ],
            continuation: nil,
            createCommentParams: nil
        )
        await sut.loadMoreComments()

        #expect(client.getCommentsCallCount == 2)
        #expect(sut.comments.map(\.id) == ["fixture-initial-comment", "fixture-next-comment"])
    }

    @Test("An internal identity cancellation retries the read-only watch page once")
    func internalIdentityCancellationRetriesWatchPage() async {
        let client = MockYouTubeClient()
        client.watchPageErrors = [CancellationError()]
        client.watchPages = [YouTubeWatchPage(
            data: .empty,
            askBootstrap: YouTubeAskBootstrap.testing(suggestions: ["Recovered question"])
        )]
        let video = MockYouTubeClient.makeVideo(videoId: "fixture-video")
        let sut = YouTubeWatchViewModel(video: video, client: client)

        await sut.load(accountScope: self.accountScope(sequence: 1))

        #expect(client.getWatchPageCallCount == 2)
        #expect(sut.loadingState == .loaded)
        #expect(sut.ask.isAvailable)

        sut.ask.setExpanded(true)
        await self.waitUntil(sut.ask.activity == .idle && !sut.ask.suggestions.isEmpty)
        #expect(sut.ask.suggestions.map(\.text) == ["Recovered question"])
    }

    @Test("A cancelled outer watch task does not retry")
    func cancelledOuterWatchTaskDoesNotRetry() async {
        let client = MockYouTubeClient()
        let gate = AsyncGate()
        client.beforeWatchPageReturn = {
            await gate.wait()
        }
        let video = MockYouTubeClient.makeVideo(videoId: "fixture-video")
        let sut = YouTubeWatchViewModel(video: video, client: client)
        let loadTask = Task {
            await sut.load(accountScope: self.accountScope(sequence: 1))
        }
        await self.waitUntil(client.getWatchPageCallCount == 1)

        loadTask.cancel()
        await gate.open()
        await loadTask.value

        #expect(client.getWatchPageCallCount == 1)
        #expect(sut.loadingState == .idle)
        #expect(!sut.ask.isAvailable)
    }

    @Test("Returning to the same watch route reloads discarded Ask state")
    func cancelThenReloadRestoresAskAvailability() async {
        let client = MockYouTubeClient()
        client.watchPages = [
            YouTubeWatchPage(
                data: .empty,
                askBootstrap: YouTubeAskBootstrap.testing(suggestions: ["Initial question"])
            ),
            YouTubeWatchPage(
                data: .empty,
                askBootstrap: YouTubeAskBootstrap.testing(suggestions: ["Fresh question"])
            ),
        ]
        let video = MockYouTubeClient.makeVideo(videoId: "fixture-video")
        let sut = YouTubeWatchViewModel(video: video, client: client)
        let accountScope = self.accountScope(sequence: 1)

        await sut.load(accountScope: accountScope)
        #expect(sut.ask.isAvailable)

        sut.cancel()
        #expect(!sut.ask.isAvailable)
        #expect(sut.loadingState == .idle)

        await sut.load(accountScope: accountScope)

        #expect(client.getWatchPageCallCount == 2)
        #expect(sut.ask.isAvailable)
        #expect(!sut.ask.isExpanded)

        sut.ask.setExpanded(true)
        await self.waitUntil(sut.ask.activity == .idle && !sut.ask.suggestions.isEmpty)
        #expect(sut.ask.suggestions.map(\.text) == ["Fresh question"])
    }

    @Test("A verified primary account refreshes Ask without reusing unresolved state")
    func verifiedAccountRefreshesAskAvailability() async {
        let client = MockYouTubeClient()
        client.commentsPage = YouTubeCommentsPage(
            comments: [
                YouTubeComment(
                    id: "fixture-old-comment",
                    author: "Fixture author",
                    authorAvatarURL: nil,
                    text: "Old account comment",
                    publishedText: nil,
                    likeCountText: nil
                ),
            ],
            continuation: nil,
            createCommentParams: "fixture-old-comment-params"
        )
        client.watchPages = [
            YouTubeWatchPage(
                data: WatchNextData(
                    videoTitle: "Old account title",
                    viewCountText: nil,
                    publishedText: nil,
                    channel: nil,
                    related: [],
                    isSubscribed: true,
                    commentsContinuation: "fixture-old-comments"
                ),
                askBootstrap: nil
            ),
            YouTubeWatchPage(
                data: WatchNextData(
                    videoTitle: "Verified account title",
                    viewCountText: nil,
                    publishedText: nil,
                    channel: nil,
                    related: [],
                    isSubscribed: false,
                    commentsContinuation: nil
                ),
                askBootstrap: YouTubeAskBootstrap.testing(suggestions: ["Verified question"])
            ),
        ]
        let video = MockYouTubeClient.makeVideo(videoId: "fixture-video")
        let sut = YouTubeWatchViewModel(video: video, client: client)

        await sut.load(accountScope: self.accountScope(
            sequence: 0,
            hasPersonalAccount: false,
            accountScopeID: nil,
            isPrimaryAccount: nil
        ))
        #expect(!sut.ask.isAvailable)
        #expect(sut.isSubscribed)
        #expect(sut.comments.map(\.id) == ["fixture-old-comment"])
        #expect(sut.canComment)

        client.commentsPage = .empty
        await sut.load(accountScope: self.accountScope(sequence: 1))

        #expect(client.getWatchPageCallCount == 2)
        #expect(sut.data.videoTitle == "Verified account title")
        #expect(!sut.isSubscribed)
        #expect(sut.comments.isEmpty)
        #expect(!sut.canComment)
        #expect(sut.ask.isAvailable)
        #expect(!sut.ask.isExpanded)
    }

    @Test("A stale account refresh cannot replace the latest Ask bootstrap")
    func staleAccountRefreshIsDiscarded() async {
        let client = MockYouTubeClient()
        client.watchPages = [YouTubeWatchPage(data: .empty, askBootstrap: nil)]
        let video = MockYouTubeClient.makeVideo(videoId: "fixture-video")
        let sut = YouTubeWatchViewModel(video: video, client: client)

        await sut.load(accountScope: self.accountScope(sequence: 0))

        let gate = AsyncGate()
        client.beforeWatchPageReturnByCallCount = { callCount in
            if callCount == 2 {
                await gate.wait()
            }
        }
        client.askBootstrap = YouTubeAskBootstrap.testing(suggestions: ["Stale question"])

        let staleRefresh = Task {
            await sut.load(accountScope: self.accountScope(sequence: 1))
        }
        await self.waitUntil(client.getWatchPageCallCount == 2)

        client.watchPages = [YouTubeWatchPage(
            data: .empty,
            askBootstrap: YouTubeAskBootstrap.testing(suggestions: ["Latest question"])
        )]
        await sut.load(accountScope: self.accountScope(sequence: 2))

        await gate.open()
        await staleRefresh.value

        #expect(client.getWatchPageCallCount == 3)
        #expect(sut.ask.isAvailable)
        sut.ask.setExpanded(true)
        await self.waitUntil(sut.ask.activity == .idle && !sut.ask.suggestions.isEmpty)
        #expect(sut.ask.suggestions.map(\.text) == ["Latest question"])
    }

    @Test("Lifecycle cancellation discards state and rejects late preparation")
    func cancellationDiscardsState() async {
        let client = MockYouTubeClient()
        let gate = AsyncGate()
        client.beforeAskPreparationReturn = {
            await gate.wait()
        }
        let sut = YouTubeAskViewModel(videoID: "fixture-video", client: client)
        sut.seed(YouTubeAskBootstrap.testing(suggestions: ["Explain this"]))
        sut.setExpanded(true)
        await self.waitUntil(client.loadAskConversationCallCount == 1)

        sut.cancelAndDiscard()
        await gate.open()
        await Task.yield()
        await Task.yield()

        #expect(!sut.isAvailable)
        #expect(!sut.isExpanded)
        #expect(sut.activity == .idle)
        #expect(sut.conversation == nil)
        #expect(sut.messages.isEmpty)
        #expect(sut.suggestions.isEmpty)
    }

    @Test("Watch load seeds an available but hidden Ask panel")
    func watchViewModelSeedsAskFromWatchPage() async {
        let client = MockYouTubeClient()
        client.watchNextData = WatchNextData(
            videoTitle: "Fixture title",
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: []
        )
        client.askBootstrap = YouTubeAskBootstrap.testing(suggestions: ["Explain this video"])
        let video = MockYouTubeClient.makeVideo(videoId: "fixture-video")
        let sut = YouTubeWatchViewModel(video: video, client: client)

        await sut.load()

        #expect(client.getWatchPageCallCount == 1)
        #expect(client.getWatchNextCallCount == 0)
        #expect(sut.data.videoTitle == "Fixture title")
        #expect(sut.ask.isAvailable)
        #expect(!sut.ask.isExpanded)
        #expect(client.loadAskConversationCallCount == 0)

        sut.cancel()
        #expect(!sut.ask.isAvailable)
    }

    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
        timeout: Duration = .seconds(2)
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
        #expect(condition())
    }

    private func accountScope(
        sequence: Int,
        hasPersonalAccount: Bool = true,
        accountScopeID: String? = "fixture-primary-scope",
        isPrimaryAccount: Bool? = true
    ) -> YouTubeAskAccountScopeObservation {
        YouTubeAskAccountScopeObservation(
            authenticationGeneration: UInt64(sequence),
            hasPersonalAccount: hasPersonalAccount,
            accountScopeID: accountScopeID,
            isPrimaryAccount: isPrimaryAccount,
            verifiedIdentitySequence: sequence
        )
    }
}
