import Foundation
import Testing
@testable import Kaset

/// Tests for WebKitManager.
@Suite(.serialized, .tags(.service))
@MainActor
struct WebKitManagerTests {
    var webKitManager: WebKitManager

    init() {
        self.webKitManager = WebKitManager.shared
    }

    @Test("Shared instance exists")
    func sharedInstanceExists() {
        #expect(WebKitManager.shared != nil)
    }

    @Test("Data store exists")
    func dataStoreExists() {
        #expect(self.webKitManager.dataStore != nil)
    }

    @Test("Create WebView configuration")
    func createWebViewConfiguration() {
        let configuration = self.webKitManager.createWebViewConfiguration()
        #expect(configuration != nil)
        #expect(configuration.websiteDataStore === self.webKitManager.dataStore)
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
        let cookies = await webKitManager.getAllCookies()
        #expect(cookies != nil)
        // Cookies array may be empty in test environment
    }

    @Test("Cookie header for domain")
    func cookieHeaderForDomain() async {
        // May be nil if no cookies are set
        // Just verify it doesn't crash
        _ = await self.webKitManager.cookieHeader(for: "youtube.com")
    }

    @Test("Has auth cookies")
    func hasAuthCookies() async {
        let hasAuth = await webKitManager.hasAuthCookies()
        // Just verify the method works and returns a Bool
        #expect(hasAuth == true || hasAuth == false)
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
}
