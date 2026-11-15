import Foundation

/// Rules for the comment reply field's draft: the mention it starts with,
/// whether it holds something to post, and how it follows the field when the
/// field moves to another comment.
enum CommentReplyDraft {
    /// What the field starts with for `comment`: YouTube's mention of its
    /// author ("@author ") when it is itself a reply, otherwise nothing.
    static func prefill(for comment: YouTubeComment?) -> String {
        guard let mention = comment?.replyMention else { return "" }
        return mention + " "
    }

    /// Whether `draft` holds more than the mention it started with.
    static func canPost(_ draft: String, replyingTo comment: YouTubeComment?) -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let mention = Self.prefill(for: comment).trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text != mention
    }

    /// Whether nothing was typed beyond the prefilled mention.
    static func isUntouched(_ draft: String, replyingTo comment: YouTubeComment?) -> Bool {
        let prefill = Self.prefill(for: comment)
        return draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft == prefill
    }

    /// The draft once the field moves from `old` to `new`. Typed text is kept
    /// and the old comment's mention is swapped for the new one's; text with
    /// no mention gains the new one. A mention the user edited is left alone.
    static func moving(_ draft: String, from old: YouTubeComment?, to new: YouTubeComment) -> String {
        let oldPrefill = Self.prefill(for: old)
        let newPrefill = Self.prefill(for: new)
        if Self.isUntouched(draft, replyingTo: old) {
            return newPrefill
        }
        if !newPrefill.isEmpty, draft.hasPrefix(newPrefill) {
            return draft
        }
        if oldPrefill.isEmpty {
            return newPrefill + draft
        }
        if draft.hasPrefix(oldPrefill) {
            return newPrefill + draft.dropFirst(oldPrefill.count)
        }
        return draft
    }
}
