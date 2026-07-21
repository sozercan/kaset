import Foundation
import Testing
@testable import Kaset

/// Tests for normalizing WebView-reported artist bylines.
@Suite(.tags(.service))
@MainActor
struct PlayerServiceArtistNameTests {
    @Test("Strips a trailing view-count segment")
    func stripsViewCount() {
        #expect(PlayerService.normalizedWebArtistName("Artist • 1.3M views") == "Artist")
        #expect(PlayerService.normalizedWebArtistName("Artist • 1 view") == "Artist")
    }

    @Test("Leaves a plain artist name unchanged")
    func plainNameUnchanged() {
        #expect(PlayerService.normalizedWebArtistName("Artist") == "Artist")
    }

    @Test("Keeps non-view-count segments")
    func keepsOtherSegments() {
        #expect(PlayerService.normalizedWebArtistName("Song • Artist • 1.2M views") == "Song • Artist")
        #expect(PlayerService.normalizedWebArtistName("Artist • Topic") == "Artist • Topic")
    }

    @Test("Trims surrounding whitespace")
    func trimsWhitespace() {
        #expect(PlayerService.normalizedWebArtistName("  Artist • 500 views  ") == "Artist")
    }

    @Test("Falls back to the raw string when every segment is a view count")
    func viewCountOnlyFallsBack() {
        // Nothing safe to keep — return the trimmed input rather than an empty name.
        #expect(PlayerService.normalizedWebArtistName("1.3M views") == "1.3M views")
    }
}
