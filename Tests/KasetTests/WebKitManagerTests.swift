import Foundation
import Testing
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
