import Foundation

/// Pure filter + sort for the playlist detail track list. No state, no networking.
///
/// Sort and search run client-side over the fully-loaded track set because YouTube
/// Music's server-side playlist sort only reorders the returned window — its
/// continuation tokens carry no sort state, so paginated results revert to the
/// default order (see `docs/api-discovery.md`).
enum PlaylistTrackListPresenter {
    /// Returns the tracks to display after filtering by `searchQuery` and sorting by
    /// `sortOrder`. Filtering happens first, then sorting.
    static func displayedTracks(
        from tracks: [Song],
        sortOrder: PlaylistSortOrder,
        searchQuery: String
    ) -> [Song] {
        let filtered = Self.filter(tracks, query: searchQuery)
        return Self.sort(filtered, order: sortOrder)
    }

    // MARK: - Filtering

    private static func filter(_ tracks: [Song], query: String) -> [Song] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return tracks }
        return tracks.filter { song in
            if Self.contains(song.title, trimmed) {
                return true
            }
            if let albumTitle = song.album?.title, Self.contains(albumTitle, trimmed) {
                return true
            }
            return song.artists.contains { Self.contains($0.name, trimmed) }
        }
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    // MARK: - Sorting

    /// A track decorated with its sort key and original position. The key is built once
    /// per track, not inside the comparator: `artistsDisplay` re-joins the artist array on
    /// every access. The index keeps ties — and the whole comparison — stable.
    private struct Decorated {
        let song: Song
        let index: Int
        let stringKey: String?
        let duration: TimeInterval?
    }

    private static func sort(_ tracks: [Song], order: PlaylistSortOrder) -> [Song] {
        guard order.key != .original else { return tracks }

        let decorated = tracks.enumerated().map { index, song in
            Decorated(
                song: song,
                index: index,
                stringKey: Self.stringKey(for: song, key: order.key),
                duration: order.key == .duration ? song.duration : nil
            )
        }

        return decorated
            .sorted { Self.less($0, $1, order: order) }
            .map(\.song)
    }

    private static func stringKey(for song: Song, key: PlaylistSortKey) -> String? {
        switch key {
        case .title:
            song.title
        case .artist:
            song.artistsDisplay.isEmpty ? nil : song.artistsDisplay
        case .album:
            song.album?.title
        case .original, .duration:
            nil
        }
    }

    private static func less(_ lhs: Decorated, _ rhs: Decorated, order: PlaylistSortOrder) -> Bool {
        switch Self.compareKeys(lhs, rhs, key: order.key) {
        case .orderedSame:
            lhs.index < rhs.index // stable tie-break, direction-independent
        case .orderedAscending:
            order.ascending
        case .orderedDescending:
            !order.ascending
        case .lhsMissing:
            false // missing keys always sort last
        case .rhsMissing:
            true
        }
    }

    private enum KeyComparison {
        case orderedSame
        case orderedAscending
        case orderedDescending
        case lhsMissing
        case rhsMissing
    }

    private static func compareKeys(_ lhs: Decorated, _ rhs: Decorated, key: PlaylistSortKey) -> KeyComparison {
        switch key {
        case .original:
            .orderedSame
        case .duration:
            Self.compareDurations(lhs.duration, rhs.duration)
        case .title, .artist, .album:
            Self.compareStrings(lhs.stringKey, rhs.stringKey)
        }
    }

    private static func compareStrings(_ lhs: String?, _ rhs: String?) -> KeyComparison {
        switch (lhs, rhs) {
        case (nil, nil): .orderedSame
        case (nil, _): .lhsMissing
        case (_, nil): .rhsMissing
        case let (l?, r?):
            switch l.localizedStandardCompare(r) {
            case .orderedSame: .orderedSame
            case .orderedAscending: .orderedAscending
            case .orderedDescending: .orderedDescending
            }
        }
    }

    private static func compareDurations(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> KeyComparison {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .lhsMissing
        case (_, nil): return .rhsMissing
        case let (l?, r?):
            if l == r {
                return .orderedSame
            }
            return l < r ? .orderedAscending : .orderedDescending
        }
    }
}
