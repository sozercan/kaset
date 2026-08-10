import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.viewModel))
struct PlaylistTrackListPresenterTests {
    private func makeSong(
        title: String,
        artist: String,
        videoId: String,
        duration: TimeInterval? = nil,
        albumTitle: String? = nil
    ) -> Song {
        Song(
            id: videoId,
            title: title,
            artists: artist.isEmpty ? [] : [Artist.inline(name: artist, namespace: "test")],
            album: albumTitle.map {
                Album(id: "al-\($0)", title: $0, artists: nil, thumbnailURL: nil, year: nil, trackCount: nil)
            },
            duration: duration,
            thumbnailURL: nil,
            videoId: videoId
        )
    }

    // MARK: - Model

    @Test("Default sort order is original ascending")
    func defaultSortOrder() {
        let order = PlaylistSortOrder.default
        #expect(order.key == .original)
        #expect(order.ascending == true)
    }

    @Test("All sort keys expose a non-empty display name")
    func sortKeyDisplayNames() {
        for key in PlaylistSortKey.allCases {
            #expect(!key.displayName.isEmpty)
        }
    }

    // MARK: - Sorting

    @Test("Original order returns tracks unchanged")
    func originalOrderUnchanged() {
        let songs = [
            self.makeSong(title: "Zulu", artist: "B", videoId: "1"),
            self.makeSong(title: "Alpha", artist: "A", videoId: "2"),
        ]
        let result = PlaylistTrackListPresenter.displayedTracks(
            from: songs, sortOrder: .default, searchQuery: ""
        )
        #expect(result.map(\.videoId) == ["1", "2"])
    }

    @Test("Title ascending sorts case- and diacritic-insensitively")
    func titleAscending() {
        let songs = [
            self.makeSong(title: "banana", artist: "x", videoId: "1"),
            self.makeSong(title: "Ápple", artist: "x", videoId: "2"),
            self.makeSong(title: "Cherry", artist: "x", videoId: "3"),
        ]
        let result = PlaylistTrackListPresenter.displayedTracks(
            from: songs,
            sortOrder: PlaylistSortOrder(key: .title, ascending: true),
            searchQuery: ""
        )
        #expect(result.map(\.videoId) == ["2", "1", "3"])
    }

    @Test("Title descending reverses the comparable order")
    func titleDescending() {
        let songs = [
            self.makeSong(title: "banana", artist: "x", videoId: "1"),
            self.makeSong(title: "Ápple", artist: "x", videoId: "2"),
            self.makeSong(title: "Cherry", artist: "x", videoId: "3"),
        ]
        let result = PlaylistTrackListPresenter.displayedTracks(
            from: songs,
            sortOrder: PlaylistSortOrder(key: .title, ascending: false),
            searchQuery: ""
        )
        #expect(result.map(\.videoId) == ["3", "1", "2"])
    }

    @Test("Duration sorts nils last in both directions")
    func durationNilsLast() {
        let songs = [
            self.makeSong(title: "a", artist: "x", videoId: "1", duration: 200),
            self.makeSong(title: "b", artist: "x", videoId: "2", duration: nil),
            self.makeSong(title: "c", artist: "x", videoId: "3", duration: 100),
        ]
        let asc = PlaylistTrackListPresenter.displayedTracks(
            from: songs, sortOrder: PlaylistSortOrder(key: .duration, ascending: true), searchQuery: ""
        )
        #expect(asc.map(\.videoId) == ["3", "1", "2"])
        let desc = PlaylistTrackListPresenter.displayedTracks(
            from: songs, sortOrder: PlaylistSortOrder(key: .duration, ascending: false), searchQuery: ""
        )
        #expect(desc.map(\.videoId) == ["1", "3", "2"])
    }

    @Test("Album sorts nils last")
    func albumNilsLast() {
        let songs = [
            self.makeSong(title: "a", artist: "x", videoId: "1", albumTitle: "Bravo"),
            self.makeSong(title: "b", artist: "x", videoId: "2", albumTitle: nil),
            self.makeSong(title: "c", artist: "x", videoId: "3", albumTitle: "Alpha"),
        ]
        let asc = PlaylistTrackListPresenter.displayedTracks(
            from: songs, sortOrder: PlaylistSortOrder(key: .album, ascending: true), searchQuery: ""
        )
        #expect(asc.map(\.videoId) == ["3", "1", "2"])
    }

