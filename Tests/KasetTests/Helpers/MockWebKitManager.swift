import Foundation
@testable import Kaset

/// A mock implementation of WebKitManagerProtocol for testing.
/// Does not interact with real WebKit or file storage.
@MainActor
final class MockWebKitManager: WebKitManagerProtocol {
    // MARK: - Response Stubs

    var allCookies: [HTTPCookie] = []
    var sapisidValue: String?

    /// When set, `switchSessionIdentity` throws this error instead of succeeding.
    var switchSessionIdentityError: Error?

    /// Per-call scripted outcomes (front of queue first); `nil` = succeed. Takes
    /// precedence over `switchSessionIdentityError` while non-empty.
    var switchSessionIdentityErrorQueue: [Error?] = []

    /// Optional async gate awaited inside `switchSessionIdentity` so a test can
    /// hold a pin "in flight" to exercise cancel/await ordering.
    var switchSessionIdentityGate: (@Sendable () async -> Void)?

    /// Per-call gates (front of queue first); `nil` = no gate for that call.
    /// Takes precedence over `switchSessionIdentityGate` while non-empty.
    var switchSessionIdentityGateQueue: [(@Sendable () async -> Void)?] = []

    /// URLs passed to `switchSessionIdentity`, in call order.
    private(set) var switchSessionIdentityURLs: [URL] = []

    // MARK: - Call Tracking

    private(set) var getAllCookiesCalled = false
    private(set) var getCookiesForDomainCalled = false
    private(set) var getCookiesForDomains: [String] = []
    private(set) var cookieHeaderCalled = false
    private(set) var getSAPISIDCalled = false
    private(set) var getSAPISIDCallCount = 0
    private(set) var hasAuthCookiesCalled = false
    private(set) var clearAuthCookiesCalled = false
    private(set) var clearAllDataCalled = false
    private(set) var forceBackupCookiesCalled = false
    private(set) var waitForInitialCookieRestoreCalled = false
    private(set) var waitForInitialCookieRestoreCallCount = 0
    private(set) var logAuthCookiesCalled = false
    private(set) var switchSessionIdentityCalled = false
    private(set) var switchSessionIdentityCallCount = 0
    private(set) var switchSessionIdentityExpectedBrandIds: [String?] = []
    private(set) var switchSessionIdentityCompletedBrandIds: [String?] = []
    private(set) var callSequence: [String] = []

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
        self.getSAPISIDCallCount += 1
        self.callSequence.append("getSAPISID")
        return self.sapisidValue
    }

    func hasAuthCookies() async -> Bool {
        self.hasAuthCookiesCalled = true
        return self.sapisidValue != nil
    }

    func clearAuthCookies() async {
        self.clearAuthCookiesCalled = true
        self.sapisidValue = nil
        self.allCookies.removeAll { KeychainCookieStorage.authCookieNames.contains($0.name) }
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

    func waitForInitialCookieRestore() async {
        self.waitForInitialCookieRestoreCalled = true
        self.waitForInitialCookieRestoreCallCount += 1
        self.callSequence.append("waitForInitialCookieRestore")
    }

    func logAuthCookies() async {
        self.logAuthCookiesCalled = true
        // No-op in mock
    }

    func switchSessionIdentity(to signinURL: URL, expectedBrandId: String?) async throws {
        self.switchSessionIdentityCalled = true
        self.switchSessionIdentityCallCount += 1
        self.switchSessionIdentityExpectedBrandIds.append(expectedBrandId)
        self.switchSessionIdentityURLs.append(signinURL)
        self.callSequence.append("switchSessionIdentity")

        // Optional gate: lets a test hold a "pin" in flight (e.g. a cold-launch
        // restore) to exercise cancel/await ordering. Honors cooperative
        // cancellation so the production cancel+await returns promptly.
        let gate = if !self.switchSessionIdentityGateQueue.isEmpty {
            self.switchSessionIdentityGateQueue.removeFirst()
        } else {
            self.switchSessionIdentityGate
        }
        if let gate {
            await gate()
            try Task.checkCancellation()
        }

        // Per-call failure scripting (front of queue), else the sticky error.
        if !self.switchSessionIdentityErrorQueue.isEmpty {
            if let scripted = self.switchSessionIdentityErrorQueue.removeFirst() {
                throw scripted
            }
        } else if let error = self.switchSessionIdentityError {
            throw error
        }

        self.switchSessionIdentityCompletedBrandIds.append(expectedBrandId)
    }

    // MARK: - Helper Methods

    /// Resets all call tracking.
    func reset() {
        self.getAllCookiesCalled = false
        self.getCookiesForDomainCalled = false
        self.getCookiesForDomains = []
        self.cookieHeaderCalled = false
        self.getSAPISIDCalled = false
        self.getSAPISIDCallCount = 0
        self.hasAuthCookiesCalled = false
        self.clearAuthCookiesCalled = false
        self.clearAllDataCalled = false
        self.forceBackupCookiesCalled = false
        self.waitForInitialCookieRestoreCalled = false
        self.waitForInitialCookieRestoreCallCount = 0
        self.logAuthCookiesCalled = false
        self.switchSessionIdentityCalled = false
        self.switchSessionIdentityCallCount = 0
        self.switchSessionIdentityExpectedBrandIds = []
        self.switchSessionIdentityCompletedBrandIds = []
        self.switchSessionIdentityError = nil
        self.switchSessionIdentityErrorQueue = []
        self.switchSessionIdentityGate = nil
        self.switchSessionIdentityGateQueue = []
        self.switchSessionIdentityURLs = []
        self.callSequence = []
        self.allCookies = []
        self.sapisidValue = nil
    }
}
