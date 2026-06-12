import Foundation
import Observation

/// View model for the YouTube watch page (metadata + related videos).
@MainActor
@Observable
final class YouTubeWatchViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// Watch-page companion data.
    private(set) var data: WatchNextData = .empty

    let video: YouTubeVideo
    /// Invalidates stale in-flight loads when a newer one starts
    /// (SwiftUI restarts .task during launch/layout churn; latest wins).
    private var loadGeneration = 0

    let client: any YouTubeClientProtocol
    private let logger = DiagnosticsLogger.api

    init(video: YouTubeVideo, client: any YouTubeClientProtocol) {
        self.video = video
        self.client = client
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

    func load() async {
        self.loadGeneration += 1
        let generation = self.loadGeneration
        self.loadingState = .loading
        do {
            let data = try await self.client.getWatchNext(videoId: self.video.videoId)
            guard generation == self.loadGeneration else { return }
            self.data = data
            self.isSubscribed = data.isSubscribed ?? false
            self.commentsContinuation = data.commentsContinuation
            self.loadingState = .loaded
            await self.loadMoreComments()
        } catch {
            guard generation == self.loadGeneration else { return }
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

    // MARK: - Comments

    /// Loads the next page of comments.
    func loadMoreComments() async {
        guard !self.isLoadingComments, let continuation = self.commentsContinuation else { return }

        self.isLoadingComments = true
        defer {
            self.isLoadingComments = false
        }
        do {
            let page = try await self.client.getComments(continuation: continuation)
            guard self.commentsContinuation == continuation else { return }
            let existing = Set(self.comments.map(\.id))
            self.comments.append(contentsOf: page.comments.filter { !existing.contains($0.id) })
            self.commentsContinuation = page.continuation
            if let params = page.createCommentParams {
                self.createCommentParams = params
            }
        } catch {
            if error is CancellationError { return }
            self.logger.error("Failed to load comments: \(error.localizedDescription)")
            self.commentsContinuation = nil
        }
    }

    /// Likes a comment (one-shot; YouTube's undo token isn't tracked).
    func likeComment(_ comment: YouTubeComment) async {
        guard let token = comment.likeActionToken,
              !self.likedComments.contains(comment.id)
        else {
            return
        }
        do {
            try await self.client.performCommentAction(token)
            self.likedComments.insert(comment.id)
            self.dislikedComments.remove(comment.id)
            HapticService.toggle()
        } catch {
            self.logger.error("Failed to like comment: \(error.localizedDescription)")
        }
    }

    /// Dislikes a comment (one-shot).
    func dislikeComment(_ comment: YouTubeComment) async {
        guard let token = comment.dislikeActionToken,
              !self.dislikedComments.contains(comment.id)
        else {
            return
        }
        do {
            try await self.client.performCommentAction(token)
            self.dislikedComments.insert(comment.id)
            self.likedComments.remove(comment.id)
            HapticService.toggle()
        } catch {
            self.logger.error("Failed to dislike comment: \(error.localizedDescription)")
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

        self.loadingReplies.insert(comment.id)
        defer {
            self.loadingReplies.remove(comment.id)
        }
        do {
            let page = try await self.client.getComments(continuation: continuation)
            // Reply pages can echo the parent; drop it.
            self.repliesByComment[comment.id] = page.comments.filter { $0.id != comment.id }
        } catch {
            if error is CancellationError { return }
            self.logger.error("Failed to load replies: \(error.localizedDescription)")
        }
    }

    /// Posts a top-level comment; returns true on success.
    func postComment(text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let params = self.createCommentParams, !self.isPostingComment else {
            return false
        }

        self.isPostingComment = true
        defer {
            self.isPostingComment = false
        }
        do {
            try await self.client.postComment(text: trimmed, createCommentParams: params)
            HapticService.success()
            return true
        } catch {
            self.logger.error("Failed to post comment: \(error.localizedDescription)")
            HapticService.error()
            return false
        }
    }

    // MARK: - Actions

    /// Subscribes/unsubscribes the channel (optimistic with rollback).
    func toggleSubscribed() async {
        guard let channel = self.data.channel else { return }
        let wasSubscribed = self.isSubscribed
        self.isSubscribed = !wasSubscribed
        do {
            try await self.client.setSubscribed(self.isSubscribed, channelId: channel.channelId)
            HapticService.toggle()
        } catch {
            self.logger.error("Failed to change subscription: \(error.localizedDescription)")
            self.isSubscribed = wasSubscribed
        }
    }
}
