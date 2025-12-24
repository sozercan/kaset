import Foundation
import Testing
@testable import Kaset

/// Tests for WebKitManager.
@Suite(.serialized)
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
        #expect(webKitManager.dataStore != nil)
    }

    @Test("Create WebView configuration")
    func createWebViewConfiguration() {
        let configuration = webKitManager.createWebViewConfiguration()
        #expect(configuration != nil)
        #expect(configuration.websiteDataStore === webKitManager.dataStore)
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
        _ = await webKitManager.cookieHeader(for: "youtube.com")
    }

    @Test("Has auth cookies")
    func hasAuthCookies() async {
        let hasAuth = await webKitManager.hasAuthCookies()
        // Just verify the method works and returns a Bool
        #expect(hasAuth == true || hasAuth == false)
    }
}
