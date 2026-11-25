import Foundation
import Observation

struct YouTubeAskAccountScopeObservation: Hashable, Sendable {
    let authenticationGeneration: UInt64
    let hasPersonalAccount: Bool
    let accountScopeID: String?
    let isPrimaryAccount: Bool?
    let verifiedIdentitySequence: Int
}

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

@MainActor
@Observable
final class YouTubeWatchViewModel {
    private(set) var loadingState: LoadingState = .idle

    private(set) var data: WatchNextData = .empty

    let ask: YouTubeAskViewModel

    let video: YouTubeVideo
    private var loadGeneration = 0
    private var lastAskAccountScope: YouTubeAskAccountScopeObservation?

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(video: YouTubeVideo, client: any YouTubeClientProtocol) {
        self.video = video
        self.client = client
        self.ask = YouTubeAskViewModel(videoID: video.videoId, client: client)
    }

    private(set) var isSubscribed = false

    private(set) var comments: [YouTubeComment] = []

    private(set) var isLoadingComments = false

    private var commentsContinuation: String?
    private var commentsGeneration = 0

    private var commentsLoadTask: Task<CommentsLoadOutcome, Never>?

    private var didCompleteInitialCommentsLoad = false

    private(set) var createCommentParams: String?

    private(set) var isPostingComment = false

    var canLoadMoreComments: Bool {
        self.commentsContinuation != nil
    }

    var canComment: Bool {
        self.createCommentParams != nil
    }

    private(set) var likedComments: Set<String> = []
    private(set) var dislikedComments: Set<String> = []

    private(set) var repliesByComment: [String: [YouTubeComment]] = [:]

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
            if error is CancellationError {
                self.loadingState = .idle
                return
            }
            self.logger.error("Failed to load watch-next data: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

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

    private enum CommentsLoadOutcome {
        case completed
        case cancelled
        case unavailable
    }

    private func loadInitialCommentsIfNeeded() async {
        guard !self.didCompleteInitialCommentsLoad else { return }
        _ = await self.loadCommentsPage()
    }

    func loadMoreComments() async {
        _ = await self.loadCommentsPage()
    }

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
            self.repliesByComment[comment.id] = page.comments.filter { $0.id != comment.id }
        } catch {
            if error is CancellationError {
                return
            }
            guard generation == self.commentsGeneration else { return }
            self.logger.error("Failed to load replies: \(error.localizedDescription)")
        }
    }

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
