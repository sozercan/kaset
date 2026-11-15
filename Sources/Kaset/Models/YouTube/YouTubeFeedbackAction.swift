import Foundation

// MARK: - YouTubeFeedbackAction

/// A recommendation-feedback entry from a video's overflow menu, such as
/// "Not interested" or "Don't recommend channel".
///
/// YouTube issues these per video in feed responses. Sending
/// `feedbackToken` to the `feedback` endpoint records the choice on the
/// account, and `undoToken` reverses it. The display strings come from
/// YouTube already localized for the account's language, so Kaset shows
/// them as-is instead of carrying its own translations.
struct YouTubeFeedbackAction: Hashable {
    enum Kind: Hashable {
        /// Hide this video and recommend fewer like it.
        case notInterested
        /// Stop recommending videos from this video's channel.
        case dontRecommendChannel
    }

    let kind: Kind
    /// Menu title, e.g. "Not interested".
    let title: String
    let feedbackToken: String
    /// Token that reverses this feedback, when YouTube offers an undo.
    let undoToken: String?
    /// Confirmation shown after sending, e.g. "Video removed".
    let confirmationText: String?
    /// Label for the undo button, e.g. "Undo".
    let undoTitle: String?

    /// SF Symbol for the context-menu entry.
    var systemImage: String {
        switch self.kind {
        case .notInterested:
            "eye.slash"
        case .dontRecommendChannel:
            "person.crop.circle.badge.minus"
        }
    }
}
