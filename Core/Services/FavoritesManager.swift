import CoreTransferable
import Foundation
import Observation

// MARK: - FavoritesManager

/// Manages Favorites persistence and state.
@MainActor
@Observable
final class FavoritesManager {
    /// Shared singleton instance.
    static let shared = FavoritesManager()

    /// Current pinned items (ordered).
    private(set) var items: [FavoriteItem] = []

    /// Whether Favorites section should be visible.
    var isVisible: Bool { !self.items.isEmpty }

    /// Whether this instance should skip persistence (for testing).
    private let skipPersistence: Bool

    // MARK: - Persistence

    /// File URL for persisted data.
    private var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let kasetDir = appSupport.appendingPathComponent("Kaset", isDirectory: true)
        return kasetDir.appendingPathComponent("favorites.json")
    }

    // MARK: - Initialization

    private init() {
        // In UI test mode, use mock data and skip persistence to avoid touching live data
        if UITestConfig.isUITestMode {
            self.skipPersistence = true
            self.loadMockData()
        } else {
            self.skipPersistence = false
            self.load()
        }
    }

    /// Internal initializer for testing that skips auto-loading and persistence.
    /// Test instances never read from or write to disk, ensuring user data is never affected.
    init(skipLoad: Bool) {
        self.skipPersistence = skipLoad // When skipLoad is true, also skip persistence
        if !skipLoad {
            self.load()
        }
    }

    // MARK: - Load & Save

    /// Loads items from disk (called once at init, runs synchronously on main thread).
    /// This is acceptable because it only happens once at app launch.
    func load() {
        do {
            guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
                DiagnosticsLogger.ui.debug("Favorites file does not exist, starting fresh")
                return
            }
            let data = try Data(contentsOf: self.fileURL)
            let decoded = try JSONDecoder().decode([FavoriteItem].self, from: data)
            self.items = decoded
            DiagnosticsLogger.ui.info("Loaded \(decoded.count) favorite items")
        } catch {
            DiagnosticsLogger.ui.error("Failed to load favorites: \(error.localizedDescription)")
            self.items = []
        }
    }

    /// Saves items to disk asynchronously on a background thread.
    /// Captures current state and writes without blocking the main thread.
    /// Test instances (skipPersistence=true) never write to disk.
    private func save() {
        // Skip persistence for test instances to avoid overwriting user data
        guard !self.skipPersistence else { return }

        // Capture current state for background write
        let itemsSnapshot = self.items
        let targetURL = self.fileURL

        // Perform disk I/O off the main actor.
        // Fire-and-forget: failures are logged but not propagated.
        Task(priority: .utility) {
            do {
                // Ensure directory exists
                let directory = targetURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                let data = try JSONEncoder().encode(itemsSnapshot)
                try data.write(to: targetURL, options: .atomic)
                DiagnosticsLogger.ui.debug("Saved \(itemsSnapshot.count) favorite items")
            } catch {
                DiagnosticsLogger.ui.error("Failed to save favorites: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Actions

    /// Adds an item to Favorites if not already present.
    func add(_ item: FavoriteItem) {
        guard !self.isPinned(contentId: item.contentId) else {
            DiagnosticsLogger.ui.debug("Item already in favorites: \(item.contentId)")
            return
        }
        self.items.insert(item, at: 0) // New items go to the front
        self.save()
        DiagnosticsLogger.ui.info("Added to favorites: \(item.title)")
    }

    /// Removes an item by content ID (videoId or browseId).
    func remove(contentId: String) {
        guard let index = items.firstIndex(where: { $0.contentId == contentId }) else {
            DiagnosticsLogger.ui.debug("Item not in favorites: \(contentId)")
            return
        }
        let removed = self.items.remove(at: index)
        self.save()
        DiagnosticsLogger.ui.info("Removed from favorites: \(removed.title)")
    }

    /// Toggles an item in/out of Favorites.
    func toggle(_ item: FavoriteItem) {
        if self.isPinned(contentId: item.contentId) {
            self.remove(contentId: item.contentId)
        } else {
            self.add(item)
        }
    }

    /// Moves an item to a new position.
    func move(from source: IndexSet, to destination: Int) {
        self.items.move(fromOffsets: source, toOffset: destination)
        self.save()
    }

    /// Moves an item to the beginning of the list.
    func moveToTop(contentId: String) {
        guard let index = items.firstIndex(where: { $0.contentId == contentId }) else { return }
        let item = self.items.remove(at: index)
        self.items.insert(item, at: 0)
        self.save()
    }

    /// Moves an item to the end of the list.
    func moveToEnd(contentId: String) {
        guard let index = items.firstIndex(where: { $0.contentId == contentId }) else { return }
        let item = self.items.remove(at: index)
        self.items.append(item)
        self.save()
    }

    /// Checks if an item is pinned by content ID.
    func isPinned(contentId: String) -> Bool {
        self.items.contains { $0.contentId == contentId }
    }

    // MARK: - Convenience Methods

    /// Checks if a song is pinned.
    func isPinned(song: Song) -> Bool {
        self.isPinned(contentId: song.videoId)
    }

    /// Checks if an album is pinned.
    func isPinned(album: Album) -> Bool {
        self.isPinned(contentId: album.id)
    }

    /// Checks if a playlist is pinned.
    func isPinned(playlist: Playlist) -> Bool {
        self.isPinned(contentId: playlist.id)
    }

    /// Checks if an artist is pinned.
    func isPinned(artist: Artist) -> Bool {
        self.isPinned(contentId: artist.id)
    }

    /// Checks if a podcast show is pinned.
    func isPinned(podcastShow: PodcastShow) -> Bool {
        self.isPinned(contentId: podcastShow.id)
    }

    /// Toggles a song in/out of Favorites.
    func toggle(song: Song) {
        self.toggle(.from(song))
    }

    /// Toggles an album in/out of Favorites.
    func toggle(album: Album) {
        self.toggle(.from(album))
    }

    /// Toggles a playlist in/out of Favorites.
    func toggle(playlist: Playlist) {
        self.toggle(.from(playlist))
    }

    /// Toggles an artist in/out of Favorites.
    func toggle(artist: Artist) {
        self.toggle(.from(artist))
    }

    /// Toggles a podcast show in/out of Favorites.
    func toggle(podcastShow: PodcastShow) {
        self.toggle(.from(podcastShow))
    }

    // MARK: - Testing Support

    /// Loads mock favorites data from environment variable (for UI testing).
    /// This never touches disk, ensuring live user data is protected.
    private func loadMockData() {
        guard let jsonString = UITestConfig.environmentValue(for: UITestConfig.mockFavoritesKey),
              let data = jsonString.data(using: .utf8)
        else {
            DiagnosticsLogger.ui.debug("No mock favorites data provided")
            self.items = []
            return
        }

        do {
            let decoded = try JSONDecoder().decode([FavoriteItem].self, from: data)
            self.items = decoded
            DiagnosticsLogger.ui.info("Loaded \(decoded.count) mock favorite items")
        } catch {
            DiagnosticsLogger.ui.error("Failed to decode mock favorites: \(error.localizedDescription)")
            self.items = []
        }
    }

    /// Clears all favorites (for testing).
    func clearAll() {
        self.items.removeAll()
        self.save()
    }

    /// Resets the manager with new items (for testing).
    func reset(with items: [FavoriteItem]) {
        self.items = items
        self.save()
    }
}

// MARK: - FavoriteItem + Transferable

extension FavoriteItem: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(for: FavoriteItem.self, contentType: .data)
    }
}
