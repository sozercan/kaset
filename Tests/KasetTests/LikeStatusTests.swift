import Foundation
import Testing
@testable import Kaset

/// Unit tests for LikeStatus and FeedbackTokens.
@Suite("LikeStatus and FeedbackTokens")
struct LikeStatusTests {
    // MARK: - LikeStatus Tests

    @Test("Raw values are correct")
    func likeStatusRawValues() {
        #expect(LikeStatus.like.rawValue == "LIKE")
        #expect(LikeStatus.dislike.rawValue == "DISLIKE")
        #expect(LikeStatus.indifferent.rawValue == "INDIFFERENT")
    }

    @Test("isLiked returns true only for .like")
    func likeStatusIsLiked() {
        #expect(LikeStatus.like.isLiked)
        #expect(!LikeStatus.dislike.isLiked)
        #expect(!LikeStatus.indifferent.isLiked)
    }

    @Test("isDisliked returns true only for .dislike")
    func likeStatusIsDisliked() {
        #expect(!LikeStatus.like.isDisliked)
        #expect(LikeStatus.dislike.isDisliked)
        #expect(!LikeStatus.indifferent.isDisliked)
    }

    @Test("Encoding and decoding preserves value", arguments: [LikeStatus.like, .dislike, .indifferent])
    func likeStatusEncodingDecoding(status: LikeStatus) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(status)
        let decoded = try decoder.decode(LikeStatus.self, from: data)
        #expect(status == decoded)
    }

    @Test("Decodes from raw value strings", arguments: [
        ("\"LIKE\"", LikeStatus.like),
        ("\"DISLIKE\"", LikeStatus.dislike),
        ("\"INDIFFERENT\"", LikeStatus.indifferent),
    ])
    func likeStatusDecodingFromRawValue(jsonString: String, expected: LikeStatus) throws {
        let decoder = JSONDecoder()
        let data = Data(jsonString.utf8)
        let decoded = try decoder.decode(LikeStatus.self, from: data)
        #expect(decoded == expected)
    }

    @Test("Equality comparison works correctly")
    func likeStatusEquality() {
        #expect(LikeStatus.like == LikeStatus.like)
        #expect(LikeStatus.like != LikeStatus.dislike)
        #expect(LikeStatus.like != LikeStatus.indifferent)
        #expect(LikeStatus.dislike != LikeStatus.indifferent)
    }

    // MARK: - FeedbackTokens Tests

    @Test("Initialization stores tokens correctly")
    func feedbackTokensInitialization() {
        let tokens = FeedbackTokens(add: "add_token_123", remove: "remove_token_456")
        #expect(tokens.add == "add_token_123")
        #expect(tokens.remove == "remove_token_456")
    }

    @Test("Handles nil values correctly")
    func feedbackTokensWithNilValues() {
        let tokensNilAdd = FeedbackTokens(add: nil, remove: "remove_token")
        #expect(tokensNilAdd.add == nil)
        #expect(tokensNilAdd.remove == "remove_token")

        let tokensNilRemove = FeedbackTokens(add: "add_token", remove: nil)
        #expect(tokensNilRemove.add == "add_token")
        #expect(tokensNilRemove.remove == nil)

        let tokensAllNil = FeedbackTokens(add: nil, remove: nil)
        #expect(tokensAllNil.add == nil)
        #expect(tokensAllNil.remove == nil)
    }

    @Test("token(forAdding:) returns correct token")
    func feedbackTokensTokenForAdding() {
        let tokens = FeedbackTokens(add: "add_token", remove: "remove_token")

        #expect(tokens.token(forAdding: true) == "add_token")
        #expect(tokens.token(forAdding: false) == "remove_token")
    }

    @Test("token(forAdding:) handles nil values")
    func feedbackTokensTokenForAddingWithNilValues() {
        let tokensNilAdd = FeedbackTokens(add: nil, remove: "remove_token")
        #expect(tokensNilAdd.token(forAdding: true) == nil)
        #expect(tokensNilAdd.token(forAdding: false) == "remove_token")

        let tokensNilRemove = FeedbackTokens(add: "add_token", remove: nil)
        #expect(tokensNilRemove.token(forAdding: true) == "add_token")
        #expect(tokensNilRemove.token(forAdding: false) == nil)
    }

    @Test("Encoding and decoding preserves FeedbackTokens")
    func feedbackTokensEncodingDecoding() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let tokens = FeedbackTokens(add: "add_token_123", remove: "remove_token_456")
        let data = try encoder.encode(tokens)
        let decoded = try decoder.decode(FeedbackTokens.self, from: data)

        #expect(tokens.add == decoded.add)
        #expect(tokens.remove == decoded.remove)
    }

    @Test("Equality comparison works correctly for FeedbackTokens")
    func feedbackTokensEquality() {
        let tokens1 = FeedbackTokens(add: "add", remove: "remove")
        let tokens2 = FeedbackTokens(add: "add", remove: "remove")
        let tokens3 = FeedbackTokens(add: "different", remove: "remove")

        #expect(tokens1 == tokens2)
        #expect(tokens1 != tokens3)
    }

    @Test("FeedbackTokens is Hashable")
    func feedbackTokensHashable() {
        let tokens1 = FeedbackTokens(add: "add", remove: "remove")
        let tokens2 = FeedbackTokens(add: "add", remove: "remove")

        var set = Set<FeedbackTokens>()
        set.insert(tokens1)
        set.insert(tokens2)

        #expect(set.count == 1)
    }
}
