import Foundation
import Testing
@testable import Kaset

// MARK: - ArtworkViewerSourceTests

@Suite(.tags(.model))
struct ArtworkViewerSourceTests {
    @Test("falls back to the public video thumbnail when the primary artwork fails")
    func fallsBackAfterPrimaryFailure() throws {
        let primaryURL = try #require(URL(string: "https://lh3.googleusercontent.com/abc=w544-h544-l90-rj"))
        let fallbackURL = try #require(URL(string: "https://i.ytimg.com/vi/abc123/hqdefault.jpg"))
        let source = ArtworkViewerSource(primaryURL: primaryURL, fallbackURL: fallbackURL)

        #expect(source.activeURL(didFailPrimary: false) == primaryURL)
        #expect(source.activeURL(didFailPrimary: true) == fallbackURL)
    }

    @Test("keeps the primary URL when no distinct fallback exists")
    func keepsPrimaryWithoutDistinctFallback() throws {
        let primaryURL = try #require(URL(string: "https://i.ytimg.com/vi/abc123/hqdefault.jpg"))
        let source = ArtworkViewerSource(primaryURL: primaryURL, fallbackURL: primaryURL)

        #expect(source.retryableFallbackURL == nil)
        #expect(source.activeURL(didFailPrimary: true) == primaryURL)
    }

    @Test("uses the fallback when the API supplies no artwork")
    func usesFallbackWithoutPrimary() throws {
        let fallbackURL = try #require(URL(string: "https://i.ytimg.com/vi/abc123/hqdefault.jpg"))
        let source = ArtworkViewerSource(primaryURL: nil, fallbackURL: fallbackURL)

        #expect(source.hasArtwork)
        #expect(source.activeURL(didFailPrimary: false) == fallbackURL)
    }

    @Test("reports no artwork when both sources are missing")
    func reportsMissingArtwork() {
        let source = ArtworkViewerSource(primaryURL: nil, fallbackURL: nil)

        #expect(!source.hasArtwork)
        #expect(source.activeURL(didFailPrimary: false) == nil)
        #expect(source.activeURL(didFailPrimary: true) == nil)
    }
}
