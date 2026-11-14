import Foundation
import os
import WebKit

// MARK: - ManagedExtension

/// A user-managed web extension entry.
struct ManagedExtension: Codable, Identifiable, Equatable {
    /// Stable identifier (UUID string).
    let id: String

    /// Display name shown in the Extensions settings UI.
    var name: String

    /// Whether this extension is currently enabled.
    var isEnabled: Bool

    /// Path to the local copy of the extension in Application Support.
    var relativePath: String

    /// The options page path from manifest.json (e.g. "options.html")
    var optionsPath: String?

    /// The popup path from manifest.json (e.g. "popup.html")
    var popupPath: String?

    /// Local security-scoped bookmark for the cloned folder (needed for some sandbox processes)
    var localBookmark: Data?

    /// Required access explicitly approved by the user; absent for legacy entries.
    var approvedPermissions: ExtensionPermissions?

    init(id: String = UUID().uuidString,
         name: String,
         isEnabled: Bool,
         relativePath: String,
         optionsPath: String? = nil,
         popupPath: String? = nil,
         localBookmark: Data? = nil,
         approvedPermissions: ExtensionPermissions? = nil)
    {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.relativePath = relativePath
        self.optionsPath = optionsPath
        self.popupPath = popupPath
        self.localBookmark = localBookmark
        self.approvedPermissions = approvedPermissions
    }
}

// MARK: - ExtensionsManager

/// Manages the list of user-installed web extensions.
///
/// Extensions are persisted as JSON in Application Support. Directory access
/// is protected by security-scoped bookmarks so it survives app restarts.
@MainActor
@Observable
final class ExtensionsManager {
    static let shared = ExtensionsManager()

    private let logger = DiagnosticsLogger.extensions
    private let persistenceURL: URL?

    /// All managed extensions, in display order.
    private(set) var extensions: [ManagedExtension] = []

