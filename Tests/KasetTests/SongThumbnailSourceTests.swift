import Foundation
import Testing
@testable import Kaset

// MARK: - SongThumbnailSourceTests

@Suite(.tags(.model))
struct SongThumbnailSourceTests {
    @Test("uses primary URL until that exact primary source fails")
    func usesPrimaryUntilMatchingFailure() throws {
        let primaryURL = try #require(URL(string: "https://example.com/thumbnail.jpg"))
        let fallbackURL = try #require(URL(string: "https://i.ytimg.com/vi/abc123/hqdefault.jpg"))
        let source = SongThumbnailSource(videoId: "abc123", primaryURL: primaryURL, fallbackURL: fallbackURL)

        #expect(source.activeURL(failedPrimaryKey: nil) == primaryURL)
        #expect(source.activeURL(failedPrimaryKey: source.primaryFailureKey) == fallbackURL)
    }

    @Test("same song retries primary when the primary URL changes")
    func newPrimaryURLIgnoresPreviousFailure() throws {
        let oldPrimaryURL = try #require(URL(string: "https://example.com/old.jpg"))
        let newPrimaryURL = try #require(URL(string: "https://example.com/new.jpg"))
        let fallbackURL = try #require(URL(string: "https://i.ytimg.com/vi/abc123/hqdefault.jpg"))
        let oldSource = SongThumbnailSource(videoId: "abc123", primaryURL: oldPrimaryURL, fallbackURL: fallbackURL)
        let newSource = SongThumbnailSource(videoId: "abc123", primaryURL: newPrimaryURL, fallbackURL: fallbackURL)

        #expect(newSource.activeURL(failedPrimaryKey: oldSource.primaryFailureKey) == newPrimaryURL)
    }

    @Test("fallback only activates when there is a distinct fallback URL")
    func fallbackRequiresDistinctFallbackURL() throws {
        let fallbackURL = try #require(URL(string: "https://i.ytimg.com/vi/abc123/hqdefault.jpg"))

        #expect(
            SongThumbnailSource(videoId: "abc123", primaryURL: nil, fallbackURL: fallbackURL).primaryFailureKey == nil
        )
        #expect(
            SongThumbnailSource(videoId: "abc123", primaryURL: fallbackURL, fallbackURL: fallbackURL)
                .primaryFailureKey == nil
        )
        #expect(
            SongThumbnailSource(videoId: "abc123", primaryURL: fallbackURL, fallbackURL: nil)
                .primaryFailureKey == nil
        )
    }
}
