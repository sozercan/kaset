import XCTest
@testable import Kaset

/// Tests for WebKitManager.
@MainActor
final class WebKitManagerTests: XCTestCase {
    var webKitManager: WebKitManager!

    override func setUp() async throws {
        self.webKitManager = WebKitManager.shared
    }

    override func tearDown() async throws {
        self.webKitManager = nil
    }

    func testSharedInstanceExists() {
        XCTAssertNotNil(WebKitManager.shared)
    }

    func testDataStoreExists() {
        XCTAssertNotNil(self.webKitManager.dataStore)
    }

    func testCreateWebViewConfiguration() {
        let configuration = self.webKitManager.createWebViewConfiguration()
        XCTAssertNotNil(configuration)
        XCTAssertEqual(configuration.websiteDataStore, self.webKitManager.dataStore)
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
        // Just verify the method works and returns a Bool
        // Value depends on whether user has previously logged in
        XCTAssertNotNil(hasAuth as Bool?)
    }
}