    private static var defaultPersistenceURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return appSupport
            .appendingPathComponent("Kaset", isDirectory: true)
            .appendingPathComponent("extensions.json")
    }

    private var managedExtensionsDirectoryURL: URL? {
        self.persistenceURL?
            .deletingLastPathComponent()
            .appendingPathComponent("ManagedExtensions", isDirectory: true)
    }

    init(persistenceURL: URL? = ExtensionsManager.defaultPersistenceURL) {
        self.persistenceURL = persistenceURL
        let loaded = Self.load(from: persistenceURL)
        self.extensions = loaded
        for index in self.extensions.indices where self.extensions[index].approvedPermissions == nil {
            self.extensions[index].isEnabled = false
        }
        if self.extensions != loaded {
            self.save()
        }
    }

    // MARK: - Persistence

    private static func load(from persistenceURL: URL?) -> [ManagedExtension] {
        guard let url = persistenceURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ManagedExtension].self, from: data)
        else {
            return []
        }
        return decoded
    }

    private func save() {
        guard let url = self.persistenceURL else { return }
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(self.extensions)
            try data.write(to: url, options: .atomic)
        } catch {
            self.logger.error("Failed to save extensions list: \(error.localizedDescription)")
        }
    }

    // MARK: - Public API

    /// Returns the resolved `URL`s for all enabled extensions, in order.
    /// Starts security-scoped access — call `stopAllAccess()` when done.
    func resolvedURLs() -> [(id: String, url: URL)] {
        var result: [(id: String, url: URL)] = []

        for ext in self.extensions where ext.isEnabled && ext.approvedPermissions != nil {
            if let resource = self.resolvedResource(for: ext) {
                result.append((id: ext.id, url: resource.url))
            }
        }

        return result
    }

    private func resolvedResource(for ext: ManagedExtension) -> (url: URL, accessingScope: Bool)? {
        guard let base = self.managedExtensionsDirectoryURL else { return nil }
        if let bookmarkData = ext.localBookmark {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale),
               resolved.startAccessingSecurityScopedResource()
            {
                return (resolved, true)
            }
        }
        let url = base.appendingPathComponent(ext.relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? (url, false) : nil
    }

    /// Parses resources without loading an extension context or executing its scripts.
    func permissionReview(id: String) async throws -> ExtensionPermissionReview {
        guard let ext = self.extensions.first(where: { $0.id == id }),
              let resource = self.resolvedResource(for: ext)
        else { throw ExtensionConsentError.unavailable }
        defer {
            if resource.accessingScope {
                resource.url.stopAccessingSecurityScopedResource()
            }
        }
        let webExtension = try await WKWebExtension(resourceBaseURL: resource.url)
        return ExtensionPermissionReview(id: ext.id, name: ext.name, permissions: ExtensionPermissions(webExtension: webExtension))
    }

    func approveExtension(_ review: ExtensionPermissionReview) async throws {
        let currentReview = try await self.permissionReview(id: review.id)
        guard currentReview.permissions == review.permissions else {
            self.invalidateApproval(id: review.id)
            throw ExtensionConsentError.accessChanged
        }
        guard let index = self.extensions.firstIndex(where: { $0.id == review.id }) else {
            throw ExtensionConsentError.unavailable
        }
        self.extensions[index].approvedPermissions = review.permissions
        self.extensions[index].isEnabled = true
        self.save()
    }

    /// Must succeed before granting permissions or loading the parsed extension.
    func allowsLoading(_ permissions: ExtensionPermissions, id: String) -> Bool {
        guard let ext = self.extensions.first(where: { $0.id == id }), ext.isEnabled else { return false }
        guard ext.approvedPermissions == permissions else {
            self.invalidateApproval(id: id)
            return false
        }
        return true
    }

    private func invalidateApproval(id: String) {
        guard let index = self.extensions.firstIndex(where: { $0.id == id }) else { return }
        self.extensions[index].approvedPermissions = nil
        self.extensions[index].isEnabled = false
        self.save()
    }

    /// Stops security-scoped access for all currently resolved extensions (obsolete).
    func stopAllAccess() {}

    /// Adds an extension from a directory URL chosen by the user.
    /// Creates a security-scoped bookmark for persistent access.
    /// Adds an extension from a folder containing manifest.json.
    /// Analyzes the manifest structure before attempting to copy.
    @discardableResult
    func addExtension(at url: URL) throws -> String {
        // 1. Analyze the manifest first
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw NSError(domain: "ExtensionsManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "manifest.json not found in the selected folder."])
        }

        let accessingSource = url.startAccessingSecurityScopedResource()
        defer {
            if accessingSource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NSError(domain: "ExtensionsManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not read or parse manifest.json."])
        }

        // 2. Extract metadata
        let manifestName = (manifest["name"] as? String) ?? url.lastPathComponent
        let name = manifestName.hasPrefix("__MSG_") ? url.lastPathComponent : manifestName
        let manifestVersion = (manifest["manifest_version"] as? Int) ?? 0

        let optionsPath: String? = if let optionsUI = manifest["options_ui"] as? [String: Any] {
            optionsUI["page"] as? String
        } else {
            manifest["options_page"] as? String
        }

        var popupPath: String?
        if let action = (manifest["action"] as? [String: Any]) ?? (manifest["browser_action"] as? [String: Any]) {
            popupPath = action["default_popup"] as? String
        }

        self.logger.info("Manifest Analysis: Name=\(name), V\(manifestVersion), Options=\(optionsPath ?? "none"), Popup=\(popupPath ?? "none")")

        // 3. Perform Copy
        guard let extensionsDir = self.managedExtensionsDirectoryURL else {
            throw NSError(domain: "ExtensionsManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not determine the extensions storage location."])
        }
        try FileManager.default.createDirectory(at: extensionsDir, withIntermediateDirectories: true)

        let relativePath = UUID().uuidString
        let destURL = extensionsDir.appendingPathComponent(relativePath, isDirectory: true)

        try FileManager.default.copyItem(at: url, to: destURL)

        // 4. Persistence
        let localBookmark = try? destURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)

        let entry = ManagedExtension(
            id: relativePath,
            name: name,
            isEnabled: false,
            relativePath: relativePath,
            optionsPath: optionsPath,
            popupPath: popupPath,
            localBookmark: localBookmark
        )
        self.extensions.append(entry)
        self.save()
        self.logger.info("Successfully installed extension: \(name)")
        return entry.id
    }

    /// Removes an extension by its ID.
    func removeExtension(id: String) {
        guard let index = self.extensions.firstIndex(where: { $0.id == id }) else { return }
        let ext = self.extensions[index]
        if let extensionsDir = self.managedExtensionsDirectoryURL {
            let destURL = extensionsDir.appendingPathComponent(ext.relativePath)
            try? FileManager.default.removeItem(at: destURL)
        }

        self.extensions.remove(at: index)
        self.save()
    }

    /// Disables an extension. Enabling requires an explicit permission review.
    func disableExtension(id: String) {
        guard let idx = self.extensions.firstIndex(where: { $0.id == id }) else { return }
        self.extensions[idx].isEnabled = false
        self.save()
    }
}
