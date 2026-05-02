import Foundation
import Observation

// MARK: - SidebarPinnedItemsManager

/// Manages playlist-like items pinned to the sidebar.
@MainActor
@Observable
final class SidebarPinnedItemsManager {
    static let shared = SidebarPinnedItemsManager()

    private(set) var items: [SidebarPinnedItem] = []

    var isVisible: Bool {
        !self.items.isEmpty
    }

    private let skipPersistence: Bool
    private var saveTask: Task<Void, Never>?

    private var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let kasetDir = appSupport.appendingPathComponent("Kaset", isDirectory: true)
        return kasetDir.appendingPathComponent("sidebar-pins.json")
    }

    private init() {
        if UITestConfig.isUITestMode {
            self.skipPersistence = true
        } else {
            self.skipPersistence = false
            self.load()
        }
    }

    /// Internal initializer for tests that never reads or writes live user data.
    init(skipLoad: Bool) {
        self.skipPersistence = skipLoad
        if !skipLoad {
            self.load()
        }
    }

    func load() {
        do {
            guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
                DiagnosticsLogger.ui.debug("Sidebar pins file does not exist, starting fresh")
                return
            }

            let data = try Data(contentsOf: self.fileURL)
            let decoded = try JSONDecoder().decode([SidebarPinnedItem].self, from: data)
            self.items = decoded
            DiagnosticsLogger.ui.info("Loaded \(decoded.count) sidebar pinned items")
        } catch {
            DiagnosticsLogger.ui.error("Failed to load sidebar pinned items: \(error.localizedDescription)")
            self.items = []
        }
    }

    func add(_ item: SidebarPinnedItem) {
        guard !self.isPinned(contentId: item.contentId) else {
            DiagnosticsLogger.ui.debug("Item already pinned to sidebar: \(item.contentId)")
            return
        }

        self.items.append(item)
        self.save()
        DiagnosticsLogger.ui.info("Added to sidebar: \(item.title)")
    }

    func remove(contentId: String) {
        guard let index = self.items.firstIndex(where: { $0.contentId == contentId }) else {
            DiagnosticsLogger.ui.debug("Item not pinned to sidebar: \(contentId)")
            return
        }

        let removed = self.items.remove(at: index)
        self.save()
        DiagnosticsLogger.ui.info("Removed from sidebar: \(removed.title)")
    }

    func toggle(_ item: SidebarPinnedItem) {
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

    func moveUp(contentId: String) {
        guard let index = self.items.firstIndex(where: { $0.contentId == contentId }),
              index > self.items.startIndex
        else { return }

        self.items.swapAt(index, self.items.index(before: index))
        self.save()
    }

    func moveDown(contentId: String) {
        guard let index = self.items.firstIndex(where: { $0.contentId == contentId }),
              index < self.items.index(before: self.items.endIndex)
        else { return }

        self.items.swapAt(index, self.items.index(after: index))
        self.save()
    }

    func moveToTop(contentId: String) {
        guard let index = self.items.firstIndex(where: { $0.contentId == contentId }) else { return }
        let item = self.items.remove(at: index)
        self.items.insert(item, at: 0)
        self.save()
    }

    func moveToEnd(contentId: String) {
        guard let index = self.items.firstIndex(where: { $0.contentId == contentId }) else { return }
        let item = self.items.remove(at: index)
        self.items.append(item)
        self.save()
    }

    func isPinned(contentId: String) -> Bool {
        self.items.contains { $0.contentId == contentId }
    }

    func isPinned(_ item: SidebarPinnedItem) -> Bool {
        self.isPinned(contentId: item.contentId)
    }

    func reset(with items: [SidebarPinnedItem]) {
        self.items = items
        self.save()
    }

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
                DiagnosticsLogger.ui.debug("Saved \(itemsSnapshot.count) sidebar pinned items")
            } catch {
                DiagnosticsLogger.ui.error("Failed to save sidebar pinned items: \(error.localizedDescription)")
            }
        }
    }
}
