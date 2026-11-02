import Foundation
import Testing
import WebKit
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct ExtensionsManagerTests {
    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionsManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanupDirectory(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makePersistenceURL(in rootDirectory: URL) -> URL {
        rootDirectory
            .appendingPathComponent("Kaset", isDirectory: true)
            .appendingPathComponent("extensions.json")
    }

    private func makeManager(in rootDirectory: URL) -> ExtensionsManager {
        ExtensionsManager(persistenceURL: self.makePersistenceURL(in: rootDirectory))
    }

    private func copiedExtensionURL(for ext: ManagedExtension, in rootDirectory: URL) -> URL {
        self.makePersistenceURL(in: rootDirectory)
            .deletingLastPathComponent()
            .appendingPathComponent("ManagedExtensions", isDirectory: true)
            .appendingPathComponent(ext.relativePath, isDirectory: true)
    }

    private func makeExtensionSource(
        in rootDirectory: URL,
        folderName: String,
        manifest: [String: Any]? = nil,
        rawManifest: String? = nil,
        extraFiles: [String: String] = [:]
    ) throws -> URL {
        let sourceURL = rootDirectory.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        if let manifest {
            let completeManifest = manifest.merging(["version": "1.0", "description": "Test extension"]) { value, _ in value }
            let data = try JSONSerialization.data(withJSONObject: completeManifest, options: [.sortedKeys])
            try data.write(to: sourceURL.appendingPathComponent("manifest.json"))
        }

        if let rawManifest {
            try rawManifest.write(to: sourceURL.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        }

        for (relativePath, contents) in extraFiles {
            let fileURL = sourceURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        return sourceURL
    }

    @Test("Adding an extension copies files, extracts manifest metadata, and persists the entry")
    func addExtensionCopiesFilesAndPersistsMetadata() throws {
        let rootDirectory = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(rootDirectory) }

        let sourceURL = try self.makeExtensionSource(
            in: rootDirectory,
            folderName: "TestExtension",
            manifest: [
                "name": "Test Extension",
                "manifest_version": 3,
                "options_ui": [
                    "page": "pages/options.html",
                ],
                "action": [
                    "default_popup": "popup/index.html",
                ],
            ],
            extraFiles: [
                "pages/options.html": "<html>Options</html>",
                "popup/index.html": "<html>Popup</html>",
            ]
        )

        let manager = self.makeManager(in: rootDirectory)
        try manager.addExtension(at: sourceURL)

        #expect(manager.extensions.count == 1)

        let ext = try #require(manager.extensions.first)
        #expect(ext.id == ext.relativePath)
        #expect(ext.name == "Test Extension")
        #expect(ext.isEnabled == false)
        #expect(ext.approvedPermissions == nil)
        #expect(manager.resolvedURLs().isEmpty)
        #expect(ext.optionsPath == "pages/options.html")
        #expect(ext.popupPath == "popup/index.html")

        let copiedURL = self.copiedExtensionURL(for: ext, in: rootDirectory)
        #expect(FileManager.default.fileExists(atPath: copiedURL.path))
        #expect(FileManager.default.fileExists(atPath: copiedURL.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: copiedURL.appendingPathComponent("pages/options.html").path))
        #expect(FileManager.default.fileExists(atPath: copiedURL.appendingPathComponent("popup/index.html").path))
        #expect(FileManager.default.fileExists(atPath: self.makePersistenceURL(in: rootDirectory).path))

        let reloadedManager = self.makeManager(in: rootDirectory)
        #expect(reloadedManager.extensions == manager.extensions)
    }

    @Test("Adding an extension falls back to the folder name when the manifest uses a localized __MSG_ name")
    func addExtensionFallsBackToFolderNameForLocalizedManifestName() throws {
        let rootDirectory = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(rootDirectory) }

        let sourceURL = try self.makeExtensionSource(
            in: rootDirectory,
            folderName: "LocalizedExtension",
            manifest: [
                "name": "__MSG_extensionName__",
                "manifest_version": 3,
            ]
        )

        let manager = self.makeManager(in: rootDirectory)
        try manager.addExtension(at: sourceURL)

        let ext = try #require(manager.extensions.first)
        #expect(ext.name == "LocalizedExtension")
        #expect(ext.optionsPath == nil)
        #expect(ext.popupPath == nil)
    }

    @Test("Adding an extension supports legacy options_page and browser_action popup keys")
    func addExtensionSupportsLegacyManifestKeys() throws {
        let rootDirectory = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(rootDirectory) }

        let sourceURL = try self.makeExtensionSource(
            in: rootDirectory,
            folderName: "LegacyExtension",
            manifest: [
                "name": "Legacy Extension",
                "manifest_version": 2,
                "options_page": "legacy-options.html",
                "browser_action": [
                    "default_popup": "legacy-popup.html",
                ],
            ],
            extraFiles: [
                "legacy-options.html": "<html>Legacy Options</html>",
                "legacy-popup.html": "<html>Legacy Popup</html>",
            ]
        )

        let manager = self.makeManager(in: rootDirectory)
        try manager.addExtension(at: sourceURL)

        let ext = try #require(manager.extensions.first)
        #expect(ext.name == "Legacy Extension")
        #expect(ext.optionsPath == "legacy-options.html")
        #expect(ext.popupPath == "legacy-popup.html")
    }

    @Test("Adding an extension throws when manifest.json is missing")
    func addExtensionThrowsWhenManifestIsMissing() throws {
        let rootDirectory = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(rootDirectory) }

        let sourceURL = try self.makeExtensionSource(
            in: rootDirectory,
            folderName: "MissingManifest"
        )

        let manager = self.makeManager(in: rootDirectory)

        do {
            try manager.addExtension(at: sourceURL)
            Issue.record("Expected addExtension(at:) to throw for a missing manifest")
        } catch let error as NSError {
            #expect(error.domain == "ExtensionsManager")
            #expect(error.code == 1)
        }
    }

    @Test("Adding an extension throws when manifest.json cannot be parsed")
    func addExtensionThrowsWhenManifestIsInvalid() throws {
        let rootDirectory = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(rootDirectory) }

        let sourceURL = try self.makeExtensionSource(
            in: rootDirectory,
            folderName: "InvalidManifest",
            rawManifest: "{ invalid json"
        )

        let manager = self.makeManager(in: rootDirectory)

        do {
            try manager.addExtension(at: sourceURL)
            Issue.record("Expected addExtension(at:) to throw for an invalid manifest")
        } catch let error as NSError {
            #expect(error.domain == "ExtensionsManager")
            #expect(error.code == 2)
        }
    }

    @Test("Corrupt extensions.json loads as an empty list")
    func corruptPersistenceLoadsAsEmptyList() throws {
        let rootDirectory = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(rootDirectory) }

        let persistenceURL = self.makePersistenceURL(in: rootDirectory)
        try FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{ not valid json".write(to: persistenceURL, atomically: true, encoding: .utf8)

        let manager = self.makeManager(in: rootDirectory)
        #expect(manager.extensions.isEmpty)
    }

    @Test("Approval survives restart and disabling excludes an extension from resolved URLs")
    func approvalPersistsAndDisablingUpdatesResolvedURLs() async throws {
        let rootDirectory = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(rootDirectory) }

        let sourceURL = try self.makeExtensionSource(
            in: rootDirectory,
            folderName: "ToggleExtension",
            manifest: [
                "name": "Toggle Extension",
                "manifest_version": 3,
            ]
        )

        let manager = self.makeManager(in: rootDirectory)
        try manager.addExtension(at: sourceURL)

        let ext = try #require(manager.extensions.first)
        let review = try await manager.permissionReview(id: ext.id)
        #expect(manager.resolvedURLs().isEmpty)
        try await manager.approveExtension(review)
        let approvedManager = self.makeManager(in: rootDirectory)
        #expect(approvedManager.extensions.first?.isEnabled == true)
        #expect(approvedManager.allowsLoading(review.permissions, id: ext.id))
        let resolvedURLs = manager.resolvedURLs()
        #expect(resolvedURLs.count == 1)
        #expect(resolvedURLs.first?.id == ext.id)
        #expect(resolvedURLs.first?.url.lastPathComponent == ext.relativePath)

        manager.disableExtension(id: ext.id)

        #expect(manager.extensions.first?.isEnabled == false)
        #expect(manager.resolvedURLs().isEmpty)

        let reloadedManager = self.makeManager(in: rootDirectory)
        #expect(reloadedManager.extensions.first?.isEnabled == false)
    }

    @Test("resolvedURLs skips missing copied folders")
    func resolvedURLsSkipsMissingCopiedFolders() async throws {
        let rootDirectory = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(rootDirectory) }

        let sourceURL = try self.makeExtensionSource(
            in: rootDirectory,
            folderName: "MissingFilesExtension",
            manifest: [
                "name": "Missing Files Extension",
                "manifest_version": 3,
            ]
        )

        let manager = self.makeManager(in: rootDirectory)
        try manager.addExtension(at: sourceURL)

        let ext = try #require(manager.extensions.first)
        let review = try await manager.permissionReview(id: ext.id)
        try await manager.approveExtension(review)
        #expect(manager.extensions.first?.isEnabled == true)
        let copiedURL = self.copiedExtensionURL(for: ext, in: rootDirectory)
        try FileManager.default.removeItem(at: copiedURL)

        #expect(manager.resolvedURLs().isEmpty)
    }

    @Test("Review includes WebKit permissions, host access, and content-script matches, excluding optional access")
    func reviewDescribesRequiredAccessWithoutEnabling() async throws {
        let rootDirectory = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(rootDirectory) }
        let sourceURL = try self.makeExtensionSource(
            in: rootDirectory,
            folderName: "PermissionReview",
            manifest: [
                "name": "Permission Review",
                "manifest_version": 3,
                "permissions": ["cookies", "storage"],
                "host_permissions": ["https://*.youtube.com/*"],
                "optional_permissions": ["tabs"],
                "optional_host_permissions": ["https://example.com/*"],
                "content_scripts": [["matches": ["https://music.youtube.com/*"], "js": ["content.js"]]],
            ],
            extraFiles: ["content.js": "// Test fixture"]
        )
        let manager = self.makeManager(in: rootDirectory)
        let id = try manager.addExtension(at: sourceURL)
        let review = try await manager.permissionReview(id: id)

        #expect(review.permissions.permissions == ["cookies", "storage"])
        #expect(review.permissions.websitePatterns == ["https://*.youtube.com/*", "https://music.youtube.com/*"])
        #expect(manager.extensions.first?.isEnabled == false)
        #expect(manager.extensions.first?.approvedPermissions == nil)
        #expect(manager.resolvedURLs().isEmpty)
        #expect(self.makeManager(in: rootDirectory).resolvedURLs().isEmpty)

        let webKitManager = WebKitManager.makeTestInstance()
        await webKitManager.loadExtensions(using: manager)
        #expect(webKitManager.loadedExtensionCount == 0)
        try await manager.approveExtension(review)
        await webKitManager.loadExtensions(using: manager)
        #expect(webKitManager.loadedExtensionCount == 1)
        let context = try #require(webKitManager.webExtensionController.extensionContexts.first)
        #expect(context.grantedPermissions.keys.contains(.cookies))
        #expect(!context.grantedPermissions.keys.contains(.tabs))
        #expect(Set(context.grantedPermissionMatchPatterns.keys.map(\.string)) == Set(review.permissions.websitePatterns))
    }

    @Test("Legacy enabled extensions migrate to disabled entries requiring review")
    func legacyExtensionsRequireReview() throws {
        let rootDirectory = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(rootDirectory) }
        let persistenceURL = self.makePersistenceURL(in: rootDirectory)
        try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = """
        [{"id":"legacy","name":"Legacy extension","isEnabled":true,"relativePath":"legacy"}]
        """
        try legacy.write(to: persistenceURL, atomically: true, encoding: .utf8)

        let manager = self.makeManager(in: rootDirectory)
        #expect(manager.extensions.first?.name == "Legacy extension")
        #expect(manager.extensions.first?.isEnabled == false)
        #expect(manager.extensions.first?.approvedPermissions == nil)
        #expect(manager.resolvedURLs().isEmpty)
        let persisted = try JSONDecoder().decode([ManagedExtension].self, from: Data(contentsOf: persistenceURL))
        #expect(persisted.first?.isEnabled == false)
    }

    @Test("A changed extension cannot load or reuse a stale approval", arguments: ["permissions", "host_permissions", "content_scripts", "legacy_hosts"])
    func changedPermissionsRequireReview(change: String) async throws {
        let rootDirectory = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(rootDirectory) }
        let sourceURL = try self.makeExtensionSource(
            in: rootDirectory,
            folderName: "ChangedAccess",
            manifest: ["name": "Changed Access", "manifest_version": change == "legacy_hosts" ? 2 : 3],
            extraFiles: ["content.js": "// Test fixture"]
        )
        let manager = self.makeManager(in: rootDirectory)
        let id = try manager.addExtension(at: sourceURL)
        let review = try await manager.permissionReview(id: id)
        try await manager.approveExtension(review)

        let ext = try #require(manager.extensions.first)
        let manifestURL = self.copiedExtensionURL(for: ext, in: rootDirectory).appendingPathComponent("manifest.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        switch change {
        case "permissions":
            manifest[change] = ["cookies"]
        case "host_permissions":
            manifest[change] = ["<all_urls>"]
        case "content_scripts":
            manifest[change] = [["matches": ["https://*.google.com/*"], "js": ["content.js"]]]
        default:
            manifest["permissions"] = ["https://*.google.com/*"]
        }
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let changedReview = try await manager.permissionReview(id: id)
        #expect(changedReview.permissions != review.permissions)

        let reloadedManager = self.makeManager(in: rootDirectory)
        let webKitManager = WebKitManager.makeTestInstance()
        await webKitManager.loadExtensions(using: reloadedManager)
        #expect(webKitManager.loadedExtensionCount == 0)
        #expect(!reloadedManager.allowsLoading(changedReview.permissions, id: id))
        #expect(reloadedManager.extensions.first?.isEnabled == false)
        #expect(reloadedManager.extensions.first?.approvedPermissions == nil)
        #expect(reloadedManager.resolvedURLs().isEmpty)

        do {
            try await manager.approveExtension(review)
            Issue.record("A stale review must not enable changed access")
        } catch ExtensionConsentError.accessChanged {
            #expect(manager.extensions.first?.isEnabled == false)
            #expect(manager.extensions.first?.approvedPermissions == nil)
        }
        try await manager.approveExtension(changedReview)
        #expect(manager.allowsLoading(changedReview.permissions, id: id))
    }

    @Test("Runtime permission requests cannot grant optional API, host, or URL access")
    func optionalRuntimeRequestsAreDenied() async throws {
        let rootDirectory = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(rootDirectory) }
        let sourceURL = try self.makeExtensionSource(
            in: rootDirectory,
            folderName: "OptionalAccess",
            manifest: ["name": "Optional Access", "manifest_version": 3, "optional_permissions": ["cookies"]]
        )
        let webExtension = try await WKWebExtension(resourceBaseURL: sourceURL)
        let context = WKWebExtensionContext(for: webExtension)
        let controller = WKWebExtensionController()
        let webKitManager = WebKitManager.makeTestInstance()
        let apiResult = await webKitManager.webExtensionController(controller, promptForPermissions: [.cookies], in: nil, for: context)
        let pattern = try WKWebExtension.MatchPattern(string: "<all_urls>")
        let hostResult = await webKitManager.webExtensionController(controller, promptForPermissionMatchPatterns: [pattern], in: nil, for: context)
        let url = try #require(URL(string: "https://example.com/"))
        let urlResult = await webKitManager.webExtensionController(controller, promptForPermissionToAccess: [url], in: nil, for: context)
        #expect(apiResult.0.isEmpty)
        #expect(hostResult.0.isEmpty)
        #expect(urlResult.0.isEmpty)
    }

    @Test("Disable and remove with unknown IDs are no-ops")
    func unknownIdsAreNoOps() throws {
        let rootDirectory = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(rootDirectory) }

        let sourceURL = try self.makeExtensionSource(
            in: rootDirectory,
            folderName: "KnownExtension",
            manifest: [
                "name": "Known Extension",
                "manifest_version": 3,
            ]
        )

        let manager = self.makeManager(in: rootDirectory)
        try manager.addExtension(at: sourceURL)

        let before = manager.extensions

        manager.disableExtension(id: "missing-id")
        manager.removeExtension(id: "missing-id")

        #expect(manager.extensions == before)
    }

    @Test("Removing an extension deletes the copied files and persisted entry")
    func removeExtensionDeletesCopiedFilesAndPersistence() throws {
        let rootDirectory = try self.makeTemporaryDirectory()
        defer { self.cleanupDirectory(rootDirectory) }

        let sourceURL = try self.makeExtensionSource(
            in: rootDirectory,
            folderName: "RemovableExtension",
            manifest: [
                "name": "Removable Extension",
                "manifest_version": 3,
            ],
            extraFiles: [
                "content.js": "console.log('hello');",
            ]
        )

        let manager = self.makeManager(in: rootDirectory)
        try manager.addExtension(at: sourceURL)

        let ext = try #require(manager.extensions.first)
        let copiedURL = self.copiedExtensionURL(for: ext, in: rootDirectory)
        #expect(FileManager.default.fileExists(atPath: copiedURL.path))

        manager.removeExtension(id: ext.id)

        #expect(manager.extensions.isEmpty)
        #expect(FileManager.default.fileExists(atPath: copiedURL.path) == false)

        let reloadedManager = self.makeManager(in: rootDirectory)
        #expect(reloadedManager.extensions.isEmpty)
    }
}
