import Foundation

/// Parses YouTube comments continuation responses (`next` with the
/// comments section's continuation token).
///
/// Modern responses deliver comment data as `commentEntityPayload`
/// mutations in `frameworkUpdates`; older ones inline `commentRenderer`s.
/// Both are handled.
enum YouTubeCommentsParser {
    static func parse(_ data: [String: Any]) -> YouTubeCommentsPage {
        var comments = Self.commentsFromEntityPayloads(data)
        if comments.isEmpty {
            comments = Self.commentsFromLegacyRenderers(data)
        }

        return YouTubeCommentsPage(
            comments: comments,
            continuation: Self.nextPageToken(of: data),
            createCommentParams: Self.firstString(forKey: "createCommentParams", in: data)
        )
    }

    // MARK: - Entity Payloads (2024+ format)

    private static func commentsFromEntityPayloads(_ data: [String: Any]) -> [YouTubeComment] {
        let updates = data["frameworkUpdates"] as? [String: Any]
        let batch = updates?["entityBatchUpdate"] as? [String: Any]
        let mutations = batch?["mutations"] as? [[String: Any]] ?? []

        return mutations.compactMap { mutation in
            guard let payload = (mutation["payload"] as? [String: Any])?["commentEntityPayload"]
                as? [String: Any]
            else {
                return nil
            }
            return Self.comment(fromEntityPayload: payload)
        }
    }

    private static func comment(fromEntityPayload payload: [String: Any]) -> YouTubeComment? {
        let properties = payload["properties"] as? [String: Any]
        let author = payload["author"] as? [String: Any]

        guard let commentId = properties?["commentId"] as? String,
              let text = (properties?["content"] as? [String: Any])?["content"] as? String,
              let authorName = author?["displayName"] as? String
        else {
            return nil
        }

        let toolbar = payload["toolbar"] as? [String: Any]

        return YouTubeComment(
            id: commentId,
            author: authorName,
            authorAvatarURL: (author?["avatarThumbnailUrl"] as? String).flatMap(URL.init(string:)),
            text: text,
            publishedText: properties?["publishedTime"] as? String,
            likeCountText: toolbar?["likeCountNotliked"] as? String
        )
    }

    // MARK: - Legacy Renderers

    private static func commentsFromLegacyRenderers(_ data: [String: Any]) -> [YouTubeComment] {
        var comments: [YouTubeComment] = []
        Self.collectLegacy(in: data, into: &comments)
        return comments
    }

    private static func collectLegacy(in value: Any, into comments: inout [YouTubeComment]) {
        if let dict = value as? [String: Any] {
            if let renderer = dict["commentRenderer"] as? [String: Any] {
                if let comment = comment(fromLegacyRenderer: renderer) {
                    comments.append(comment)
                }
                return
            }
            for nested in dict.values {
                Self.collectLegacy(in: nested, into: &comments)
            }
        } else if let array = value as? [Any] {
            for element in array {
                Self.collectLegacy(in: element, into: &comments)
            }
        }
    }

    private static func comment(fromLegacyRenderer renderer: [String: Any]) -> YouTubeComment? {
        guard let commentId = renderer["commentId"] as? String,
              let text = YouTubeItemParser.text(from: renderer["contentText"]),
              let author = YouTubeItemParser.text(from: renderer["authorText"])
        else {
            return nil
        }

        return YouTubeComment(
            id: commentId,
            author: author,
            authorAvatarURL: YouTubeItemParser.thumbnailURL(fromThumbnail: renderer["authorThumbnail"]),
            text: text,
            publishedText: YouTubeItemParser.text(from: renderer["publishedTimeText"]),
            likeCountText: YouTubeItemParser.text(from: renderer["voteCount"])
        )
    }

    // MARK: - Continuation & Create Params

    /// The next comments page token: the last continuation among the
    /// appended items (reply continuations come earlier within threads).
    private static func nextPageToken(of data: [String: Any]) -> String? {
        let endpoints = data["onResponseReceivedEndpoints"] as? [[String: Any]]
            ?? data["onResponseReceivedActions"] as? [[String: Any]]
            ?? []

        var token: String?
        for endpoint in endpoints {
            let items = (endpoint["appendContinuationItemsAction"] as? [String: Any])?["continuationItems"]
                as? [[String: Any]]
                ?? (endpoint["reloadContinuationItemsCommand"] as? [String: Any])?["continuationItems"]
                as? [[String: Any]]
                ?? []
            for item in items {
                if let continuationItem = item["continuationItemRenderer"] as? [String: Any],
                   let found = YouTubeFeedParser.token(fromContinuationItem: continuationItem)
                {
                    token = found
                }
            }
        }
        return token
    }

    /// Depth-first search for a string value under the given key.
    static func firstString(forKey key: String, in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let match = dict[key] as? String {
                return match
            }
            for nested in dict.values {
                if let found = Self.firstString(forKey: key, in: nested) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let found = Self.firstString(forKey: key, in: element) {
                    return found
                }
            }
        }
        return nil
    }
}
