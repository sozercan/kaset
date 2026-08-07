import Foundation
@testable import Kaset

/// A mock implementation of WebKitManagerProtocol for testing.
/// Does not interact with real WebKit or file storage.
@MainActor
final class MockWebKitManager: WebKitManagerProtocol {
    // MARK: - Response Stubs

    var allCookies: [HTTPCookie] = []
    var sapisidValue: String?
    var getSAPISIDGate: (@Sendable () async -> Void)?
    var clearAuthCookiesGate: (@Sendable () async -> Void)?
    var clearAllDataGate: (@Sendable () async -> Void)?
    var forceBackupCookiesGate: (@Sendable () async -> Void)?
    var finalizeLoginCookieBackupGate: (@Sendable () async -> Void)?
    var invalidateAuthCookieRestorationResult = true
    var clearAuthCookiesResult = true
    var clearAllDataResult = true
    var forceBackupCookiesResult = true
    var forceBackupCookiesResults: [Bool] = []
    var beginLoginCookieBackupResult = true
    var commitLoginCookieBackupResult = true
    var finalizeLoginCookieBackupResult = true
    var loginCookieSessionValue = "candidate-session"
    var loginCookieSessionValues: [String] = []
    var loginCookieSnapshotChanged = true
    var rollbackLoginCookieBackupResult: CookieBackupRollbackResult = .rolledBack
    var loginCookieBackupSetupRequiresCleanup = false
    var waitForInitialCookieRestoreResult = true

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
    private(set) var invalidateAuthCookieRestorationCalled = false
    private(set) var clearAuthCookiesCalled = false
    private(set) var clearAllDataCalled = false
    private(set) var forceBackupCookiesCalled = false
    private(set) var forceBackupCookiesCallCount = 0
    private(set) var beginLoginCookieBackupCallCount = 0
    private(set) var refreshLoginCookieBackupCallCount = 0
    private(set) var commitLoginCookieBackupCallCount = 0
    private(set) var finalizeLoginCookieBackupCallCount = 0
    private(set) var rollbackLoginCookieBackupCallCount = 0
    private var nextCookieBackupTransactionID: UInt64 = 0
    private var activeCookieBackupTransaction: CookieBackupTransaction?
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
        await self.getSAPISIDGate?()
        return self.sapisidValue
    }

    func hasAuthCookies() async -> Bool {
        self.hasAuthCookiesCalled = true
        return self.sapisidValue != nil
    }

    @discardableResult
    func invalidateAuthCookieRestoration() -> Bool {
        self.invalidateAuthCookieRestorationCalled = true
        self.callSequence.append("invalidateAuthCookieRestoration")
        return self.invalidateAuthCookieRestorationResult
    }

    @discardableResult
    func clearAuthCookies() async -> Bool {
        self.clearAuthCookiesCalled = true
        self.callSequence.append("clearAuthCookies")
        await self.clearAuthCookiesGate?()
        self.sapisidValue = nil
        self.activeCookieBackupTransaction = nil
        self.allCookies.removeAll(where: KeychainCookieStorage.isAuthCookie)
        self.loginCookieBackupSetupRequiresCleanup = !self.clearAuthCookiesResult
        return self.clearAuthCookiesResult
    }

    @discardableResult
    func clearAllData() async -> Bool {
        self.clearAllDataCalled = true
        self.callSequence.append("clearAllData")
        await self.clearAllDataGate?()
        // Does NOT clear real data - this is a mock
        self.allCookies = []
        self.sapisidValue = nil
        self.activeCookieBackupTransaction = nil
        self.loginCookieBackupSetupRequiresCleanup = !self.clearAllDataResult
        return self.clearAllDataResult
    }

    func forceBackupCookies() async -> Bool {
        self.forceBackupCookiesCalled = true
        self.forceBackupCookiesCallCount += 1
        self.callSequence.append("forceBackupCookies")
        await self.forceBackupCookiesGate?()
        // Does NOT interact with real file storage
        if !self.forceBackupCookiesResults.isEmpty {
            return self.forceBackupCookiesResults.removeFirst()
        }
        return self.forceBackupCookiesResult
    }

    func beginLoginCookieBackup() async -> CookieBackupTransaction? {
        self.beginLoginCookieBackupCallCount += 1
        self.callSequence.append("beginLoginCookieBackup")
        guard self.beginLoginCookieBackupResult else { return nil }
        self.nextCookieBackupTransactionID &+= 1
        let transaction = CookieBackupTransaction.testing(id: self.nextCookieBackupTransactionID)
        self.activeCookieBackupTransaction = transaction
        return transaction
    }

    func isLoginCookieBackupActive(_ transaction: CookieBackupTransaction) async -> Bool {
        self.activeCookieBackupTransaction?.matches(transaction) == true
    }

    func hasLoginCookieSnapshotChanged(_ transaction: CookieBackupTransaction) async -> Bool {
        self.activeCookieBackupTransaction?.matches(transaction) == true
            && self.loginCookieSnapshotChanged
    }

    func refreshLoginCookieBackup(_: CookieBackupTransaction) async -> Bool {
        self.refreshLoginCookieBackupCallCount += 1
        self.callSequence.append("refreshLoginCookieBackup")
        return await self.forceBackupCookies()
    }

    func commitLoginCookieBackup(
        _ transaction: CookieBackupTransaction
    ) async -> String? {
        self.commitLoginCookieBackupCallCount += 1
        self.callSequence.append("commitLoginCookieBackup")
        guard await self.refreshLoginCookieBackup(transaction),
              self.commitLoginCookieBackupResult
        else { return nil }
        if !self.loginCookieSessionValues.isEmpty {
            return self.loginCookieSessionValues.removeFirst()
        }
        return self.loginCookieSessionValue
    }

    func finalizeLoginCookieBackup(
        _: CookieBackupTransaction
    ) async -> String? {
        self.finalizeLoginCookieBackupCallCount += 1
        self.callSequence.append("finalizeLoginCookieBackup")
        await self.finalizeLoginCookieBackupGate?()
        guard self.finalizeLoginCookieBackupResult else { return nil }
        let finalSessionValue: String = if !self.loginCookieSessionValues.isEmpty {
            self.loginCookieSessionValues.removeFirst()
        } else {
            self.loginCookieSessionValue
        }
        guard self.loginCookieSnapshotChanged else { return nil }
        self.activeCookieBackupTransaction = nil
        return finalSessionValue
    }

    func prepareLoginCookieBackupRollback(
        _: CookieBackupTransaction
    ) async -> Bool {
        self.callSequence.append("prepareLoginCookieBackupRollback")
        return true
    }

    func rollbackLoginCookieBackup(
        _: CookieBackupTransaction
    ) async -> CookieBackupRollbackResult {
        self.rollbackLoginCookieBackupCallCount += 1
        self.callSequence.append("rollbackLoginCookieBackup")
        if self.rollbackLoginCookieBackupResult != .failed {
            self.activeCookieBackupTransaction = nil
        }
        return self.rollbackLoginCookieBackupResult
    }

    func waitForInitialCookieRestore() async -> Bool {
        self.waitForInitialCookieRestoreCalled = true
        self.waitForInitialCookieRestoreCallCount += 1
        self.callSequence.append("waitForInitialCookieRestore")
        return self.waitForInitialCookieRestoreResult
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
        self.getSAPISIDGate = nil
        self.hasAuthCookiesCalled = false
        self.invalidateAuthCookieRestorationCalled = false
        self.invalidateAuthCookieRestorationResult = true
        self.clearAuthCookiesCalled = false
        self.clearAuthCookiesGate = nil
        self.clearAuthCookiesResult = true
        self.clearAllDataCalled = false
        self.clearAllDataGate = nil
        self.clearAllDataResult = true
        self.forceBackupCookiesCalled = false
        self.forceBackupCookiesCallCount = 0
        self.forceBackupCookiesGate = nil
        self.finalizeLoginCookieBackupGate = nil
        self.forceBackupCookiesResult = true
        self.forceBackupCookiesResults = []
        self.beginLoginCookieBackupResult = true
        self.commitLoginCookieBackupResult = true
        self.finalizeLoginCookieBackupResult = true
        self.loginCookieSessionValue = "candidate-session"
        self.loginCookieSessionValues = []
        self.rollbackLoginCookieBackupResult = .rolledBack
        self.loginCookieBackupSetupRequiresCleanup = false
        self.waitForInitialCookieRestoreResult = true
        self.beginLoginCookieBackupCallCount = 0
        self.refreshLoginCookieBackupCallCount = 0
        self.commitLoginCookieBackupCallCount = 0
        self.finalizeLoginCookieBackupCallCount = 0
        self.rollbackLoginCookieBackupCallCount = 0
        self.nextCookieBackupTransactionID = 0
        self.activeCookieBackupTransaction = nil
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