    @Test("Sort is stable on ties")
    func stableOnTies() {
        let songs = [
            self.makeSong(title: "same", artist: "x", videoId: "1"),
            self.makeSong(title: "same", artist: "x", videoId: "2"),
            self.makeSong(title: "same", artist: "x", videoId: "3"),
        ]
        let result = PlaylistTrackListPresenter.displayedTracks(
            from: songs, sortOrder: PlaylistSortOrder(key: .title, ascending: true), searchQuery: ""
        )
        #expect(result.map(\.videoId) == ["1", "2", "3"])
    }

    // MARK: - Search

    @Test("Search matches title or artist, diacritic-insensitive")
    func searchMatches() {
        let songs = [
            self.makeSong(title: "Hello World", artist: "Adele", videoId: "1"),
            self.makeSong(title: "Something", artist: "Beyoncé", videoId: "2"),
            self.makeSong(title: "Other", artist: "Nobody", videoId: "3"),
        ]
        let byTitle = PlaylistTrackListPresenter.displayedTracks(
            from: songs, sortOrder: .default, searchQuery: "hello"
        )
        #expect(byTitle.map(\.videoId) == ["1"])
        let byArtist = PlaylistTrackListPresenter.displayedTracks(
            from: songs, sortOrder: .default, searchQuery: "beyonce"
        )
        #expect(byArtist.map(\.videoId) == ["2"])
    }

    @Test("Empty and whitespace query returns all tracks")
    func emptyQueryReturnsAll() {
        let songs = [
            self.makeSong(title: "a", artist: "x", videoId: "1"),
            self.makeSong(title: "b", artist: "y", videoId: "2"),
        ]
        #expect(
            PlaylistTrackListPresenter.displayedTracks(from: songs, sortOrder: .default, searchQuery: "   ").count == 2
        )
    }

    @Test("No matches returns empty")
    func noMatches() {
        let songs = [self.makeSong(title: "a", artist: "x", videoId: "1")]
        #expect(
            PlaylistTrackListPresenter.displayedTracks(from: songs, sortOrder: .default, searchQuery: "zzz").isEmpty
        )
    }

    @Test("Filter then sort: search narrows, sort orders the survivors")
    func filterThenSort() {
        let songs = [
            self.makeSong(title: "rock ballad", artist: "x", videoId: "1"),
            self.makeSong(title: "pop anthem", artist: "x", videoId: "2"),
            self.makeSong(title: "rock anthem", artist: "x", videoId: "3"),
        ]
        let result = PlaylistTrackListPresenter.displayedTracks(
            from: songs,
            sortOrder: PlaylistSortOrder(key: .title, ascending: true),
            searchQuery: "rock"
        )
        #expect(result.map(\.videoId) == ["3", "1"])
    }

    @Test("Search matches album title")
    func searchMatchesAlbum() {
        let songs = [
            self.makeSong(title: "a", artist: "x", videoId: "1", albumTitle: "Kind of Blue"),
            self.makeSong(title: "b", artist: "y", videoId: "2", albumTitle: "Blue Train"),
            self.makeSong(title: "c", artist: "z", videoId: "3", albumTitle: "Giant Steps"),
        ]
        let result = PlaylistTrackListPresenter.displayedTracks(
            from: songs,
            sortOrder: .default,
            searchQuery: "blue"
        )
        #expect(result.map(\.videoId) == ["1", "2"])
    }

    @Test("Multi-artist sort uses the joined artist display, not just the first artist")
    func multiArtistSortUsesJoinedDisplay() {
        let collab = Song(
            id: "1",
            title: "collab",
            artists: [
                Artist.inline(name: "Zed", namespace: "test"),
                Artist.inline(name: "Abe", namespace: "test"),
            ],
            album: nil,
            duration: nil,
            thumbnailURL: nil,
            videoId: "1"
        )
        let solo = self.makeSong(title: "solo", artist: "Mona", videoId: "2")
        let result = PlaylistTrackListPresenter.displayedTracks(
            from: [collab, solo],
            sortOrder: PlaylistSortOrder(key: .artist, ascending: true),
            searchQuery: ""
        )
        // "Mona" sorts before "Zed, Abe" — the key is the joined display string.
        #expect(result.map(\.videoId) == ["2", "1"])
    }

    // MARK: - Row identity

    @Test("Row identity prefers the per-occurrence playlist id so duplicates stay distinct")
    func rowIdentityDistinguishesDuplicates() {
        var first = self.makeSong(title: "same", artist: "x", videoId: "dup")
        var second = self.makeSong(title: "same", artist: "x", videoId: "dup")
        first.playlistSetVideoId = "set-a"
        second.playlistSetVideoId = "set-b"

        #expect(first.rowIdentity != second.rowIdentity)
        #expect(self.makeSong(title: "a", artist: "x", videoId: "vid").rowIdentity == "vid")
    }
}
