import SwiftUI
import Testing
@testable import Kaset

/// Construction-level tests for the legacy fallback views used on macOS 15.
///
/// SwiftUI views can't have their `body` evaluated outside of a hosting
/// renderer, so these tests are deliberately narrow: they verify the view
/// values can be constructed with realistic inputs and that the stored
/// properties survive `init`. The end-to-end behavior is covered by the
/// matching UI tests in `KasetUITests` running on the macos-15 CI leg.
@MainActor
@Suite(.tags(.model))
struct LegacyFallbackViewsTests {
    private static func makePlaylist() -> Playlist {
        Playlist(
            id: "PL_TEST_LEGACY",
            title: "Legacy Test Playlist",
            description: "A playlist used by macOS 15 fallback tests",
            thumbnailURL: URL(string: "https://example.invalid/thumb.jpg"),
            trackCount: 12
        )
    }

    @Test("SimplePlaylistDetailView constructs with mock client and viewmodel")
    func simplePlaylistDetailViewConstructs() {
        let playlist = Self.makePlaylist()
        let client = MockYTMusicClient()
        let viewModel = PlaylistDetailViewModel(playlist: playlist, client: client)
        let view = SimplePlaylistDetailView(playlist: playlist, viewModel: viewModel)
        #expect(view.playlist.id == playlist.id)
        #expect(view.playlist.title == playlist.title)
    }

    @Test("SimpleLyricsView accepts custom header and width configuration")
    func simpleLyricsViewConstructs() {
        let client = MockYTMusicClient()

        let defaultView = SimpleLyricsView(client: client)
        #expect(defaultView.showsHeader == true)
        #expect(defaultView.preferredWidth == 280)

        let customView = SimpleLyricsView(
            client: client,
            showsHeader: false,
            preferredWidth: nil
        )
        #expect(customView.showsHeader == false)
        #expect(customView.preferredWidth == nil)
    }
}
