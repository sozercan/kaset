import Foundation
import Testing
@testable import Kaset

/// Login transactions share the process-wide restore-policy generation with
/// quarantine tests, so keep recovery cases in the same serialized suite.
extension WebKitCookieRestoreTests {
    @Test("Unavailable startup storage preserves authentication without requiring cleanup", arguments: [true, false])
    func unavailableStartupDoesNotRequireCleanup(policyUnavailable: Bool) async throws {
        let storage = CookieRecoveryStorage()
        storage.update {
            $0.policy = policyUnavailable ? .unavailable : .allowed
            $0.readFails = !policyUnavailable
        }
        let manager = WebKitManager.makeTestInstance(cookieArchiveStorage: storage.interface)
        let cookie = try Self.makeRecoveryCookie(name: "SAPISID", domain: ".youtube.com")
        await manager.dataStore.httpCookieStore.setCookie(cookie)
        let authService = AuthService(webKitManager: manager)

        manager.startInitialCookieRestore()
        await authService.checkLoginStatus()

        #expect(!authService.loginCleanupRequired)
        #expect(authService.isCookieRestoreUnavailable)
        #expect(authService.shouldUseCookieFreePlaybackDataStore)
        #expect(await manager.getSAPISID() == "mock-session")
        #expect(storage.snapshot.deleteCount == 0)
        manager.cookieDebounceTask?.cancel()
    }

    @Test("Retry restores the saved session and concurrent callers share the read", arguments: [true, false])
    func retryRestoresSavedSession(policyUnavailable: Bool) async throws {
        let storage = CookieRecoveryStorage()
        let cookie = try Self.makeRecoveryCookie(name: "SAPISID", domain: ".youtube.com")
        let archive = try #require(KeychainCookieStorage.makeArchiveData(from: [cookie]))
        storage.update {
            $0.archive = archive.data
            $0.policy = policyUnavailable ? .unavailable : .allowed
            $0.readFails = !policyUnavailable
        }
        let manager = WebKitManager.makeTestInstance(cookieArchiveStorage: storage.interface)
        try await manager.dataStore.httpCookieStore.setCookie(
            Self.makeRecoveryCookie(name: "SAPISID", domain: ".youtube.com", value: "mock-stale-session")
        )
        let authService = AuthService(webKitManager: manager)
        manager.startInitialCookieRestore()
        await authService.checkLoginStatus()
        #expect(authService.isCookieRestoreUnavailable)
        let readsBeforeRetry = storage.snapshot.loadCount
        storage.update {
            $0.policy = .allowed
            $0.readFails = false
        }

        async let first: Void = authService.checkLoginStatus()
        async let second: Void = authService.checkLoginStatus()
        _ = await (first, second)

        #expect(authService.state == .loggedIn(sapisid: cookie.value))
        #expect(!authService.isCookieRestoreUnavailable)
        #expect(!authService.loginCleanupRequired)
        #expect(!authService.needsReauth)
        #expect(manager.canPersistAuthCookies)
        #expect(storage.snapshot.loadCount == readsBeforeRetry + 1)
        #expect(storage.snapshot.archive == archive.data)
        #expect(storage.snapshot.deleteCount == 0)
        #expect(await manager.getSAPISID() == cookie.value)
        _ = await manager.clearAllData()
    }

    @Test("Retry honors a newly readable sign-out denial")
    func retryHonorsDeniedRestore() async throws {
        let storage = CookieRecoveryStorage()
        storage.update {
            $0.policy = .unavailable
            $0.archive = Data("mock-retained-archive".utf8)
        }
        let manager = WebKitManager.makeTestInstance(cookieArchiveStorage: storage.interface)
        try await manager.dataStore.httpCookieStore.setCookie(
            Self.makeRecoveryCookie(name: "SAPISID", domain: ".youtube.com")
        )
        let authService = AuthService(webKitManager: manager)
        manager.startInitialCookieRestore()
        await authService.checkLoginStatus()
        storage.update { $0.policy = .denied }

        await authService.checkLoginStatus()

        #expect(authService.state == .loggedOut)
        #expect(!authService.isCookieRestoreUnavailable)
        #expect(!authService.loginCleanupRequired)
        #expect(!authService.needsReauth)
        #expect(await manager.getSAPISID() == nil)
        #expect(storage.snapshot.archive == nil)
        #expect(storage.snapshot.deleteCount == 1)
    }

