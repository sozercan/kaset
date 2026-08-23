import Foundation
import Observation

// MARK: - YouTubeAskAccountScopeObservation

/// In-memory observation key for watch-page account changes. The raw scope is
/// never persisted or rendered; it only restarts the Ask bootstrap request.
struct YouTubeAskAccountScopeObservation: Hashable, Sendable {
    let authenticationGeneration: UInt64
    let hasPersonalAccount: Bool
    let accountScopeID: String?
    let isPrimaryAccount: Bool?
    let verifiedIdentitySequence: Int
}

// MARK: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable

extension YouTubeAskAccountScopeObservation: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "<redacted YouTube Ask account scope>"
    }

    var debugDescription: String {
        self.description
    }

    var customMirror: Mirror {
        Mirror(reflecting: self.description)
    }
}

// MARK: - YouTubeWatchViewModel

/// View model for the YouTube watch page (metadata + related videos).
@MainActor
@Observable
final class YouTubeWatchViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Watch-page companion data.
    private(set) var data: WatchNextData = .empty

    /// Watch-scoped Ask Gemini state. The child owns all of its request tasks
    /// and opaque conversation state.
    let ask: YouTubeAskViewModel

    let video: YouTubeVideo
    /// Invalidates stale in-flight loads when a newer one starts
    /// (SwiftUI restarts .task during launch/layout churn; latest wins).
    private var loadGeneration = 0
    private var lastAskAccountScope: YouTubeAskAccountScopeObservation?

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(video: YouTubeVideo, client: any YouTubeClientProtocol) {
        self.video = video
        self.client = client
        self.ask = YouTubeAskViewModel(videoID: video.videoId, client: client)
    }

    // MARK: - Action State (optimistic)

    // Like/dislike and Watch Later live on YouTubePlayerService so the
    // player bar (inline and pop-out) owns them.

    /// Whether the user is subscribed to the channel (seeded from watch-next).
    private(set) var isSubscribed = false

    // MARK: - Comments State

    /// Loaded comments (top-level threads).
    private(set) var comments: [YouTubeComment] = []

    /// Whether comments are currently loading.
    private(set) var isLoadingComments = false

    /// Token for the next comments page.
    private var commentsContinuation: String?
    private var commentsGeneration = 0

    /// The single in-flight comments page, shared by concurrent callers so a
    /// SwiftUI watch-task restart adopts the initial request instead of
    /// cancelling it with the outer task or issuing a duplicate request.
    private var commentsLoadTask: Task<CommentsLoadOutcome, Never>?

    /// Distinguishes watch initialization from explicit comment pagination.
    /// Once the first page reaches a terminal result, repeated watch-task runs
    /// preserve loaded watch/Ask state without automatically fetching page two.
    private var didCompleteInitialCommentsLoad = false

    /// Params for posting a comment (nil = signed out / disabled).
    private(set) var createCommentParams: String?

    /// Whether a comment is currently being posted.
    private(set) var isPostingComment = false

    var canLoadMoreComments: Bool {
        self.commentsContinuation != nil
    }

    var canComment: Bool {
        self.createCommentParams != nil
    }

    /// Comments the user liked/disliked this session (display state only —
    /// undo tokens aren't tracked, so actions are one-shot).
    private(set) var likedComments: Set<String> = []
    private(set) var dislikedComments: Set<String> = []

    /// Loaded reply threads by parent comment ID.
    private(set) var repliesByComment: [String: [YouTubeComment]] = [:]

    /// Parent comments whose replies are currently loading.
    private(set) var loadingReplies: Set<String> = []

    func load(accountScope: YouTubeAskAccountScopeObservation? = nil) async {
        let accountScopeChanged: Bool
        if let accountScope {
            accountScopeChanged = self.lastAskAccountScope.map { $0 != accountScope } ?? false
            self.lastAskAccountScope = accountScope
        } else {
            accountScopeChanged = false
        }

        if accountScopeChanged {
            self.resetAccountScopedWatchState()
        }

        if self.loadingState == .loaded {
            await self.loadInitialCommentsIfNeeded()
            return
        }
        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.ask.cancelAndDiscard()
        self.loadingState = .loading
        do {
            let page = try await self.loadWatchPageWithIdentityRetry(generation: generation)
            guard generation == self.loadGeneration else { return }
            self.data = page.data
            self.isSubscribed = page.data.isSubscribed ?? false
            self.commentsContinuation = page.data.commentsContinuation
            self.didCompleteInitialCommentsLoad = false
            self.ask.seed(page.askBootstrap)
            self.loadingState = .loaded
            await self.loadInitialCommentsIfNeeded()
        } catch {
            guard generation == self.loadGeneration else { return }
            self.ask.cancelAndDiscard()
            // A cancelled load (view went away mid-flight) is not an
            // error; reset so the next task run reloads.
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load watch-next data: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// A scope publication can reset the shared client after a watch response
    /// parses but before its final identity fence. Retry that read-only `next`
    /// request once when the outer route task and load generation are still
    /// current. Panel materialization and suggestion submission are never retried.
    private func loadWatchPageWithIdentityRetry(
        generation: Int
    ) async throws -> YouTubeWatchPage {
        do {
            return try await self.client.getWatchPage(videoId: self.video.videoId)
        } catch is CancellationError {
            guard !Task.isCancelled, generation == self.loadGeneration else {
                throw CancellationError()
            }
            await Task.yield()
            guard !Task.isCancelled, generation == self.loadGeneration else {
                throw CancellationError()
            }
            return try await self.client.getWatchPage(videoId: self.video.videoId)
        }
    }

    /// Invalidates the current route load and discards all Ask state.
    func cancel() {
        self.loadGeneration += 1
        self.commentsLoadTask?.cancel()
        self.commentsLoadTask = nil
        self.commentsGeneration += 1
        self.didCompleteInitialCommentsLoad = false
        self.isLoadingComments = false
        self.isPostingComment = false
        self.commentsContinuation = nil
        self.loadingReplies = []
        self.ask.cancelAndDiscard()
        self.loadingState = .idle
    }

    private func resetAccountScopedWatchState() {
        self.loadGeneration += 1
        self.commentsLoadTask?.cancel()
        self.commentsLoadTask = nil
        self.commentsGeneration += 1
        self.didCompleteInitialCommentsLoad = false
        self.data = .empty
        self.ask.cancelAndDiscard()
        self.isSubscribed = false
        self.comments = []
        self.isLoadingComments = false
        self.commentsContinuation = nil
        self.createCommentParams = nil
        self.isPostingComment = false
        self.likedComments = []
        self.dislikedComments = []
        self.repliesByComment = [:]
        self.loadingReplies = []
        self.loadingState = .idle
    }

    // MARK: - Comments

    private enum CommentsLoadOutcome {
        case completed
        case cancelled
        case unavailable
    }

    /// Loads the first comments page once for watch initialization. A restarted
    /// outer `.task` coalesces onto the stored page request, while later task
    /// runs remain no-ops after that first page reaches a terminal result.
    private func loadInitialCommentsIfNeeded() async {
        guard !self.didCompleteInitialCommentsLoad else { return }
        _ = await self.loadCommentsPage()
    }

    /// Loads the next page of comments.
    func loadMoreComments() async {
        _ = await self.loadCommentsPage()
    }

    /// Coalesces every caller for the current comments page onto one
    /// unstructured task. The task survives cancellation of an awaiting SwiftUI
    /// `.task`; only an explicit route/account reset cancels it.
    private func loadCommentsPage() async -> CommentsLoadOutcome {
        if let existing = self.commentsLoadTask {
            return await existing.value
        }
        guard let continuation = self.commentsContinuation else {
            self.didCompleteInitialCommentsLoad = true
            return .unavailable
        }

        let generation = self.commentsGeneration
        let marksInitialCompletion = !self.didCompleteInitialCommentsLoad
        let task = Task {
            await self.performCommentsLoad(
                continuation: continuation,
                generation: generation,
                marksInitialCompletion: marksInitialCompletion
            )
        }
        self.commentsLoadTask = task
        return await task.value
    }

    private func performCommentsLoad(
        continuation: String,
        generation: Int,
        marksInitialCompletion: Bool
    ) async -> CommentsLoadOutcome {
        defer {
            if generation == self.commentsGeneration {
                self.commentsLoadTask = nil
                self.isLoadingComments = false
            }
        }
        guard generation == self.commentsGeneration, !Task.isCancelled else {
            return .cancelled
        }
        self.isLoadingComments = true
        do {
            let page = try await self.client.getComments(continuation: continuation)
            guard generation == self.commentsGeneration,
                  self.commentsContinuation == continuation
            else { return .cancelled }
            let existing = Set(self.comments.map(\.id))
            self.comments.append(contentsOf: page.comments.filter { !existing.contains($0.id) })
            self.commentsContinuation = page.continuation
            if let params = page.createCommentParams {
                self.createCommentParams = params
            }
            if marksInitialCompletion {
                self.didCompleteInitialCommentsLoad = true
            }
            return .completed
        } catch {
            if error is CancellationError {
                return .cancelled
            }
            guard generation == self.commentsGeneration else { return .cancelled }
            self.logger.error("Failed to load comments: \(error.localizedDescription)")
            self.commentsContinuation = nil
            if marksInitialCompletion {
                self.didCompleteInitialCommentsLoad = true
            }
            return .completed
        }
    }

    /// Toggles a like on a comment (likes, or removes an existing like).
    func likeComment(_ comment: YouTubeComment) async {
        let isLiked = self.likedComments.contains(comment.id)
        guard let action = isLiked ? comment.unlikeAction : comment.likeAction else {
            return
        }
        let generation = self.commentsGeneration
        do {
            try await self.client.performCommentAction(action)
            guard generation == self.commentsGeneration else { return }
            if isLiked {
                self.likedComments.remove(comment.id)
            } else {
                self.likedComments.insert(comment.id)
                self.dislikedComments.remove(comment.id)
            }
            HapticService.toggle()
        } catch {
            guard generation == self.commentsGeneration else { return }
            self.logger.error("Failed to toggle comment like: \(error.localizedDescription)")
        }
    }

    /// Toggles a dislike on a comment (dislikes, or removes an existing one).
    func dislikeComment(_ comment: YouTubeComment) async {
        let isDisliked = self.dislikedComments.contains(comment.id)
        guard let action = isDisliked ? comment.undislikeAction : comment.dislikeAction else {
            return
        }
        let generation = self.commentsGeneration
        do {
            try await self.client.performCommentAction(action)
            guard generation == self.commentsGeneration else { return }
            if isDisliked {
                self.dislikedComments.remove(comment.id)
            } else {
                self.dislikedComments.insert(comment.id)
                self.likedComments.remove(comment.id)
            }
            HapticService.toggle()
        } catch {
            guard generation == self.commentsGeneration else { return }
            self.logger.error("Failed to toggle comment dislike: \(error.localizedDescription)")
        }
    }

    /// Loads a comment's reply thread.
    func loadReplies(for comment: YouTubeComment) async {
        guard let continuation = comment.repliesContinuation,
              self.repliesByComment[comment.id] == nil,
              !self.loadingReplies.contains(comment.id)
        else {
            return
        }

        let generation = self.commentsGeneration
        self.loadingReplies.insert(comment.id)
        defer {
            if generation == self.commentsGeneration {
                self.loadingReplies.remove(comment.id)
            }
        }
        do {
            let page = try await self.client.getComments(continuation: continuation)
            guard generation == self.commentsGeneration else { return }
            // Reply pages can echo the parent; drop it.
            self.repliesByComment[comment.id] = page.comments.filter { $0.id != comment.id }
        } catch {
            if error is CancellationError {
                return
            }
            guard generation == self.commentsGeneration else { return }
            self.logger.error("Failed to load replies: \(error.localizedDescription)")
        }
    }

    /// Posts a top-level comment; returns true on success.
    func postComment(text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let params = self.createCommentParams, !self.isPostingComment else {
            return false
        }

        let generation = self.commentsGeneration
        self.isPostingComment = true
        defer {
            if generation == self.commentsGeneration {
                self.isPostingComment = false
            }
        }
        do {
            try await self.client.postComment(text: trimmed, createCommentParams: params)
            guard generation == self.commentsGeneration else { return false }
            HapticService.success()
            return true
        } catch {
            guard generation == self.commentsGeneration else { return false }
            self.logger.error("Failed to post comment: \(error.localizedDescription)")
            HapticService.error()
            return false
        }
    }

    // MARK: - Actions

    /// Subscribes/unsubscribes the channel (optimistic with rollback).
    func toggleSubscribed() async {
        guard let channel = self.data.channel else { return }
        let generation = self.loadGeneration
        let wasSubscribed = self.isSubscribed
        self.isSubscribed = !wasSubscribed
        do {
            try await self.client.setSubscribed(self.isSubscribed, channelId: channel.channelId)
            guard generation == self.loadGeneration else { return }
            HapticService.toggle()
        } catch {
            guard generation == self.loadGeneration else { return }
            self.logger.error("Failed to change subscription: \(error.localizedDescription)")
            self.isSubscribed = wasSubscribed
        }
    }
}
