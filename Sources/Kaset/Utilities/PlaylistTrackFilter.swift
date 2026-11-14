import Foundation

// MARK: - IndexedTrack

/// A playlist track paired with its position in the full, unfiltered track list.
///
/// The index is what playback relies on: in-playlist search only changes which rows
/// are *shown*, so playing a matched row must start the queue at the track's original
/// position — exactly as if it had been tapped in the unfiltered list.
struct IndexedTrack: Identifiable, Hashable {
    /// Position of the track within the full, unfiltered playlist.
    let index: Int
    let track: Song

    var id: Int {
        self.index
    }
}

// MARK: - PlaylistSearchQueueSource

/// Which queue a played in-playlist-search row should build.
enum PlaylistSearchQueueSource: Equatable {
    /// Play the whole playlist, starting at this original index — the default, identical to
    /// tapping the track in the unfiltered list.
    case fullPlaylist(originalIndex: Int)
    /// Play only the current search-result tracks, starting at this index within them.
    case searchResults(startIndex: Int)
}

// MARK: - PlaylistTrackListFooter

/// What the bottom of the (possibly filtered) playlist track list shows.
enum PlaylistTrackListFooter: Equatable {
    case none
    /// A pagination spinner.
    case loading
    /// A search is active but loading stopped before every track arrived, so the matches may be
    /// incomplete; offer a retry.
    case incompleteResults
}

// MARK: - PlaylistTrackFilter

/// Pure, view-agnostic filtering for in-playlist track search.
///
/// Matching is a case- and diacritic-insensitive substring test against the track title,
/// each artist name, and the album title, so `"dio"` finds songs by "Dio", `"diver"` finds
/// "Holy Diver", and `"bjork"` finds "Björk".
enum PlaylistTrackFilter {
    /// Returns every track paired with its original index, keeping only those whose title,
    /// an artist name, or album title contains `query`. A blank (or whitespace-only) query
    /// returns all tracks, so an empty search never hides anything.
    static func filter(_ tracks: [Song], query: String) -> [IndexedTrack] {
        let normalizedQuery = Self.normalize(query)
        return tracks.enumerated().compactMap { offset, track in
            guard normalizedQuery.isEmpty || Self.matches(track, normalizedQuery: normalizedQuery) else {
                return nil
            }
            return IndexedTrack(index: offset, track: track)
        }
    }

    /// Whether `track`'s title, any artist name, or its album title contains `normalizedQuery`.
    /// `normalizedQuery` must already be folded via ``normalize(_:)``.
    static func matches(_ track: Song, normalizedQuery: String) -> Bool {
        guard !normalizedQuery.isEmpty else { return true }
        if self.normalize(track.title).contains(normalizedQuery) {
            return true
        }
        if track.artists.contains(where: { Self.normalize($0.name).contains(normalizedQuery) }) {
            return true
        }
        guard let album = track.album else { return false }
        return self.normalize(album.title).contains(normalizedQuery)
    }

    /// Folds case and diacritics and trims surrounding whitespace so comparisons ignore
    /// accents and letter case.
    static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decides which queue to build when the filtered row at `position` is played: the current
    /// search results while a search is active, otherwise the full playlist from the track's
    /// original index (the unfiltered behavior). Returns `nil` if `position` is out of range.
    static func queueSource(
        forFilteredPosition position: Int,
        rows: [IndexedTrack],
        queryActive: Bool
    ) -> PlaylistSearchQueueSource? {
        guard rows.indices.contains(position) else { return nil }
        if queryActive {
            return .searchResults(startIndex: position)
        }
        return .fullPlaylist(originalIndex: rows[position].index)
    }

    /// Decides the list footer. Without a search it is the plain pagination spinner. While
    /// searching, scroll pagination is off and matches depend on a background full load, so the
    /// spinner covers that load's retry pauses, and a load that gave up offers a retry instead of
    /// leaving partial matches with no indication.
    static func listFooter(
        queryActive: Bool,
        hasMore: Bool,
        isLoadingPage: Bool,
        isLoadingAll: Bool,
        didFullLoadStall: Bool
    ) -> PlaylistTrackListFooter {
        if isLoadingPage {
            return .loading
        }
        guard queryActive, hasMore else { return .none }
        if isLoadingAll {
            return .loading
        }
        return didFullLoadStall ? .incompleteResults : .none
    }
}
