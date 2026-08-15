import Foundation

// MARK: - PlaylistDropTarget

/// Where a song is being added, classified once so eligibility and routing can never disagree.
///
/// Liked Music is the LM auto-playlist — membership there means "liked", so it routes through the
/// like flow instead of `edit_playlist`, which never applies to LM. Classifying up front (via
/// `LikedMusicPlaylist.matches(id:)`, which folds the `VL` browse-ID prefix) keeps that rule in one
/// place: a pinned Liked Music row exposed as `VLLM` still resolves to `.likedMusic`.
enum PlaylistDropTarget: Hashable {
    case likedMusic
    case editable(playlistId: String)

    init(playlistId: String) {
        self = LikedMusicPlaylist.matches(id: playlistId) ? .likedMusic : .editable(playlistId: playlistId)
    }
}
