import Foundation
import Testing
@testable import Kaset

@Suite("CommentReplyDraft")
struct CommentReplyDraftTests {
    private static let parent = Self.comment(id: "p1", mention: nil)
    private static let alice = Self.comment(id: "r1", mention: "@alice")
    private static let bob = Self.comment(id: "r2", mention: "@bob")

    @Test("A reply to a reply starts with its author's mention; a top-level one starts empty")
    func prefill() {
        #expect(CommentReplyDraft.prefill(for: Self.alice) == "@alice ")
        #expect(CommentReplyDraft.prefill(for: Self.parent).isEmpty)
        #expect(CommentReplyDraft.prefill(for: nil).isEmpty)
    }

    @Test("Only text beyond the mention can be posted")
    func canPost() {
        #expect(!CommentReplyDraft.canPost("", replyingTo: Self.parent))
        #expect(!CommentReplyDraft.canPost("   ", replyingTo: Self.parent))
        #expect(!CommentReplyDraft.canPost("@alice ", replyingTo: Self.alice))
        #expect(!CommentReplyDraft.canPost("@alice", replyingTo: Self.alice))
        #expect(CommentReplyDraft.canPost("@alice hi", replyingTo: Self.alice))
        #expect(CommentReplyDraft.canPost("hi", replyingTo: Self.parent))
    }

    @Test("Moving an untouched field swaps in the new mention")
    func movingUntouched() {
        #expect(CommentReplyDraft.moving("@alice ", from: Self.alice, to: Self.bob) == "@bob ")
        #expect(CommentReplyDraft.moving("", from: Self.parent, to: Self.bob) == "@bob ")
        #expect(CommentReplyDraft.moving("@alice ", from: Self.alice, to: Self.parent).isEmpty)
    }

    @Test("Moving keeps typed text and swaps only the mention")
    func movingKeepsTypedText() {
        #expect(
            CommentReplyDraft.moving("@alice great point", from: Self.alice, to: Self.bob)
                == "@bob great point"
        )
        #expect(CommentReplyDraft.moving("great point", from: Self.parent, to: Self.bob) == "@bob great point")
        #expect(CommentReplyDraft.moving("@alice great point", from: Self.alice, to: Self.parent) == "great point")
    }

    @Test("Moving leaves an edited or already matching mention alone")
    func movingLeavesEditedMention() {
        #expect(CommentReplyDraft.moving("@al great point", from: Self.alice, to: Self.bob) == "@al great point")
        #expect(CommentReplyDraft.moving("@bob great point", from: Self.parent, to: Self.bob) == "@bob great point")
    }

    private static func comment(id: String, mention: String?) -> YouTubeComment {
        YouTubeComment(
            id: id,
            author: mention ?? "@parent",
            authorAvatarURL: nil,
            text: "Text",
            publishedText: nil,
            likeCountText: nil,
            replyParams: "params-\(id)",
            replyMention: mention
        )
    }
}
