import Observation
import Testing
@testable import Kaset

@Suite("AuthService cookie restore recovery", .serialized, .tags(.service))
@MainActor
struct AuthServiceCookieRestoreTests {
    @Test("Cancelling an early sign-in resumes startup authentication", arguments: [CookieRestoreResult.ready, .unavailable, .failed])
    func cancellingEarlySignInResumesStartup(restoreResult: CookieRestoreResult) async throws {
        let manager = MockWebKitManager()
        manager.waitForInitialCookieRestoreResult = restoreResult
        manager.sapisidValue = "mock-restored-session"
        let restoreEntered = AsyncGate()
        let releaseRestore = AsyncGate()
        manager.waitForInitialCookieRestoreGate = {
            await restoreEntered.open()
            await releaseRestore.wait()
        }
        let authService = AuthService(webKitManager: manager)
        let startup = Task { @MainActor in
            await authService.checkLoginStatus()
        }
        await restoreEntered.wait()

        authService.startLogin()
        let attemptID = try #require(authService.activeLoginAttemptID)
        #expect(authService.beginLoginCancellation(expectedAttemptID: attemptID))
        await releaseRestore.open()
        await startup.value
        let rollback = await authService.resolveLoginRollbackAfterDraining(
            expectedAttemptID: attemptID,
            prepareRollback: { true },
            rollback: { _ in .rolledBack }
        )
        for _ in 0 ..< 100 where authService.state.isInitializing {
            await Task.yield()
        }

        let expectedState: AuthService.State = restoreResult == .ready
            ? .loggedIn(sapisid: "mock-restored-session")
            : .loggedOut
        #expect(rollback == .rolledBack)
        #expect(authService.state == expectedState)
        #expect(manager.waitForInitialCookieRestoreCallCount == 2)
        #expect(authService.isCookieRestoreUnavailable == (restoreResult == .unavailable))
        #expect(authService.loginCleanupRequired == (restoreResult == .failed))

        if restoreResult == .failed {
            let cleanupAttemptID = try #require(authService.loginCleanupAttemptID)
            #expect(cleanupAttemptID == attemptID)
            let didClear = await authService.clearFailedLoginAfterDraining(
                expectedAttemptID: cleanupAttemptID,
                expectedSignOutSequence: authService.signOutSequence,
                clearCookies: { await manager.clearAllData() }
            )
            #expect(didClear == true)
            #expect(manager.clearAllDataCalled)
            #expect(!authService.loginCleanupRequired)
        }
    }

    @Test("Resolving early sign-in resumes the startup account pipeline", arguments: [true, false])
    func earlySignInResumesAccountResolution(cancels: Bool) async throws {
        let manager = MockWebKitManager()
        manager.sapisidValue = "mock-restored-session"
        let restoreEntered = AsyncGate()
        let releaseRestore = AsyncGate()
        manager.waitForInitialCookieRestoreGate = {
            await restoreEntered.open()
            await releaseRestore.wait()
        }
        let authService = AuthService(webKitManager: manager)
        let client = MockYTMusicClient()
        client.accountsListResponse = AccountsListResponse(
            googleEmail: "owner@example.test",
            accounts: [MockUserAccountData.primaryAccount]
        )
        let accountService = AccountService(ytMusicClient: client, authService: authService)
        let initialState = authService.state
        let startup = Task { @MainActor in
            guard await authService.checkLoginStatusForStartup(expectedState: initialState) else { return false }
            await accountService.fetchAccounts()
            return true
        }
        await restoreEntered.wait()
        authService.startLogin()
        let attemptID = try #require(authService.activeLoginAttemptID)
        if cancels {
            #expect(authService.beginLoginCancellation(expectedAttemptID: attemptID))
        }
        Self.observeStartup(authService: authService, accountService: accountService)
        await releaseRestore.open()
        #expect(await startup.value == false)
        #expect(client.fetchAccountsListCallCount == 0)

        if cancels {
            _ = await authService.resolveLoginRollbackAfterDraining(
                expectedAttemptID: attemptID,
                prepareRollback: { true },
                rollback: { _ in .rolledBack }
            )
        } else {
            authService.completeLogin(sapisid: "mock-restored-session")
        }
        for _ in 0 ..< 100 where !accountService.didCompleteAccountResolution {
            await Task.yield()
        }

        #expect(authService.state.isLoggedIn)
        #expect(client.fetchAccountsListCallCount == 1)
        #expect(accountService.currentAccount?.id == MockUserAccountData.primaryAccount.id)
        #expect(accountService.didCompleteAccountResolution)
        #expect(await authService.checkLoginStatusForStartup(expectedState: initialState) == false)
    }

