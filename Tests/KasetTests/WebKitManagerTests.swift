import Foundation
import Testing
import WebKit
@testable import Kaset

/// Tests for WebKitManager.
@Suite(.serialized, .tags(.service))
@MainActor
struct WebKitManagerTests {
    var webKitManager: WebKitManager

    init() {
        self.webKitManager = WebKitManager.makeTestInstance()
    }

    @Test("Test instance uses non-persistent data store")
    func instanceUsesNonPersistentDataStore() {
        #expect(self.webKitManager.dataStore.isPersistent == false)
    }

    @Test("Test instance starts without loaded extensions")
    func instanceStartsWithoutLoadedExtensions() {
        #expect(self.webKitManager.isExtensionLoaded == false)
        #expect(self.webKitManager.loadedExtensionCount == 0)
    }

    @Test("Create WebView configuration")
    func createWebViewConfiguration() {
        let configuration = self.webKitManager.createWebViewConfiguration()
        #expect(configuration.websiteDataStore === self.webKitManager.dataStore)
    }

    @Test("Extension host registers playback WebViews as extension-visible tabs")
    @MainActor
    func extensionHostRegistersPlaybackWebViews() {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                let controller = WKWebExtensionController()
                let host = KasetWebExtensionHost(controller: controller)
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.webExtensionController = controller

                let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: configuration)
                let tab = host.register(webView: webView, role: .musicPlayer)

                #expect(tab != nil)
                #expect(host.registeredTabCount == 1)
                #expect(host.openWindows.count == 1)
                #expect(host.focusedWindow != nil)

                // Re-registering the same WebView should activate the existing tab, not create another one.
                _ = host.register(webView: webView, role: .musicPlayer)
                #expect(host.registeredTabCount == 1)

