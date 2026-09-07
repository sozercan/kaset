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

    @Test("Startup waits for recovery to finish publishing authentication", arguments: [true, false])
    func startupWaitsForRecoveryPublication(restoresSession: Bool) async {
        let manager = MockWebKitManager()
        manager.waitForInitialCookieRestoreResult = .unavailable
        let authService = AuthService(webKitManager: manager)
        await authService.checkLoginStatus()
        manager.waitForInitialCookieRestoreResult = .ready
        manager.sapisidValue = restoresSession ? "mock-restored-session" : nil
        let cookieReadEntered = AsyncGate()
        let releaseCookieRead = AsyncGate()
        manager.getSAPISIDGate = {
            await cookieReadEntered.open()
            await releaseCookieRead.wait()
        }

        let recovery = Task { @MainActor in
            await authService.checkLoginStatus()
        }
        await cookieReadEntered.wait()
        #expect(authService.isCookieRestoreUnavailable)
        #expect(authService.state == .loggedOut)
        #expect(!authService.shouldPersistGuestPlaybackState)
        #expect(await authService.checkLoginStatusForStartup(expectedState: .loggedOut) == false)
        await releaseCookieRead.open()
        await recovery.value
        #expect(!authService.isCookieRestoreUnavailable)
        #expect(authService.state.isLoggedIn == restoresSession)
        #expect(authService.shouldPersistGuestPlaybackState == !restoresSession)
        #expect(await authService.checkLoginStatusForStartup(expectedState: authService.state))
    }

    @Test("Sign-out supersedes a pending recovery read", arguments: [true, false], [true, false])
    func signOutSupersedesPendingRecovery(waitingForCookie: Bool, canInvalidateRestoration: Bool) async {
        let manager = MockWebKitManager()
        manager.waitForInitialCookieRestoreResult = .unavailable
        let authService = AuthService(webKitManager: manager)
        await authService.checkLoginStatus()
        manager.waitForInitialCookieRestoreResult = .ready
        manager.sapisidValue = "mock-restored-session"
        let readEntered = AsyncGate()
        let releaseRead = AsyncGate()
        let readGate: @Sendable () async -> Void = {
            await readEntered.open()
            await releaseRead.wait()
        }
        if waitingForCookie {
            manager.getSAPISIDGate = readGate
        } else {
            manager.waitForInitialCookieRestoreGate = readGate
        }
        let recovery = Task { @MainActor in
            await authService.checkLoginStatus()
        }
        await readEntered.wait()
        #expect(authService.isCookieRestoreUnavailable)
        #expect(authService.startupState == nil)

        manager.invalidateAuthCookieRestorationResult = canInvalidateRestoration
        #expect(await authService.signOut() == canInvalidateRestoration)
        #expect(authService.isCookieRestoreUnavailable == !canInvalidateRestoration)
        #expect(authService.startupState == (canInvalidateRestoration ? .loggedOut : nil))
        #expect(manager.clearAllDataCalled == canInvalidateRestoration)

        await releaseRead.open()
        await recovery.value
        #expect(authService.state == .loggedOut)
        #expect(authService.needsReauth == !canInvalidateRestoration)
        #expect(authService.isCookieRestoreUnavailable == !canInvalidateRestoration)
    }

    @Test("Recovery cancellation rejects a cookie result before asynchronous sign-out", arguments: [true, false])
    func signOutClickFencesPendingRecovery(canInvalidateRestoration: Bool) async {
        let manager = MockWebKitManager()
        manager.waitForInitialCookieRestoreResult = .unavailable
        let authService = AuthService(webKitManager: manager)
        await authService.checkLoginStatus()
        manager.waitForInitialCookieRestoreResult = .ready
        manager.sapisidValue = "mock-restored-session"
        manager.invalidateAuthCookieRestorationResult = canInvalidateRestoration
        let cookieReadEntered = AsyncGate()
        let releaseCookieRead = AsyncGate()
        manager.getSAPISIDGate = {
            await cookieReadEntered.open()
            await releaseCookieRead.wait()
        }
        let recovery = Task { @MainActor in
            await authService.checkLoginStatus()
        }
        await cookieReadEntered.wait()

        // The Sign Out action cancels recovery before scheduling its async task.
        authService.cancelLoginStatusCheck()
        recovery.cancel()
        // A queued cookie callback can run before that sign-out task starts.
        await releaseCookieRead.open()
        await recovery.value
        #expect(authService.state == .loggedOut)
        #expect(authService.isCookieRestoreUnavailable)
        #expect(authService.startupState == nil)

        #expect(await authService.signOut() == canInvalidateRestoration)
        #expect(authService.state == .loggedOut)
        #expect(authService.isCookieRestoreUnavailable == !canInvalidateRestoration)
    }

    @Test("Cancelled status callers cannot restart cookie recovery")
    func cancelledStatusCallerDoesNotStartRecovery() async {
        let manager = MockWebKitManager()
        manager.waitForInitialCookieRestoreResult = .unavailable
        let authService = AuthService(webKitManager: manager)
        await authService.checkLoginStatus()
        manager.waitForInitialCookieRestoreResult = .ready
        manager.sapisidValue = "mock-restored-session"
        let startRetry = AsyncGate()
        let recovery = Task { @MainActor in
            await startRetry.wait()
            await authService.checkLoginStatus()
        }

        recovery.cancel()
        await startRetry.open()
        await recovery.value

        #expect(authService.state == .loggedOut)
        #expect(authService.isCookieRestoreUnavailable)
        #expect(manager.waitForInitialCookieRestoreCallCount == 1)
        #expect(manager.getSAPISIDCallCount == 0)
    }

    private static func observeStartup(authService: AuthService, accountService: AccountService) {
        let state = withObservationTracking {
            authService.startupState
        } onChange: { [weak authService, weak accountService] in
            Task { @MainActor in
                guard let authService, let accountService else { return }
                Self.observeStartup(authService: authService, accountService: accountService)
            }
        }
        Task { @MainActor [weak authService, weak accountService] in
            guard let state, let authService, let accountService,
                  await authService.checkLoginStatusForStartup(expectedState: state),
                  authService.startupState == state
            else { return }
            accountService.authenticationIdentityDidChange()
            await accountService.fetchAccounts()
        }
    }
}
