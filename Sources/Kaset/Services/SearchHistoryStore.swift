import Foundation
import Observation

// MARK: - SearchHistoryStore

/// Persists a small, ordered, de-duplicated list of recent search queries for a
/// given source (Music or YouTube). Backs the "Latest Searches" list in the
/// search overlay. Modeled on `FavoritesManager` persistence: JSON file in the
/// sandboxed Application Support folder, debounced off-main writes.
@MainActor
@Observable
final class SearchHistoryStore {
    /// The search surface a store belongs to; determines the on-disk filename.
    enum Source: String {
        case music
        case youtube

        var fileName: String {
            "search-history-\(self.rawValue).json"
        }
    }

    /// Maximum number of recent queries kept.
    static let maxItems = 30

    /// Recent queries, most-recent first.
    private(set) var items: [String] = []

    private let source: Source
    private let skipPersistence: Bool
    private var saveTask: Task<Void, Never>?

    // MARK: - Persistence

    private var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let kasetDir = appSupport.appendingPathComponent("Kaset", isDirectory: true)
        return kasetDir.appendingPathComponent(self.source.fileName)
    }

    // MARK: - Initialization

    init(source: Source) {
        self.source = source
        // In UI test mode we keep history in-memory only so live user data is untouched.
        if UITestConfig.isUITestMode {
            self.skipPersistence = true
            self.loadMockHistoryIfAvailable()
        } else {
            self.skipPersistence = false
            self.load()
        }
    }

    /// Test initializer that never touches disk.
    init(source: Source, skipPersistence: Bool) {
        self.source = source
        self.skipPersistence = skipPersistence
        if !skipPersistence {
            self.load()
        }
    }

    // MARK: - Load & Save

    /// Loads items from disk (once, at init).
    func load() {
        do {
            guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
                DiagnosticsLogger.ui.debug("Search history file does not exist, starting fresh")
                return
            }
            let data = try Data(contentsOf: self.fileURL)
            let decoded = try JSONDecoder().decode([String].self, from: data)
            self.items = Self.normalized(decoded)
            DiagnosticsLogger.ui.info("Loaded \(self.items.count) \(self.source.rawValue) search history items")
        } catch {
            DiagnosticsLogger.ui.error("Failed to load search history: \(error.localizedDescription)")
            self.items = []
        }
    }

    /// Loads mock history from UI-test launch environment when provided.
    private func loadMockHistoryIfAvailable() {
        guard let raw = UITestConfig.environmentValue(for: UITestConfig.mockSearchHistoryKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        self.items = Self.normalized(decoded)
    }

    /// Persists the current items off the main actor, debounced.
    private func save() {
        guard !self.skipPersistence else { return }

        self.saveTask?.cancel()
        let itemsSnapshot = self.items
        let targetURL = self.fileURL

        self.saveTask = Task(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }

            do {
                let directory = targetURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(itemsSnapshot)
                try data.write(to: targetURL, options: .atomic)
                DiagnosticsLogger.ui.debug("Saved \(itemsSnapshot.count) search history items")
            } catch {
                DiagnosticsLogger.ui.error("Failed to save search history: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Actions

    /// Records a query at the front, de-duplicating case-insensitively and capping the list.
    /// Blank queries are ignored.
    func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        self.items.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        self.items.insert(trimmed, at: 0)
        if self.items.count > Self.maxItems {
            self.items.removeLast(self.items.count - Self.maxItems)
        }
        self.save()
    }

    /// Removes a single recorded query, matching case-insensitively. Blank input
    /// and queries not present are ignored (no save).
    func remove(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let originalCount = self.items.count
        self.items.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        guard self.items.count != originalCount else { return }
        self.save()
    }

    /// Clears all recent queries.
    func clear() {
        guard !self.items.isEmpty else { return }
        self.items.removeAll()
        self.save()
    }

    // MARK: - Helpers

    /// Trims, drops blanks, de-duplicates case-insensitively (keeping first occurrence),
    /// and caps to `maxItems`. Used when loading possibly-stale data from disk.
    private static func normalized(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in raw {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
            if result.count >= Self.maxItems { break }
        }
        return result
    }
}