    @Test("Clearing data fences an in-flight startup retry")
    func clearingDataFencesRetry() async throws {
        let storage = CookieRecoveryStorage()
        storage.update { $0.policy = .unavailable }
        let manager = WebKitManager.makeTestInstance(cookieArchiveStorage: storage.interface)
        manager.startInitialCookieRestore()
        #expect(await manager.waitForInitialCookieRestore() == .unavailable)
        let cookie = try Self.makeRecoveryCookie(name: "SAPISID", domain: ".youtube.com")
        let archive = try #require(KeychainCookieStorage.makeArchiveData(from: [cookie]))
        storage.update {
            $0.policy = .allowed
            $0.archive = archive.data
        }

        manager.startInitialCookieRestore()
        let retry = try #require(manager.initialCookieRestoreTask)
        #expect(await manager.clearAllData())
        _ = await retry.value

        #expect(await manager.waitForInitialCookieRestore() == .ready)
        #expect(await manager.getAllCookies().isEmpty)
        #expect(storage.snapshot.archive == nil)
        #expect(storage.snapshot.policy == .denied)
    }

    @Test("Recovery cleanup requires the retained deferred attempt identity")
    func invalidArchiveRecoveryRetainsCleanupOwnership() async throws {
        let storage = CookieRecoveryStorage()
        storage.update { $0.policy = .unavailable }
        let manager = WebKitManager.makeTestInstance(cookieArchiveStorage: storage.interface)
        let authService = AuthService(webKitManager: manager)
        manager.startInitialCookieRestore()
        await authService.checkLoginStatus()
        authService.startLogin()
        let attemptID = try #require(authService.activeLoginAttemptID)
        authService.deferLoginForCookieRestore(expectedAttemptID: attemptID)
        #expect(authService.activeLoginAttemptID == nil)

        storage.update {
            $0.policy = .allowed
            $0.archive = Data("mock-invalid-archive".utf8)
        }
        await authService.checkLoginStatus()
        #expect(!authService.isCookieRestoreUnavailable)
        #expect(authService.loginCleanupRequired)

        let missingIdentityResult = await authService.clearFailedLoginAfterDraining(
            expectedAttemptID: LoginAttemptID(rawValue: 0),
            expectedSignOutSequence: authService.signOutSequence,
            clearCookies: { await manager.clearAllData() }
        )
        #expect(missingIdentityResult == nil)
        #expect(storage.snapshot.archive != nil)

        let retainedIdentityResult = await authService.clearFailedLoginAfterDraining(
            expectedAttemptID: attemptID,
            expectedSignOutSequence: authService.signOutSequence,
            clearCookies: { await manager.clearAllData() }
        )
        #expect(retainedIdentityResult == true)
        #expect(!authService.loginCleanupRequired)
        #expect(authService.state == .loggedOut)
        #expect(storage.snapshot.archive == nil)
        #expect(manager.canPersistAuthCookies)
    }

    @Test("Deferred restore blocks observer and forced archive writes", arguments: [true, false])
    func deferredRestoreBlocksBackups(hasPrimarySession: Bool) async throws {
        let storage = CookieRecoveryStorage()
        let originalArchive = Data("mock-retained-archive".utf8)
        storage.update {
            $0.policy = .unavailable
            $0.archive = originalArchive
        }
        let manager = WebKitManager.makeTestInstance(cookieArchiveStorage: storage.interface)
        if hasPrimarySession {
            try await manager.dataStore.httpCookieStore.setCookie(
                Self.makeRecoveryCookie(name: "SAPISID", domain: ".youtube.com")
            )
        }

        manager.startInitialCookieRestore()
        _ = await manager.waitForInitialCookieRestore()
        #expect(await manager.forceBackupCookies() == false)
        manager.handleObservedCookieChange(in: manager.dataStore.httpCookieStore)
        await manager.cookieDebounceTask?.value

        #expect(storage.snapshot.archive == originalArchive)
        #expect(storage.snapshot.saveCount == 0)
        #expect(storage.snapshot.deleteCount == 0)
    }