    @Test("An early sign-in can defer startup and retry without clearing cookies")
    func earlySignInDefersWithoutCleanup() async throws {
        let manager = MockWebKitManager()
        let authService = AuthService(webKitManager: manager)
        authService.startLogin()
        let attemptID = try #require(authService.activeLoginAttemptID)

        authService.deferLoginForCookieRestore(expectedAttemptID: attemptID)

        #expect(authService.state == .loggedOut)
        #expect(authService.activeLoginAttemptID == nil)
        #expect(authService.isCookieRestoreUnavailable)
        #expect(authService.shouldUseCookieFreePlaybackDataStore)
        #expect(!authService.loginCleanupRequired)
        #expect(!manager.invalidateAuthCookieRestorationCalled)

        authService.startLogin()
        let reopenedAttemptID = try #require(authService.activeLoginAttemptID)
        #expect(reopenedAttemptID != attemptID)
        #expect(authService.state == .loggingIn)
        #expect(authService.isCookieRestoreUnavailable)
        authService.deferLoginForCookieRestore(expectedAttemptID: reopenedAttemptID)
        #expect(authService.activeLoginAttemptID == nil)

        manager.sapisidValue = "mock-restored-session"
        await authService.checkLoginStatus()

        #expect(authService.state == .loggedIn(sapisid: "mock-restored-session"))
        #expect(!authService.isCookieRestoreUnavailable)
        #expect(!manager.clearAllDataCalled)
        #expect(!manager.clearAuthCookiesCalled)
    }

    @Test("A queued startup recheck yields to a newer account action", arguments: [true, false])
    func queuedStartupRecheckHonorsNewerAction(signsOut: Bool) async {
        let manager = MockWebKitManager()
        manager.waitForInitialCookieRestoreResult = .unavailable
        let authService = AuthService(webKitManager: manager)
        authService.startLogin()
        authService.cancelLoginIfNeeded()

        if signsOut {
            #expect(await authService.signOut())
        } else {
            authService.startLogin()
        }
        for _ in 0 ..< 100 {
            await Task.yield()
        }

        #expect(authService.state == (signsOut ? .loggedOut : .loggingIn))
        #expect(!authService.isCookieRestoreUnavailable)
        #expect(manager.waitForInitialCookieRestoreCallCount == 0)
    }

    @Test("A stale unavailable restore cannot cancel a replacement login")
    func staleRestoreDoesNotCancelReplacementLogin() throws {
        let authService = AuthService(webKitManager: MockWebKitManager())
        authService.startLogin()
        let staleAttemptID = try #require(authService.activeLoginAttemptID)
        authService.cancelLoginIfNeeded(expectedAttemptID: staleAttemptID)
        authService.startLogin()
        let replacementID = try #require(authService.activeLoginAttemptID)

        authService.deferLoginForCookieRestore(expectedAttemptID: staleAttemptID)

        #expect(authService.activeLoginAttemptID == replacementID)
        #expect(authService.state == .loggingIn)
        #expect(!authService.isCookieRestoreUnavailable)
    }

    @Test("Explicit sign-out ends storage recovery")
    func signOutEndsStorageRecovery() async {
        let manager = MockWebKitManager()
        manager.waitForInitialCookieRestoreResult = .unavailable
        let authService = AuthService(webKitManager: manager)
        await authService.checkLoginStatus()
        #expect(authService.isCookieRestoreUnavailable)

        #expect(await authService.signOut())

        #expect(!authService.isCookieRestoreUnavailable)
        #expect(authService.state == .loggedOut)
        #expect(!authService.needsReauth)
        #expect(manager.clearAllDataCalled)
    }

    private static func observeStartup(authService: AuthService, accountService: AccountService) {
        let state = withObservationTracking {
            authService.state
        } onChange: { [weak authService, weak accountService] in
            Task { @MainActor in
                guard let authService, let accountService else { return }
                Self.observeStartup(authService: authService, accountService: accountService)
            }
        }
        Task { @MainActor [weak authService, weak accountService] in
            guard let authService, let accountService,
                  await authService.checkLoginStatusForStartup(expectedState: state),
                  authService.state == state
            else { return }
            accountService.authenticationIdentityDidChange()
            await accountService.fetchAccounts()
        }
    }
}
