import Testing
@testable import Kaset

@Suite(.tags(.model))
struct PlaylistLibraryEligibilityTests {
    @Test("System collections cannot be toggled in menus or detail headers", arguments: [
        "LM", "VLLM", "RDPN", "VLRDPN", "SE", "VLSE", Playlist.uploadedSongsBrowseID,
    ])
    func excludesSystemCollections(id: String) {
        let playlist = TestFixtures.makePlaylist(id: id)
        let detail = PlaylistDetail(playlist: playlist, tracks: [])

        #expect(!playlist.supportsLibraryToggle)
        #expect(!detail.supportsLibraryToggle)
    }

    @Test("Regular playlists and albums retain library actions", arguments: [
        "PL-test", "VLPL-test", "MPRE-test", "OLAK-test",
    ])
    func allowsRegularContent(id: String) {
        let playlist = TestFixtures.makePlaylist(id: id)
        let detail = PlaylistDetail(playlist: playlist, tracks: [])

        #expect(playlist.supportsLibraryToggle)
        #expect(detail.supportsLibraryToggle)
    }
}
