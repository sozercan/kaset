import Foundation
@testable import Kaset

/// A mock implementation of WebKitManagerProtocol for testing.
/// Does not interact with real WebKit or file storage.
@MainActor
final class MockWebKitManager: WebKitManagerProtocol {
    // MARK: - Response Stubs

    var allCookies: [HTTPCookie] = []
    var sapisidValue: String?

    // MARK: - Call Tracking

    private(set) var getAllCookiesCalled = false
    private(set) var getCookiesForDomainCalled = false
    private(set) var getCookiesForDomains: [String] = []
    private(set) var cookieHeaderCalled = false
    private(set) var getSAPISIDCalled = false
    private(set) var hasAuthCookiesCalled = false
    private(set) var clearAllDataCalled = false
    private(set) var forceBackupCookiesCalled = false
    private(set) var logAuthCookiesCalled = false

    // MARK: - Protocol Implementation

    func getAllCookies() async -> [HTTPCookie] {
        self.getAllCookiesCalled = true
        return self.allCookies
    }

    func getCookies(for domain: String) async -> [HTTPCookie] {
        self.getCookiesForDomainCalled = true
        self.getCookiesForDomains.append(domain)
        return self.allCookies.filter { cookie in
            domain.hasSuffix(cookie.domain) || cookie.domain.hasSuffix(domain)
        }
    }

    func cookieHeader(for domain: String) async -> String? {
        self.cookieHeaderCalled = true
        let cookies = await getCookies(for: domain)
        guard !cookies.isEmpty else { return nil }
        let headerFields = HTTPCookie.requestHeaderFields(with: cookies)
        return headerFields["Cookie"]
    }

    func getSAPISID() async -> String? {
        self.getSAPISIDCalled = true
        return self.sapisidValue
    }

    func hasAuthCookies() async -> Bool {
        self.hasAuthCookiesCalled = true
        return self.sapisidValue != nil
    }

    func clearAllData() async {
        self.clearAllDataCalled = true
        // Does NOT clear real data - this is a mock
        self.allCookies = []
        self.sapisidValue = nil
    }

    func forceBackupCookies() async {
        self.forceBackupCookiesCalled = true
        // Does NOT interact with real file storage
    }

    func logAuthCookies() async {
        self.logAuthCookiesCalled = true
        // No-op in mock
    }

    // MARK: - Helper Methods

    /// Resets all call tracking.
    func reset() {
        self.getAllCookiesCalled = false
        self.getCookiesForDomainCalled = false
        self.getCookiesForDomains = []
        self.cookieHeaderCalled = false
        self.getSAPISIDCalled = false
        self.hasAuthCookiesCalled = false
        self.clearAllDataCalled = false
        self.forceBackupCookiesCalled = false
        self.logAuthCookiesCalled = false
        self.allCookies = []
        self.sapisidValue = nil
    }
}
