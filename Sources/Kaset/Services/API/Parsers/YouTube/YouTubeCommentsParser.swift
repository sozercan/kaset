import Foundation

/// Parses YouTube comments continuation responses (`next` with the
/// comments section's continuation token).
///
/// Modern responses deliver comment data as `commentEntityPayload`
/// mutations in `frameworkUpdates`; older ones inline `commentRenderer`s.
/// Both are handled.
enum YouTubeCommentsParser {
    /// Like/dislike action tokens from a comment's toolbar surface payload.
    private struct ToolbarSurface {
        let like: String?
        let unlike: String?
        let dislike: String?
        let undislike: String?
    }

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

        // Entity payloads are flat; the thread structure and ordering come
        // from the comment view models in the continuation items.
        var commentsByKey: [String: [String: Any]] = [:]
        var orderedPayloads: [[String: Any]] = []
        var surfacesByKey: [String: ToolbarSurface] = [:]

        for mutation in mutations {
            guard let payload = mutation["payload"] as? [String: Any] else { continue }
            let key = mutation["entityKey"] as? String
            if let comment = payload["commentEntityPayload"] as? [String: Any] {
                orderedPayloads.append(comment)
                if let key {
                    commentsByKey[key] = comment
                }
            }
            if let key,
               let surface = payload["engagementToolbarSurfaceEntityPayload"] as? [String: Any]
               ?? payload["commentSurfaceEntityPayload"] as? [String: Any]
            {
                surfacesByKey[key] = ToolbarSurface(
                    like: Self.actionToken(of: surface["likeCommand"]),
                    unlike: Self.actionToken(of: surface["unlikeCommand"]),
                    dislike: Self.actionToken(of: surface["dislikeCommand"]),
                    undislike: Self.actionToken(of: surface["undislikeCommand"])
                )
            }
        }

        // Preferred path: walk the view models for order, thread replies,
        // and the toolbar-surface linkage.
        var viewModels: [(vm: [String: Any], replies: String?)] = []
        Self.collectCommentViewModels(in: data, into: &viewModels)

        if !viewModels.isEmpty {
            return viewModels.compactMap { entry in
                guard let commentKey = entry.vm["commentKey"] as? String,
                      let payload = commentsByKey[commentKey],
                      var comment = Self.comment(fromEntityPayload: payload)
                else {
                    return nil
                }
                if let surfaceKey = entry.vm["toolbarSurfaceKey"] as? String,
                   let surface = surfacesByKey[surfaceKey]
                {
                    comment.likeAction = surface.like
                    comment.unlikeAction = surface.unlike
                    comment.dislikeAction = surface.dislike
                    comment.undislikeAction = surface.undislike
                }
                comment.repliesContinuation = entry.replies
                return comment
            }
        }

        // Fallback: mutation order without thread/action linkage.
        return orderedPayloads.compactMap { Self.comment(fromEntityPayload: $0) }
    }

    /// Extracts the `performCommentActionEndpoint.action` token from a
    /// toolbar command container.
    private static func actionToken(of command: Any?) -> String? {
        guard let command else { return nil }
        return Self.firstString(forKey: "action", in: command)
    }

    /// Collects comment view models in display order, with each thread's
    /// replies continuation. Handles top-level threads
    /// (`commentThreadRenderer`) and bare view models (reply pages).
    private static func collectCommentViewModels(
        in value: Any,
        into results: inout [(vm: [String: Any], replies: String?)]
    ) {
        if let dict = value as? [String: Any] {
            if let thread = dict["commentThreadRenderer"] as? [String: Any] {
                if let viewModel = innerCommentViewModel(of: thread["commentViewModel"]) {
                    let repliesToken = (thread["replies"] as? [String: Any])
                        .flatMap { Self.firstString(forKey: "token", in: $0) }
                    results.append((viewModel, repliesToken))
                }
                return
            }

            if let viewModel = Self.innerCommentViewModel(of: dict["commentViewModel"]) {
                results.append((viewModel, nil))
                return
            }

            for nested in dict.values {
                Self.collectCommentViewModels(in: nested, into: &results)
            }
        } else if let array = value as? [Any] {
            for element in array {
                Self.collectCommentViewModels(in: element, into: &results)
            }
        }
    }

    /// `commentViewModel` sometimes wraps another `commentViewModel` level.
    private static func innerCommentViewModel(of value: Any?) -> [String: Any]? {
        guard let dict = value as? [String: Any] else { return nil }
        if let inner = dict["commentViewModel"] as? [String: Any] {
            return inner["commentKey"] != nil ? inner : nil
        }
        return dict["commentKey"] != nil ? dict : nil
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
            likeCountText: toolbar?["likeCountNotliked"] as? String,
            authorChannelId: author?["channelId"] as? String
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
