import Foundation
import os
import WebKit

struct ManagedExtension: Codable, Identifiable, Equatable {
    let id: String

    var name: String

    var isEnabled: Bool

    var relativePath: String

    var optionsPath: String?

    var popupPath: String?

    var localBookmark: Data?

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

@MainActor
@Observable
final class ExtensionsManager {
    static let shared = ExtensionsManager()

    private let logger = DiagnosticsLogger.extensions
    private let persistenceURL: URL?

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
        do {
            try self.persist()
        } catch {
            self.logger.error("Failed to save extensions list: \(error.localizedDescription)")
        }
    }

    private func persist() throws {
        guard let url = self.persistenceURL else { return }
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self.extensions)
        try data.write(to: url, options: .atomic)
    }

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
        let previous = self.extensions[index]
        self.extensions[index].approvedPermissions = review.permissions
        self.extensions[index].isEnabled = true
        do {
            try self.persist()
        } catch {
            self.extensions[index] = previous
            self.logger.error("Failed to save extension approval: \(error.localizedDescription)")
            throw error
        }
    }

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

    func stopAllAccess() {}

    @discardableResult
    func addExtension(at url: URL) throws -> String {
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

        guard let extensionsDir = self.managedExtensionsDirectoryURL else {
            throw NSError(domain: "ExtensionsManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not determine the extensions storage location."])
        }
        try FileManager.default.createDirectory(at: extensionsDir, withIntermediateDirectories: true)

        let relativePath = UUID().uuidString
        let destURL = extensionsDir.appendingPathComponent(relativePath, isDirectory: true)

        try FileManager.default.copyItem(at: url, to: destURL)

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

    func disableExtension(id: String) {
        guard let idx = self.extensions.firstIndex(where: { $0.id == id }) else { return }
        self.extensions[idx].isEnabled = false
        self.save()
    }
}
