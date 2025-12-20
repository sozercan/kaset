import XCTest
@testable import YouTubeMusic

/// Tests for WebKitManager.
@MainActor
final class WebKitManagerTests: XCTestCase {
    var webKitManager: WebKitManager!

    override func setUp() async throws {
        webKitManager = WebKitManager.shared
    }

    override func tearDown() async throws {
        webKitManager = nil
    }

    func testSharedInstanceExists() {
        XCTAssertNotNil(WebKitManager.shared)
    }

    func testDataStoreExists() {
        XCTAssertNotNil(webKitManager.dataStore)
    }

    func testCreateWebViewConfiguration() {
        let configuration = webKitManager.createWebViewConfiguration()
        XCTAssertNotNil(configuration)
        XCTAssertEqual(configuration.websiteDataStore, webKitManager.dataStore)
    }

    func testOriginConstant() {
        XCTAssertEqual(WebKitManager.origin, "https://music.youtube.com")
    }

    func testAuthCookieName() {
        XCTAssertEqual(WebKitManager.authCookieName, "__Secure-3PAPISID")
    }

    func testGetAllCookies() async {
        let cookies = await webKitManager.getAllCookies()
        XCTAssertNotNil(cookies)
        // Cookies array may be empty in test environment
    }

    func testCookieHeaderForDomain() async {
        let header = await webKitManager.cookieHeader(for: "youtube.com")
        // May be nil if no cookies are set
        // Just verify it doesn't crash
    }

    func testHasAuthCookies() async {
        let hasAuth = await webKitManager.hasAuthCookies()
        // In test environment, we likely don't have auth cookies
        XCTAssertFalse(hasAuth)
    }
}
