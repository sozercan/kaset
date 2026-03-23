import Foundation

// MARK: - LikeStatus

/// Represents the like/dislike status of a song in YouTube Music.
enum LikeStatus: String, Codable, Sendable, Equatable {
    /// Song is liked (thumbs up).
    case like = "LIKE"

    /// Song is disliked (thumbs down).
    case dislike = "DISLIKE"

    /// Song has no rating (neutral).
    case indifferent = "INDIFFERENT"

    /// Whether the song is liked.
    var isLiked: Bool {
        self == .like
    }

    /// Whether the song is disliked.
    var isDisliked: Bool {
        self == .dislike
    }
}

// MARK: - FeedbackTokens

/// Tokens used for library add/remove operations.
/// These are obtained from song metadata in API responses.
struct FeedbackTokens: Codable, Hashable, Sendable {
    /// Token to add the song to library.
    let add: String?

    /// Token to remove the song from library.
    let remove: String?

    /// Returns the appropriate token for the desired action.
    func token(forAdding: Bool) -> String? {
        forAdding ? self.add : self.remove
    }
}
