import Testing
@testable import Kaset

@Suite("PlaylistDropTarget", .tags(.model))
struct PlaylistDropTargetTests {
    @Test("Classifies the raw Liked Music id as Liked Music")
    func classifiesLikedMusicId() {
        #expect(PlaylistDropTarget(playlistId: LikedMusicPlaylist.id) == .likedMusic)
    }

    @Test("Classifies the VL-prefixed Liked Music browse id as Liked Music")
    func classifiesLikedMusicBrowseId() {
        #expect(PlaylistDropTarget(playlistId: LikedMusicPlaylist.browseID) == .likedMusic)
    }

    @Test("Classifies an ordinary playlist id as editable")
    func classifiesOrdinaryPlaylist() {
        #expect(PlaylistDropTarget(playlistId: "PL_owned") == .editable(playlistId: "PL_owned"))
    }
}