    @Test("A partial Google session survives login preparation and cancellation", arguments: [true, false])
    func partialSessionCanBeginAndRollbackLogin(startsUnavailable: Bool) async throws {
        let storage = CookieRecoveryStorage()
        storage.update { $0.policy = startsUnavailable ? .unavailable : .allowed }
        let manager = WebKitManager.makeTestInstance(cookieArchiveStorage: storage.interface)
        let googleCookie = try Self.makeRecoveryCookie(name: "SID", domain: ".google.com")
        await manager.dataStore.httpCookieStore.setCookie(googleCookie)
        let authService = AuthService(webKitManager: manager)
        manager.startInitialCookieRestore()
        await authService.checkLoginStatus()
        if startsUnavailable {
            storage.update { $0.policy = .allowed }
            await authService.checkLoginStatus()
        }
        #expect(authService.state == .loggedOut)
        #expect(!authService.isCookieRestoreUnavailable)
        #expect(!authService.needsReauth)
        authService.startLogin()
        let attemptID = try #require(authService.activeLoginAttemptID)

        let transaction = await manager.beginLoginCookieBackup()
        #expect(transaction != nil)
        #expect(!manager.loginCookieBackupSetupRequiresCleanup)
        guard let transaction else { return }

        try await manager.dataStore.httpCookieStore.setCookie(
            Self.makeRecoveryCookie(name: "SAPISID", domain: ".youtube.com")
        )
        let rollback = await authService.resolveLoginRollbackAfterDraining(
            expectedAttemptID: attemptID,
            prepareRollback: { await manager.prepareLoginCookieBackupRollback(transaction) },
            rollback: { _ in await manager.rollbackLoginCookieBackup(transaction) }
        )
        #expect(rollback == .rolledBack)
        #expect(authService.state == .loggedOut)
        #expect(!authService.loginCleanupRequired)
        let cookies = await manager.getAllCookies()
        #expect(cookies.count == 1)
        #expect(cookies.first?.name == googleCookie.name)
        #expect(cookies.first?.value == googleCookie.value)
        _ = await manager.clearAllData()
    }

    private static func makeRecoveryCookie(
        name: String,
        domain: String,
        value: String = "mock-session"
    ) throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
            .expires: Date().addingTimeInterval(3600),
        ]))
    }
}

// MARK: - CookieRecoveryStorage

private final class CookieRecoveryStorage: @unchecked Sendable {
    struct State {
        var policy: CookieArchiveRestoreDecision = .allowed
        var archive: Data?
        var readFails = false
        var loadCount = 0
        var saveCount = 0
        var deleteCount = 0
    }

    private let lock = NSLock()
    private var state = State()

    var snapshot: State {
        self.lock.withLock { self.state }
    }

    func update(_ operation: (inout State) -> Void) {
        self.lock.withLock { operation(&self.state) }
    }

    var interface: CookieArchiveStorage {
        CookieArchiveStorage(
            save: { data, _ in
                self.update {
                    $0.archive = data
                    $0.saveCount += 1
                }
                return true
            },
            loadResult: {
                self.lock.withLock {
                    self.state.loadCount += 1
                    guard !self.state.readFails else { return .failure }
                    guard let data = self.state.archive else { return .notFound }
                    return .data(data)
                }
            },
            delete: {
                self.update {
                    $0.archive = nil
                    $0.deleteCount += 1
                }
                return true
            },
            restoreDecision: { self.snapshot.policy },
            setRestoreAllowed: { allowed in
                self.update { $0.policy = allowed ? .allowed : .denied }
                return true
            }
        )
    }
}
