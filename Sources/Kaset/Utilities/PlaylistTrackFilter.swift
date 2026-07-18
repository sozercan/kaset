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

// MARK: - PlaylistTrackFilter

/// Pure, view-agnostic filtering for in-playlist track search.
///
/// Matching is a case- and diacritic-insensitive substring test against the track title
/// and each artist name, so `"dio"` finds songs by "Dio", `"diver"` finds "Holy Diver", and
/// `"bjork"` finds "Björk".
enum PlaylistTrackFilter {
    /// Returns every track paired with its original index, keeping only those whose title
    /// or an artist name contains `query`. A blank (or whitespace-only) query returns all
    /// tracks, so an empty search never hides anything.
    static func filter(_ tracks: [Song], query: String) -> [IndexedTrack] {
        let normalizedQuery = Self.normalize(query)
        return tracks.enumerated().compactMap { offset, track in
            guard normalizedQuery.isEmpty || Self.matches(track, normalizedQuery: normalizedQuery) else {
                return nil
            }
            return IndexedTrack(index: offset, track: track)
        }
    }

    /// Whether `track`'s title or any artist name contains `normalizedQuery`.
    /// `normalizedQuery` must already be folded via ``normalize(_:)``.
    static func matches(_ track: Song, normalizedQuery: String) -> Bool {
        guard !normalizedQuery.isEmpty else { return true }
        if self.normalize(track.title).contains(normalizedQuery) {
            return true
        }
        return track.artists.contains { Self.normalize($0.name).contains(normalizedQuery) }
    }

    /// Folds case and diacritics and trims surrounding whitespace so comparisons ignore
    /// accents and letter case.
    static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decides which queue to build when the filtered row at `position` is played. Defaults to
    /// the full playlist (matching unfiltered behavior) whenever the search isn't active or the
    /// results-queue preference is off. Returns `nil` if `position` is out of range.
    static func queueSource(
        forFilteredPosition position: Int,
        rows: [IndexedTrack],
        queryActive: Bool,
        queueFromResults: Bool
    ) -> PlaylistSearchQueueSource? {
        guard rows.indices.contains(position) else { return nil }
        if queryActive, queueFromResults {
            return .searchResults(startIndex: position)
        }
        return .fullPlaylist(originalIndex: rows[position].index)
    }
}
