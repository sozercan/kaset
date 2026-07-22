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

    @Test("Landing fallback preserves existing album snapshot")
    func landingFallbackPreservesExistingAlbums() {
        var reconciler = LibraryContentReconciler()
        let authoritativeAlbum = TestFixtures.makeAlbum(id: "MPRE-authoritative", title: "Authoritative Album")
        let fallbackAlbum = TestFixtures.makeAlbum(id: "MPRE-preview", title: "Preview Album")
        var snapshot = reconciler.apply(
            Self.content(albums: [authoritativeAlbum], accountScope: "account-a"),
            currentSnapshot: .empty
        ).snapshot

        let result = reconciler.apply(
            Self.content(
                albums: [fallbackAlbum],
                albumsSource: .landingFallback,
                accountScope: "account-a"
            ),
            currentSnapshot: snapshot
        )
        snapshot = result.snapshot

        #expect(result.preservedExistingAlbums)
        #expect(snapshot.albums == [authoritativeAlbum])
    }

    @Test("Partial album pagination preserves existing same-account snapshot")
    func partialAlbumPaginationPreservesExistingAlbums() {
        var reconciler = LibraryContentReconciler()
        let firstAlbum = TestFixtures.makeAlbum(id: "MPRE-first", title: "First Album")
        let laterAlbum = TestFixtures.makeAlbum(id: "MPRE-later", title: "Later Album")
        let freshFirstAlbum = TestFixtures.makeAlbum(
            id: "MPRE-first",
            title: "Updated First Album",
            year: "2026",
            libraryTargetId: "OLAK-first"
        )
        let newlyLoadedAlbum = TestFixtures.makeAlbum(id: "MPRE-new", title: "Newly Loaded Album")
        var snapshot = reconciler.apply(
            Self.content(albums: [firstAlbum, laterAlbum], accountScope: "account-a"),
            currentSnapshot: .empty
        ).snapshot

        let result = reconciler.apply(
            Self.content(
                albums: [freshFirstAlbum, newlyLoadedAlbum],
                albumsSource: .partial,
                accountScope: "account-a"
            ),
            currentSnapshot: snapshot
        )
        snapshot = result.snapshot

        #expect(result.preservedExistingAlbums)
        #expect(snapshot.albums.map(\.id) == ["MPRE-first", "MPRE-later", "MPRE-new"])
        #expect(snapshot.albums.first?.title == "Updated First Album")
        #expect(snapshot.albums.first?.year == "2026")
        #expect(snapshot.albums.first?.libraryTargetId == "OLAK-first")
        #expect(snapshot.albumsSource == .partial)
    }

    @Test("Partial album merge preserves the canonical MPRE browse ID")
    func partialAlbumMergePreservesCanonicalBrowseID() {
        var reconciler = LibraryContentReconciler()
        let existing = TestFixtures.makeAlbum(
            id: "MPRE-canonical",
            title: "Canonical Album",
            libraryTargetId: "OLAK-canonical"
        )
        var snapshot = reconciler.apply(
            Self.content(albums: [existing], accountScope: "account-a"),
            currentSnapshot: .empty
        ).snapshot
        let incoming = TestFixtures.makeAlbum(
            id: "OLAK-canonical",
            title: "Updated Album"
        )

        snapshot = reconciler.apply(
            Self.content(
                albums: [incoming],
                albumsSource: .partial,
                accountScope: "account-a"
            ),
            currentSnapshot: snapshot
        ).snapshot

        #expect(snapshot.albums.first?.id == "MPRE-canonical")
        #expect(snapshot.albums.first?.libraryTargetId == "OLAK-canonical")
        #expect(snapshot.albums.first?.title == "Updated Album")
    }

    @Test("Partial album snapshots do not downgrade on weaker refreshes")
    func partialAlbumSnapshotsDoNotDowngrade() {
        var reconciler = LibraryContentReconciler()
        let firstAlbum = TestFixtures.makeAlbum(id: "MPRE-first", title: "First Album")
        let secondAlbum = TestFixtures.makeAlbum(id: "MPRE-second", title: "Second Album")
        let thirdAlbum = TestFixtures.makeAlbum(id: "MPRE-third", title: "Third Album")
        let previewAlbum = TestFixtures.makeAlbum(id: "MPRE-preview", title: "Preview Album")
        var snapshot = reconciler.apply(
            Self.content(
                albums: [firstAlbum, secondAlbum],
                albumsSource: .partial,
                accountScope: "account-a"
            ),
            currentSnapshot: .empty
        ).snapshot

        let shorterPartial = reconciler.apply(
            Self.content(
                albums: [firstAlbum, thirdAlbum],
                albumsSource: .partial,
                accountScope: "account-a"
            ),
            currentSnapshot: snapshot
        )
        snapshot = shorterPartial.snapshot

        #expect(shorterPartial.preservedExistingAlbums)
        #expect(snapshot.albums == [firstAlbum, secondAlbum, thirdAlbum])
        #expect(snapshot.albumsSource == .partial)

        let fallback = reconciler.apply(
            Self.content(
                albums: [previewAlbum],
                albumsSource: .landingFallback,
                accountScope: "account-a"
            ),
            currentSnapshot: snapshot
        )

        #expect(fallback.preservedExistingAlbums)
        #expect(fallback.snapshot.albums == [firstAlbum, secondAlbum, thirdAlbum])
        #expect(fallback.snapshot.albumsSource == .partial)
    }

    @Test("Album fallback does not preserve another account's snapshot")
    func albumFallbackDoesNotCrossAccountScope() {
        var reconciler = LibraryContentReconciler()
        let firstAccountAlbum = TestFixtures.makeAlbum(id: "MPRE-account-a", title: "Account A Album")
        let secondAccountPreview = TestFixtures.makeAlbum(id: "MPRE-account-b", title: "Account B Preview")
        var snapshot = reconciler.apply(
            Self.content(albums: [firstAccountAlbum], accountScope: "account-a"),
            currentSnapshot: .empty
        ).snapshot

        let result = reconciler.apply(
            Self.content(
                albums: [secondAccountPreview],
                albumsSource: .landingFallback,
                accountScope: "account-b"
            ),
            currentSnapshot: snapshot
        )
        snapshot = result.snapshot

        #expect(!result.preservedExistingAlbums)
        #expect(snapshot.albums == [secondAccountPreview])
        #expect(snapshot.accountScope == "account-b")
    }

    @Test("Account scope changes clear pending optimistic library state")
    func accountScopeChangesClearPendingMutations() {
        var reconciler = LibraryContentReconciler()
        var snapshot = reconciler.apply(
            Self.content(accountScope: "account-a"),
            currentSnapshot: .empty
        ).snapshot
        let playlist = TestFixtures.makePlaylist(id: "VL-account-a", title: "Account A Playlist")
        let album = TestFixtures.makeAlbum(id: "MPRE-account-a", title: "Account A Album")
        let artist = TestFixtures.makeArtist(id: "UC-account-a", name: "Account A Artist")

        reconciler.addPlaylist(playlist, to: &snapshot)
        reconciler.addAlbum(album, to: &snapshot)
        reconciler.addArtist(artist, to: &snapshot)

        let result = reconciler.apply(
            Self.content(accountScope: "account-b"),
            currentSnapshot: snapshot
        )

        #expect(result.snapshot.playlists.isEmpty)
        #expect(result.snapshot.albums.isEmpty)
        #expect(result.snapshot.artists.isEmpty)
        #expect(result.snapshot.playlistIds.isEmpty)
        #expect(result.snapshot.artistIds.isEmpty)
        #expect(result.snapshot.accountScope == "account-b")
    }

    @Test("Authoritative empty albums clear an existing snapshot")
    func authoritativeEmptyAlbumsClearExistingSnapshot() {
        var reconciler = LibraryContentReconciler()
        let album = TestFixtures.makeAlbum(id: "MPRE-existing", title: "Existing Album")
        var snapshot = reconciler.apply(
            Self.content(albums: [album], accountScope: "account-a"),
            currentSnapshot: .empty
        ).snapshot

        let result = reconciler.apply(
            Self.content(albums: [], albumsSource: .dedicated, accountScope: "account-a"),
            currentSnapshot: snapshot
        )
        snapshot = result.snapshot

        #expect(!result.preservedExistingAlbums)
        #expect(snapshot.albums.isEmpty)
        #expect(snapshot.albumsSource == .dedicated)
        #expect(snapshot.hasLoadedContent)

        let fallbackAlbum = TestFixtures.makeAlbum(id: "MPRE-stale-preview", title: "Stale Preview")
        let fallbackResult = reconciler.apply(
            Self.content(
                albums: [fallbackAlbum],
                albumsSource: .landingFallback,
                accountScope: "account-a"
            ),
            currentSnapshot: snapshot
        )

        #expect(fallbackResult.preservedExistingAlbums)
        #expect(fallbackResult.snapshot.albums.isEmpty)
        #expect(fallbackResult.snapshot.albumsSource == .dedicated)
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

    @Test("Saved album snapshots update from backend content")
    func savedAlbumSnapshotsUpdateFromBackendContent() {
        var reconciler = LibraryContentReconciler()
        let firstAlbum = TestFixtures.makeAlbum(id: "MPRE-first", title: "First Album")
        let secondAlbum = TestFixtures.makeAlbum(id: "MPRE-second", title: "Second Album")

        var snapshot = reconciler.apply(Self.content(albums: [firstAlbum]), currentSnapshot: .empty).snapshot
        #expect(snapshot.albums == [firstAlbum])
        #expect(snapshot.hasVisibleContent)

        snapshot = reconciler.apply(Self.content(albums: [secondAlbum]), currentSnapshot: snapshot).snapshot
        #expect(snapshot.albums == [secondAlbum])
    }

    @Test("Album addition remains visible until backend stabilizes")
    func albumAdditionRemainsVisibleUntilBackendStabilizes() {
        var reconciler = LibraryContentReconciler()
        var snapshot = LibraryContentSnapshot.empty
        let optimisticAlbum = TestFixtures.makeAlbum(
            id: "MPRE-optimistic",
            title: "Optimistic Album",
            libraryTargetId: "OLAK-shared"
        )
        let backendAlbum = TestFixtures.makeAlbum(
            id: "MPRE-backend",
            title: "Backend Album",
            libraryTargetId: "OLAK-shared"
        )

        reconciler.addAlbum(optimisticAlbum, to: &snapshot)
        snapshot = reconciler.apply(Self.content(albums: []), currentSnapshot: snapshot).snapshot
        #expect(snapshot.albums == [optimisticAlbum])

        snapshot = reconciler.apply(Self.content(albums: [backendAlbum]), currentSnapshot: snapshot).snapshot
        snapshot = reconciler.apply(Self.content(albums: [backendAlbum]), currentSnapshot: snapshot).snapshot
        #expect(snapshot.albums == [backendAlbum])

        snapshot = reconciler.apply(Self.content(albums: []), currentSnapshot: snapshot).snapshot
        #expect(snapshot.albums.isEmpty)
    }

    @Test("Album removal stays suppressed until backend stabilizes")
    func albumRemovalStaysSuppressedUntilBackendStabilizes() {
        var reconciler = LibraryContentReconciler()
        let album = TestFixtures.makeAlbum(
            id: "MPRE-saved",
            title: "Saved Album",
            libraryTargetId: "OLAK-saved"
        )
        var snapshot = reconciler.apply(Self.content(albums: [album]), currentSnapshot: .empty).snapshot

        reconciler.removeAlbum(
            albumId: album.id,
            targetPlaylistId: album.libraryTargetId,
            from: &snapshot
        )
        snapshot = reconciler.apply(Self.content(albums: [album]), currentSnapshot: snapshot).snapshot
        #expect(snapshot.albums.isEmpty)

        snapshot = reconciler.apply(Self.content(albums: []), currentSnapshot: snapshot).snapshot
        snapshot = reconciler.apply(Self.content(albums: []), currentSnapshot: snapshot).snapshot
        #expect(snapshot.albums.isEmpty)

        snapshot = reconciler.apply(Self.content(albums: [album]), currentSnapshot: snapshot).snapshot
        #expect(snapshot.albums == [album])
    }

    @Test("Album removal matches MPRE-only snapshot when mutation also has OLAK target")
    func albumRemovalMatchesMPREOnlySnapshot() {
        var reconciler = LibraryContentReconciler()
        let backendAlbum = TestFixtures.makeAlbum(
            id: "MPRE-saved",
            title: "Saved Album",
            libraryTargetId: nil
        )
        var snapshot = reconciler.apply(Self.content(albums: [backendAlbum]), currentSnapshot: .empty).snapshot

        reconciler.removeAlbum(
            albumId: backendAlbum.id,
            targetPlaylistId: "OLAK-saved",
            from: &snapshot
        )
        snapshot = reconciler.apply(Self.content(albums: [backendAlbum]), currentSnapshot: snapshot).snapshot

        #expect(snapshot.albums.isEmpty)
    }

    @Test("Album addition matches backend row that only returns MPRE identity")
    func albumAdditionMatchesMPREOnlyBackendRow() {
        var reconciler = LibraryContentReconciler()
        var snapshot = LibraryContentSnapshot.empty
        let optimisticAlbum = TestFixtures.makeAlbum(
            id: "MPRE-shared",
            title: "Optimistic Album",
            libraryTargetId: "OLAK-shared"
        )
        let backendAlbum = TestFixtures.makeAlbum(
            id: "MPRE-shared",
            title: "Backend Album",
            libraryTargetId: nil
        )

        reconciler.addAlbum(optimisticAlbum, to: &snapshot)
        snapshot = reconciler.apply(Self.content(albums: [backendAlbum]), currentSnapshot: snapshot).snapshot
        snapshot = reconciler.apply(Self.content(albums: [backendAlbum]), currentSnapshot: snapshot).snapshot

        #expect(snapshot.albums == [backendAlbum])

        snapshot = reconciler.apply(Self.content(albums: []), currentSnapshot: snapshot).snapshot
        #expect(snapshot.albums.isEmpty)
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
        albums: [Album] = [],
        artists: [Artist] = [],
        podcastShows: [PodcastShow] = [],
        albumsSource: LibraryContentParser.LibraryAlbumsSource = .dedicated,
        artistsSource: LibraryContentParser.LibraryArtistsSource = .dedicated,
        accountScope: String? = nil
    ) -> LibraryContentParser.LibraryContent {
        LibraryContentParser.LibraryContent(
            playlists: playlists,
            albums: albums,
            artists: artists,
            podcastShows: podcastShows,
            albumsSource: albumsSource,
            artistsSource: artistsSource,
            accountScope: accountScope
        )
    }
}
