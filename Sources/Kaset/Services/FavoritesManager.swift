import Foundation
import Observation

// MARK: - FavoritesManager

/// Manages Favorites persistence and state, scoped per account.
@MainActor
@Observable
final class FavoritesManager {
    static let shared = FavoritesManager()

    private(set) var items: [FavoriteItem] = []
    private(set) var activeAccountID = "primary"

    var isVisible: Bool {
        !self.items.isEmpty
    }

    private let skipPersistence: Bool
    /// In-memory store for `skipPersistence` test instances.
    private var itemsByAccount: [String: [FavoriteItem]] = [:]
    private var saveTask: Task<Void, Never>?

    private var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let kasetDir = appSupport.appendingPathComponent("Kaset", isDirectory: true)
        return kasetDir.appendingPathComponent("favorites-\(self.activeAccountID).json")
    }

    private init() {
        if UITestConfig.isUITestMode {
            self.skipPersistence = true
            self.loadMockData()
        } else {
            self.skipPersistence = false
            self.load()
        }
    }

    /// Test initializer — skips disk I/O when `skipLoad` is true.
    init(skipLoad: Bool) {
        self.skipPersistence = skipLoad
        if !skipLoad {
            self.load()
        }
    }

    /// Switches account scope. `nil` clears the visible list (sign-out) without deleting files.
    func setActiveAccountID(_ accountID: String?) {
        // Flush the current account before switching so a debounced save isn't lost.
        if self.skipPersistence {
            self.itemsByAccount[self.activeAccountID] = self.items
        } else {
            self.saveTask?.cancel()
            self.saveTask = nil
            Self.write(self.items, to: self.fileURL)
        }

        guard let accountID else {
            self.activeAccountID = "primary"
            self.items = []
            return
        }

        guard self.activeAccountID != accountID else { return }
        self.activeAccountID = accountID

        // One-time: rename old shared favorites.json into this account's file.
        if !self.skipPersistence {
            let oldFile = self.fileURL.deletingLastPathComponent().appendingPathComponent("favorites.json")
            if FileManager.default.fileExists(atPath: oldFile.path),
               !FileManager.default.fileExists(atPath: self.fileURL.path)
            {
                try? FileManager.default.moveItem(at: oldFile, to: self.fileURL)
            }
        }

        self.load()
    }

    // MARK: - Load & Save

    func load() {
        if self.skipPersistence {
            self.items = self.itemsByAccount[self.activeAccountID] ?? []
            return
        }

        do {
            guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
                self.items = []
                return
            }
            let data = try Data(contentsOf: self.fileURL)
            self.items = try JSONDecoder().decode([FavoriteItem].self, from: data)
            DiagnosticsLogger.ui.info("Loaded \(self.items.count) favorite items")
        } catch {
            DiagnosticsLogger.ui.error("Failed to load favorites: \(error.localizedDescription)")
            self.items = []
        }
    }

    private func save() {
        if self.skipPersistence {
            self.itemsByAccount[self.activeAccountID] = self.items
            return
        }

        self.saveTask?.cancel()
        let itemsSnapshot = self.items
        let targetURL = self.fileURL
        self.saveTask = Task(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            Self.write(itemsSnapshot, to: targetURL)
        }
    }

    private static func write(_ items: [FavoriteItem], to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: url, options: .atomic)
        } catch {
            DiagnosticsLogger.ui.error("Failed to save favorites: \(error.localizedDescription)")
        }
    }

    // MARK: - Actions

    func add(_ item: FavoriteItem) {
        guard !self.isPinned(contentId: item.contentId) else { return }
        self.items.insert(item, at: 0)
        self.save()
    }

    func remove(contentId: String) {
        guard let index = items.firstIndex(where: { $0.contentId == contentId }) else { return }
        self.items.remove(at: index)
        self.save()
    }

    func toggle(_ item: FavoriteItem) {
        if self.isPinned(contentId: item.contentId) {
            self.remove(contentId: item.contentId)
        } else {
            self.add(item)
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        self.items.move(fromOffsets: source, toOffset: destination)
        self.save()
    }

    func moveToTop(contentId: String) {
        guard let index = items.firstIndex(where: { $0.contentId == contentId }) else { return }
        let item = self.items.remove(at: index)
        self.items.insert(item, at: 0)
        self.save()
    }

    func moveToEnd(contentId: String) {
        guard let index = items.firstIndex(where: { $0.contentId == contentId }) else { return }
        let item = self.items.remove(at: index)
        self.items.append(item)
        self.save()
    }

    func isPinned(contentId: String) -> Bool {
        self.items.contains { $0.contentId == contentId }
    }

    func isPinned(song: Song) -> Bool {
        self.isPinned(contentId: song.videoId)
    }

    func isPinned(album: Album) -> Bool {
        self.isPinned(contentId: album.id)
    }

    func isPinned(playlist: Playlist) -> Bool {
        self.isPinned(contentId: playlist.id)
    }

    func isPinned(artist: Artist) -> Bool {
        self.isPinned(contentId: artist.id)
    }

    func isPinned(podcastShow: PodcastShow) -> Bool {
        self.isPinned(contentId: podcastShow.id)
    }

    func toggle(song: Song) {
        self.toggle(.from(song))
    }

    func toggle(album: Album) {
        self.toggle(.from(album))
    }

    func toggle(playlist: Playlist) {
        self.toggle(.from(playlist))
    }

    func toggle(artist: Artist) {
        self.toggle(.from(artist))
    }

    func toggle(podcastShow: PodcastShow) {
        self.toggle(.from(podcastShow))
    }

    // MARK: - Testing Support

    private func loadMockData() {
        guard let jsonString = UITestConfig.environmentValue(for: UITestConfig.mockFavoritesKey),
              let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([FavoriteItem].self, from: data)
        else {
            self.items = []
            return
        }
        self.items = decoded
        self.itemsByAccount[self.activeAccountID] = decoded
    }

    func clearAll() {
        self.items.removeAll()
        self.save()
    }

    func reset(with items: [FavoriteItem]) {
        self.items = items
        self.save()
    }
}