                // Rebuilding the playback WebView for the same role should replace the tab's target,
                // not leave a stale ghost tab behind.
                let replacementWebView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: configuration)
                _ = host.register(webView: replacementWebView, role: .musicPlayer)
                #expect(host.registeredTabCount == 1)
            }
        #endif
    }

    @Test("Extension window does not invent an active tab after deactivation")
    @MainActor
    func extensionWindowDoesNotInventActiveTab() async throws {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                let tempDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("KasetWebExtensionWindowTests-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tempDirectory) }

                let manifest: [String: Any] = [
                    "manifest_version": 3,
                    "name": "Window Active Tab Test",
                    "description": "Test extension",
                    "version": "1.0",
                ]
                let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
                try manifestData.write(to: tempDirectory.appendingPathComponent("manifest.json"))

                let webExtension = try await WKWebExtension(resourceBaseURL: tempDirectory)
                let context = WKWebExtensionContext(for: webExtension)

                let window = KasetWebExtensionWindow()
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: configuration)
                let tab = KasetWebExtensionTab(role: .youtubeWatch, webView: webView)
                window.append(tab)

                #expect(window.activeTab(for: context) != nil)

                window.activeTab = nil

                #expect(window.activeTab(for: context) == nil)
            }
        #endif
    }

    @Test("Content script match patterns are extracted for permission grants")
    @MainActor
    func contentScriptMatchPatternsAreExtracted() {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                let manifest: [AnyHashable: Any] = [
                    "content_scripts": [
                        [
                            "matches": [
                                "https://*.youtube.com/*",
                                "https://www.youtube-nocookie.com/embed/*",
                                "https://*.youtube.com/*",
                            ],
                        ],
                    ],
                ]

                let patterns = WebKitManager.contentScriptMatchPatterns(from: manifest).map(\.string).sorted()

                #expect(patterns == [
                    "https://*.youtube.com/*",
                    "https://www.youtube-nocookie.com/embed/*",
                ])
            }
        #endif
    }

    @Test("Session switch WebView configuration excludes extensions")
    func createSessionSwitchWebViewConfiguration() {
        let configuration = self.webKitManager.createSessionSwitchWebViewConfiguration()
        #expect(configuration.websiteDataStore === self.webKitManager.dataStore)

        #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                #expect(configuration.webExtensionController == nil)
            }
        #endif
    }

    @Test("Origin constant")
    func originConstant() {
        #expect(WebKitManager.origin == "https://music.youtube.com")
    }

    @Test("Auth cookie name")
    func authCookieName() {
        #expect(WebKitManager.authCookieName == "__Secure-3PAPISID")
    }

    @Test("Get all cookies")
    func getAllCookies() async {
        let cookies = await self.webKitManager.getAllCookies()
        #expect(cookies.isEmpty)
    }

    @Test("Cookie header for domain")
    func cookieHeaderForDomain() async {
        // May be nil if no cookies are set
        // Just verify it doesn't crash
        _ = await self.webKitManager.cookieHeader(for: "youtube.com")
    }

    @Test("Has auth cookies")
    func hasAuthCookies() async {
        let hasAuth = await self.webKitManager.hasAuthCookies()
        #expect(hasAuth == false)
    }

    @Test("Cookie archive write coordinator skips duplicate pending saves and retries after failure")
    func cookieArchiveWriteCoordinatorRetriesAfterFailure() {
        let coordinator = CookieArchiveWriteCoordinator()
        let archive = Data([0x01, 0x02, 0x03])

        #expect(coordinator.beginSaveIfNeeded(archive) == true)
        #expect(coordinator.beginSaveIfNeeded(archive) == false)

        coordinator.finishSave(archive, success: false)

        #expect(coordinator.beginSaveIfNeeded(archive) == true)
    }

    @Test("Cookie archive write coordinator skips archives already persisted")
    func cookieArchiveWriteCoordinatorSkipsPersistedArchive() {
        let coordinator = CookieArchiveWriteCoordinator()
        let archive = Data([0x04, 0x05, 0x06])

        coordinator.seedPersistedArchive(archive)

        #expect(coordinator.beginSaveIfNeeded(archive) == false)
    }

    @Test("Extension resource URL resolves relative paths against the extension base URL")
    func extensionResourceURLUsesExtensionBaseURL() throws {
        let baseURL = try #require(URL(string: "webkit-extension://example-extension/"))
        let resolvedURL = WebKitManager.extensionResourceURL(
            relativePath: "/pages/options.html",
            baseURL: baseURL
        )

        #expect(resolvedURL?.absoluteString == "webkit-extension://example-extension/pages/options.html")
    }

    @Test("Extension resource URL rejects absolute external paths")
    func extensionResourceURLRejectsAbsoluteURLs() throws {
        let baseURL = try #require(URL(string: "webkit-extension://example-extension/"))
        let resolvedURL = WebKitManager.extensionResourceURL(
            relativePath: "https://example.com/options.html",
            baseURL: baseURL
        )

        #expect(resolvedURL == nil)
    }

    // MARK: - DATASYNC_ID Identity Matching

    @Test("Brand DATASYNC_ID matches when first half equals brand pageId")
    func dataSyncIdMatchesBrand() {
        // "<delegatedSessionId>||<userSessionId>" — delegated half is the brand.
        let dataSyncId = "111111111111111111111||108880000000000000000"
        #expect(WebKitManager.dataSyncId(dataSyncId, matches: "111111111111111111111") == true)
    }

    @Test("Brand DATASYNC_ID does not match a different brand pageId")
    func dataSyncIdRejectsWrongBrand() {
        let dataSyncId = "111111111111111111111||108880000000000000000"
        #expect(WebKitManager.dataSyncId(dataSyncId, matches: "999999999999999999999") == false)
    }

    @Test("Primary DATASYNC_ID (empty delegated half) matches nil brand")
    func dataSyncIdMatchesPrimary() {
        // Primary is "<userSessionId>||" — empty delegated (first) half.
        let dataSyncId = "108880000||"
        #expect(WebKitManager.dataSyncId(dataSyncId, matches: nil) == true)
    }

    @Test("Primary DATASYNC_ID does not match a brand expectation")
    func dataSyncIdPrimaryRejectsBrand() {
        let dataSyncId = "108880000||"
        #expect(WebKitManager.dataSyncId(dataSyncId, matches: "111111111111111111111") == false)
    }

    @Test("Brand DATASYNC_ID does not satisfy a primary (nil) expectation")
    func dataSyncIdBrandRejectsPrimary() {
        let dataSyncId = "111111111111111111111||108880000000000000000"
        #expect(WebKitManager.dataSyncId(dataSyncId, matches: nil) == false)
    }

    @Test("Blank/unread DATASYNC_ID never falsely verifies as primary")
    func dataSyncIdBlankIsNotPrimary() {
        // The page JS returns "" (or a bare "||") before ytcfg populates; an
        // unread page must NOT be treated as a verified primary session.
        #expect(WebKitManager.dataSyncId("", matches: nil) == false)
        #expect(WebKitManager.dataSyncId("||", matches: nil) == false)
        #expect(WebKitManager.dataSyncId("", matches: "111111111111111111111") == false)
        #expect(WebKitManager.dataSyncId("garbage-no-separator", matches: nil) == false)
    }
}
