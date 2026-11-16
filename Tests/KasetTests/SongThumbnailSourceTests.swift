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

    @Test("a failed sharp artwork steps down to the standard thumbnail before the fallback")
    func failedSharpArtworkTriesStandardBeforeFallback() throws {
        let sharpURL = try #require(URL(string: "https://lh3.googleusercontent.com/abc=w1200-h1200-l90-rj"))
        let standardURL = try #require(URL(string: "https://lh3.googleusercontent.com/abc=w226-h226-l90-rj"))
        let fallbackURL = try #require(URL(string: "https://i.ytimg.com/vi/abc123/hqdefault.jpg"))
        func source(failedSharpURL: URL?) -> SongThumbnailSource {
            SongThumbnailSource(
                videoId: "abc123",
                primaryURL: SongThumbnailSource.primaryURL(
                    sharpURL: sharpURL,
                    standardURL: standardURL,
                    failedSharpURL: failedSharpURL
                ),
                fallbackURL: fallbackURL
            )
        }

        #expect(source(failedSharpURL: nil).activeURL(failedPrimaryKey: nil) == sharpURL)

        let afterSharpFailure = source(failedSharpURL: sharpURL)
        #expect(afterSharpFailure.activeURL(failedPrimaryKey: nil) == standardURL)
        #expect(afterSharpFailure.activeURL(failedPrimaryKey: afterSharpFailure.primaryFailureKey) == fallbackURL)
    }

    @Test("a sharp artwork failure does not carry over to another artwork")
    func sharpFailureIsPerURL() throws {
        let failedURL = try #require(URL(string: "https://lh3.googleusercontent.com/old=w1200-h1200-l90-rj"))
        let sharpURL = try #require(URL(string: "https://lh3.googleusercontent.com/new=w1200-h1200-l90-rj"))
        let standardURL = try #require(URL(string: "https://lh3.googleusercontent.com/new=w226-h226-l90-rj"))

        #expect(
            SongThumbnailSource.primaryURL(sharpURL: sharpURL, standardURL: standardURL, failedSharpURL: failedURL) == sharpURL
        )
        #expect(
            SongThumbnailSource.primaryURL(sharpURL: nil, standardURL: standardURL, failedSharpURL: nil) == standardURL
        )
    }
}
