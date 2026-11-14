import Foundation

// MARK: - YouTubeSearchHistoryStore

/// Persists the YouTube searches made in Kaset on this Mac, most recent first.
///
/// This is separate from the account's YouTube search history (fetched by
/// `YouTubeClient.getSearchHistory()`): it also covers signed-out use, brand
/// accounts, and accounts with search history paused.
struct YouTubeSearchHistoryStore: @unchecked Sendable {
    /// Oldest entries beyond this count are dropped.
    static let maxEntries = 50

    private static let key = "com.kaset.youtube.searchHistory"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Stored queries, most recent first.
    var entries: [String] {
        self.defaults.stringArray(forKey: Self.key) ?? []
    }

    /// Moves `query` to the front, replacing any earlier entry that differs only
    /// in letter case or surrounding whitespace.
    func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = self.entries.filter { !Self.matches($0, trimmed) }
        updated.insert(trimmed, at: 0)
        self.defaults.set(Array(updated.prefix(Self.maxEntries)), forKey: Self.key)
    }

    /// Removes every entry matching `query`, ignoring letter case.
    func remove(_ query: String) {
        self.defaults.set(self.entries.filter { !Self.matches($0, query) }, forKey: Self.key)
    }

    func clear() {
        self.defaults.removeObject(forKey: Self.key)
    }

    /// Whether two history queries refer to the same search.
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}
