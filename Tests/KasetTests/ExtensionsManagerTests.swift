import Foundation
import Testing
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
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
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
        #expect(ext.isEnabled == true)
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

    @Test("Toggling an extension persists the enabled state and resolved URLs only include enabled entries")
    func toggleExtensionPersistsEnabledStateAndUpdatesResolvedURLs() throws {
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
        let resolvedURLs = manager.resolvedURLs()
        #expect(resolvedURLs.count == 1)
        #expect(resolvedURLs.first?.id == ext.id)
        #expect(resolvedURLs.first?.url.lastPathComponent == ext.relativePath)

        manager.toggleExtension(id: ext.id)

        #expect(manager.extensions.first?.isEnabled == false)
        #expect(manager.resolvedURLs().isEmpty)

        let reloadedManager = self.makeManager(in: rootDirectory)
        #expect(reloadedManager.extensions.first?.isEnabled == false)
    }

    @Test("resolvedURLs skips missing copied folders")
    func resolvedURLsSkipsMissingCopiedFolders() throws {
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
        let copiedURL = self.copiedExtensionURL(for: ext, in: rootDirectory)
        try FileManager.default.removeItem(at: copiedURL)

        #expect(manager.resolvedURLs().isEmpty)
    }

    @Test("Toggle and remove with unknown IDs are no-ops")
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

        manager.toggleExtension(id: "missing-id")
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
