import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.model))
struct LibraryContentIdentityTests {
    @Test("Playlist keys collapse VL browse IDs to raw playlist IDs")
    func playlistKeyCollapsesVLBrowseIDs() {
        #expect(LibraryContentIdentity.playlistKey(for: "VLPL123") == "PL123")
        #expect(LibraryContentIdentity.playlistKey(for: "PL123") == "PL123")
    }

    @Test("Playlist de-duplication keeps first equivalent item")
    func deduplicatedPlaylistsKeepsFirstEquivalentItem() {
        let canonicalPlaylist = TestFixtures.makePlaylist(id: "PL123", title: "Canonical")
        let browsePlaylist = TestFixtures.makePlaylist(id: "VLPL123", title: "Browse")
        let otherPlaylist = TestFixtures.makePlaylist(id: "VLPL456", title: "Other")

        let playlists = LibraryContentIdentity.deduplicatedPlaylists([
            canonicalPlaylist,
            browsePlaylist,
            otherPlaylist,
        ])

        #expect(playlists.map(\.id) == ["PL123", "VLPL456"])
        #expect(playlists.first?.title == "Canonical")
    }

    @Test("Artist keys collapse library browse IDs to public channel IDs")
    func artistKeyCollapsesLibraryBrowseIDs() {
        #expect(LibraryContentIdentity.artistKey(for: "MPLAUC-channel-1") == "UC-channel-1")
        #expect(LibraryContentIdentity.artistKey(for: "UC-channel-1") == "UC-channel-1")
    }

    @Test("Canonical artist preserves metadata when rewriting ID")
    func canonicalArtistPreservesMetadata() {
        let artist = Artist(
            id: "MPLAUC-channel-1",
            name: "Artist 1",
            thumbnailURL: URL(string: "https://example.com/thumb.jpg"),
            subtitle: "1.2M subscribers",
            profileKind: .profile
        )

        let canonicalArtist = LibraryContentIdentity.canonicalArtist(artist)

        #expect(canonicalArtist.id == "UC-channel-1")
        #expect(canonicalArtist.name == "Artist 1")
        #expect(canonicalArtist.thumbnailURL == artist.thumbnailURL)
        #expect(canonicalArtist.subtitle == "1.2M subscribers")
        #expect(canonicalArtist.profileKind == .profile)
    }

    @Test("Artist de-duplication canonicalizes equivalent IDs and keeps first metadata")
    func deduplicatedArtistsCanonicalizesEquivalentIDs() {
        let libraryArtist = Artist(
            id: "MPLAUC-channel-1",
            name: "Artist from Library",
            thumbnailURL: nil,
            subtitle: "Library subtitle",
            profileKind: .artist
        )
        let channelArtist = Artist(
            id: "UC-channel-1",
            name: "Artist from Channel",
            thumbnailURL: nil,
            subtitle: "Channel subtitle",
            profileKind: .profile
        )

        let artists = LibraryContentIdentity.deduplicatedArtists([libraryArtist, channelArtist])

        #expect(artists.count == 1)
        #expect(artists.first?.id == "UC-channel-1")
        #expect(artists.first?.name == "Artist from Library")
        #expect(artists.first?.subtitle == "Library subtitle")
        #expect(artists.first?.profileKind == .artist)
    }
}
