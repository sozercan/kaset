import Foundation

enum LikeStatus: String, Codable, Equatable {
    case like = "LIKE"

    case dislike = "DISLIKE"

    case indifferent = "INDIFFERENT"

    var isLiked: Bool {
        self == .like
    }

    var isDisliked: Bool {
        self == .dislike
    }
}

struct FeedbackTokens: Codable, Hashable {
    let add: String?

    let remove: String?

    func token(forAdding: Bool) -> String? {
        forAdding ? self.add : self.remove
    }
}
