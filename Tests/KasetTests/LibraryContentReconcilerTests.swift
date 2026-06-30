import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.viewModel))
struct LibraryContentReconcilerTests {
    @Test("Playlist addition remains visible until backend stabilizes")
    func playlistAdditionRemainsVisibleUntilBackendStabilizes() {
        var reconciler = LibraryContentReconciler()
        var snapshot = LibraryContentSnapshot.empty
        let playlist = TestFixtures.makePlaylist(id: "VLcreated-playlist", title: "Created Playlist")

        reconciler.addPlaylist(playlist, to: &snapshot)
        snapshot = reconciler.apply(Self.content(playlists: []), currentSnapshot: snapshot).snapshot
        #expect(snapshot.playlists.map(\.id) == ["VLcreated-playlist"])
        #expect(LibraryContentIdentity.containsPlaylist("created-playlist", in: snapshot.playlistIds))

        snapshot = reconciler.apply(Self.content(playlists: [playlist]), currentSnapshot: snapshot).snapshot
        snapshot = reconciler.apply(Self.content(playlists: [playlist]), currentSnapshot: snapshot).snapshot
        #expect(snapshot.playlists.map(\.id) == ["VLcreated-playlist"])

        snapshot = reconciler.apply(Self.content(playlists: []), currentSnapshot: snapshot).snapshot
        #expect(snapshot.playlists.isEmpty)
        #expect(snapshot.playlistIds.isEmpty)
    }

    @Test("Playlist removal stays suppressed until backend stabilizes")
    func playlistRemovalStaysSuppressedUntilBackendStabilizes() {
        var reconciler = LibraryContentReconciler()
        let playlist = TestFixtures.makePlaylist(id: "VLold-playlist", title: "Old Playlist")
        var snapshot = reconciler.apply(Self.content(playlists: [playlist]), currentSnapshot: .empty).snapshot

        reconciler.removePlaylist("old-playlist", from: &snapshot)
        snapshot = reconciler.apply(Self.content(playlists: [playlist]), currentSnapshot: snapshot).snapshot
        #expect(snapshot.playlists.isEmpty)
        #expect(snapshot.playlistIds.isEmpty)

        snapshot = reconciler.apply(Self.content(playlists: []), currentSnapshot: snapshot).snapshot
        snapshot = reconciler.apply(Self.content(playlists: []), currentSnapshot: snapshot).snapshot
        #expect(snapshot.playlists.isEmpty)

        snapshot = reconciler.apply(Self.content(playlists: [playlist]), currentSnapshot: snapshot).snapshot
        #expect(snapshot.playlists.map(\.id) == ["VLold-playlist"])
    }

    @Test("Landing fallback preserves existing artist snapshot")
    func landingFallbackPreservesExistingArtists() {
        var reconciler = LibraryContentReconciler()
        let authoritativeArtist = TestFixtures.makeArtist(id: "UC-channel-1", name: "Artist 1")
        let fallbackArtist = TestFixtures.makeArtist(id: "UC-channel-2", name: "Artist 2")
        var snapshot = reconciler.apply(Self.content(artists: [authoritativeArtist]), currentSnapshot: .empty).snapshot

        let result = reconciler.apply(
            Self.content(artists: [fallbackArtist], artistsSource: .landingFallback),
            currentSnapshot: snapshot
        )
        snapshot = result.snapshot

        #expect(result.preservedExistingArtists)
        #expect(snapshot.artists.map(\.id) == ["UC-channel-1"])
        #expect(snapshot.artistIds == Set(["UC-channel-1"]))
    }

    @Test("Artist removal stays suppressed through stale backend response")
    func artistRemovalStaysSuppressedThroughStaleBackendResponse() {
        var reconciler = LibraryContentReconciler()
        let artist = TestFixtures.makeArtist(id: "MPLAUC-channel-1", name: "Artist 1")
        var snapshot = reconciler.apply(Self.content(artists: [artist]), currentSnapshot: .empty).snapshot

        reconciler.removeArtist("UC-channel-1", from: &snapshot)
        snapshot = reconciler.apply(Self.content(artists: [artist]), currentSnapshot: snapshot).snapshot

        #expect(snapshot.artists.isEmpty)
        #expect(snapshot.artistIds.isEmpty)
        #expect(reconciler.needsArtistReconciliation(artistIds: ["MPLAUC-channel-1"], expectedInLibrary: false))
    }

    private static func content(
        playlists: [Playlist] = [],
        artists: [Artist] = [],
        podcastShows: [PodcastShow] = [],
        artistsSource: LibraryContentParser.LibraryArtistsSource = .dedicated
    ) -> LibraryContentParser.LibraryContent {
        LibraryContentParser.LibraryContent(
            playlists: playlists,
            artists: artists,
            podcastShows: podcastShows,
            artistsSource: artistsSource
        )
    }
}
