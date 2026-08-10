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

    private static func sort(_ tracks: [Song], order: PlaylistSortOrder) -> [Song] {
        guard order.key != .original else { return tracks }

        // Decorate with the original index so ties — and the whole comparison — stay stable.
        let indexed = Array(tracks.enumerated())
        let sorted = indexed.sorted { lhs, rhs in
            Self.less(lhs.element, rhs.element, order: order, lhsIndex: lhs.offset, rhsIndex: rhs.offset)
        }
        return sorted.map(\.element)
    }

    private static func less(
        _ lhs: Song, _ rhs: Song, order: PlaylistSortOrder, lhsIndex: Int, rhsIndex: Int
    ) -> Bool {
        switch self.compareKeys(lhs, rhs, key: order.key) {
        case .orderedSame:
            lhsIndex < rhsIndex // stable tie-break, direction-independent
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

    private static func compareKeys(_ lhs: Song, _ rhs: Song, key: PlaylistSortKey) -> KeyComparison {
        switch key {
        case .original:
            .orderedSame
        case .title:
            self.compareStrings(lhs.title, rhs.title)
        case .artist:
            self.compareStrings(
                lhs.artistsDisplay.isEmpty ? nil : lhs.artistsDisplay,
                rhs.artistsDisplay.isEmpty ? nil : rhs.artistsDisplay
            )
        case .album:
            self.compareStrings(lhs.album?.title, rhs.album?.title)
        case .duration:
            self.compareDurations(lhs.duration, rhs.duration)
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
