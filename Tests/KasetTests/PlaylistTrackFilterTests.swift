import Foundation
import Testing
@testable import Kaset

@Suite("Playlist track filter")
struct PlaylistTrackFilterTests {
    private func makeTracks() -> [Song] {
        [
            TestFixtures.makeSong(id: "a", title: "Alpha", artistName: "One"),
            TestFixtures.makeSong(id: "b", title: "Target Beta", artistName: "Two"),
            TestFixtures.makeSong(id: "c", title: "Gamma", artistName: "Three"),
            TestFixtures.makeSong(id: "d", title: "Delta", artistName: "Target Four"),
            TestFixtures.makeSong(id: "e", title: "Epsilon", artistName: "Five"),
        ]
    }

    @Test("Blank query returns every track with sequential indices")
    func blankQueryReturnsAll() {
        let tracks = self.makeTracks()
        let result = PlaylistTrackFilter.filter(tracks, query: "")

        #expect(result.map(\.index) == [0, 1, 2, 3, 4])
        #expect(result.map(\.track.videoId) == ["a", "b", "c", "d", "e"])
    }

    @Test("Whitespace-only query is treated as blank and hides nothing")
    func whitespaceQueryReturnsAll() {
        let tracks = self.makeTracks()
        let result = PlaylistTrackFilter.filter(tracks, query: "   \n ")

        #expect(result.count == tracks.count)
    }

    @Test("Filtering preserves each match's ORIGINAL playlist index")
    func filterPreservesOriginalIndex() {
        // The index is what playback uses: a match at playlist position 1 and 3 must report
        // 1 and 3, not 0 and 1 — otherwise playing a filtered row would start the queue at
        // the wrong track. This is the core "plays in playlist context" guarantee.
        let tracks = self.makeTracks()
        let result = PlaylistTrackFilter.filter(tracks, query: "target")

        #expect(result.map(\.index) == [1, 3])
        #expect(result.map(\.track.videoId) == ["b", "d"])
    }

    @Test("Title match is case-insensitive")
    func titleMatchIsCaseInsensitive() {
        let tracks = self.makeTracks()
        let result = PlaylistTrackFilter.filter(tracks, query: "ALPHA")

        #expect(result.map(\.track.videoId) == ["a"])
    }

    @Test("Artist name is matched, not only the title")
    func artistNameIsMatched() {
        let tracks = [
            TestFixtures.makeSong(id: "1", title: "Holy Diver", artistName: "Dio"),
            TestFixtures.makeSong(id: "2", title: "Rainbow", artistName: "Ronnie"),
        ]
        let result = PlaylistTrackFilter.filter(tracks, query: "dio")

        // Track 1 matches via the artist name "Dio" — its title "Holy Diver" does NOT contain
        // the substring "dio" — proving artist names are searched, not only titles.
        #expect(result.map(\.track.videoId) == ["1"])
    }

    @Test("Matching ignores diacritics in both query and content")
    func matchingIsDiacriticInsensitive() {
        let tracks = [
            TestFixtures.makeSong(id: "1", title: "Jóga", artistName: "Björk"),
            TestFixtures.makeSong(id: "2", title: "Naïve", artistName: "The Kooks"),
        ]

        #expect(PlaylistTrackFilter.filter(tracks, query: "bjork").map(\.track.videoId) == ["1"])
        #expect(PlaylistTrackFilter.filter(tracks, query: "naive").map(\.track.videoId) == ["2"])
    }

    @Test("A query matching nothing returns an empty result")
    func noMatchReturnsEmpty() {
        let tracks = self.makeTracks()
        let result = PlaylistTrackFilter.filter(tracks, query: "zzz-nonexistent")

        #expect(result.isEmpty)
    }

    @Test("matches() reports true for an empty normalized query")
    func matchesTreatsEmptyQueryAsWildcard() {
        let track = TestFixtures.makeSong(id: "x", title: "Anything", artistName: "Anyone")

        #expect(PlaylistTrackFilter.matches(track, normalizedQuery: ""))
    }

    @Test("Surrounding whitespace in the query is trimmed before matching")
    func queryWhitespaceIsTrimmed() {
        let tracks = self.makeTracks()
        let result = PlaylistTrackFilter.filter(tracks, query: "  alpha  ")

        #expect(result.map(\.track.videoId) == ["a"])
    }

    @Test("normalize() reduces a whitespace-only query to empty")
    func normalizeReducesWhitespaceQueryToEmpty() {
        // The view gates its eager full-playlist load on this: a whitespace-only entry must
        // normalize to empty so it never triggers a fetch.
        #expect(PlaylistTrackFilter.normalize("   \n\t ").isEmpty)
        #expect(!PlaylistTrackFilter.normalize("  x ").isEmpty)
    }
}
