import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct LoginCompletionGateTests {
    @Test("Persistence failure prevents login completion")
    func persistenceFailurePreventsLoginCompletion() async {
        let webKitManager = MockWebKitManager()
        webKitManager.forceBackupCookiesResult = false
        let authService = AuthService(webKitManager: webKitManager)
        authService.startLogin()
        guard let attemptID = authService.activeLoginAttemptID else {
            Issue.record("Expected an active login attempt")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )
        guard let transaction = await webKitManager.beginLoginCookieBackup() else {
            Issue.record("Expected a cookie backup transaction")
            return
        }

        let didComplete = await gate.complete(
            expectedAttemptID: attemptID,
            transaction: transaction
        )

        #expect(!didComplete)
        #expect(webKitManager.beginLoginCookieBackupCallCount == 1)
        #expect(webKitManager.forceBackupCookiesCallCount == 1)
        #expect(webKitManager.commitLoginCookieBackupCallCount == 1)
        #expect(webKitManager.finalizeLoginCookieBackupCallCount == 0)
        #expect(authService.state == .initializing)
    }

    @Test("Cancellation while persistence is in flight rolls back and prevents login completion")
    func cancellationWhilePersistenceIsInFlight() async {
        let webKitManager = MockWebKitManager()
        let backupStarted = AsyncGate()
        let releaseBackup = AsyncGate()
        webKitManager.forceBackupCookiesGate = {
            await backupStarted.open()
            await releaseBackup.wait()
        }
        let authService = AuthService(webKitManager: webKitManager)
        authService.startLogin()
        guard let attemptID = authService.activeLoginAttemptID else {
            Issue.record("Expected an active login attempt")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )
        guard let transaction = await webKitManager.beginLoginCookieBackup() else {
            Issue.record("Expected a cookie backup transaction")
            return
        }

        let completionTask = Task { @MainActor in
            await gate.complete(
                expectedAttemptID: attemptID,
                transaction: transaction
            )
        }
        await backupStarted.wait()
        completionTask.cancel()
        await releaseBackup.open()

        let didComplete = await completionTask.value
        #expect(!didComplete)
        #expect(webKitManager.rollbackLoginCookieBackupCallCount == 1)
        #expect(authService.state == .initializing)
    }

    @Test("A newer login attempt supersedes detection while persistence is in flight")
    func newerAttemptDuringPersistenceIsRejected() async {
        let webKitManager = MockWebKitManager()
        let backupStarted = AsyncGate()
        let releaseBackup = AsyncGate()
        webKitManager.forceBackupCookiesGate = {
            await backupStarted.open()
            await releaseBackup.wait()
        }
        let authService = AuthService(webKitManager: webKitManager)
        authService.startLogin()
        guard let staleAttemptID = authService.activeLoginAttemptID else {
            Issue.record("Expected an active login attempt")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )
        guard let transaction = await webKitManager.beginLoginCookieBackup() else {
            Issue.record("Expected a cookie backup transaction")
            return
        }

        let completionTask = Task { @MainActor in
            await gate.complete(
                expectedAttemptID: staleAttemptID,
                transaction: transaction
            )
        }
        await backupStarted.wait()
        authService.cancelLoginIfNeeded(expectedAttemptID: staleAttemptID)
        authService.startLogin()
        let replacementAttemptID = authService.activeLoginAttemptID
        await releaseBackup.open()

        let didComplete = await completionTask.value
        #expect(!didComplete)
        #expect(replacementAttemptID != staleAttemptID)
        #expect(authService.activeLoginAttemptID == replacementAttemptID)
        #expect(webKitManager.rollbackLoginCookieBackupCallCount == 1)
        #expect(!webKitManager.clearAllDataCalled)
        #expect(authService.state == .loggingIn)
    }

    @Test("Fallback cookie clearing preserves ordinary guest semantics")
    func fallbackCookieClearingPreservesGuestSemantics() async {
        let webKitManager = MockWebKitManager()
        webKitManager.commitLoginCookieBackupResult = false
        webKitManager.rollbackLoginCookieBackupResult = .failed
        let authService = AuthService(webKitManager: webKitManager)
        await authService.checkLoginStatus()
        authService.startLogin()
        guard let attemptID = authService.activeLoginAttemptID,
              let transaction = await webKitManager.beginLoginCookieBackup()
        else {
            Issue.record("Expected active login and cookie transaction")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )

        let didComplete = await gate.complete(
            expectedAttemptID: attemptID,
            transaction: transaction
        )

        #expect(!didComplete)
        #expect(authService.state == .loggedOut)
        #expect(!authService.needsReauth)
        #expect(authService.shouldUseCookieFreePlaybackDataStore)
        #expect(authService.shouldPersistGuestPlaybackState)
    }

    @Test("Fallback cookie clearing expires the prior authenticated state")
    func fallbackCookieClearingExpiresPriorAuthentication() async {
        let webKitManager = MockWebKitManager()
        webKitManager.commitLoginCookieBackupResult = false
        webKitManager.rollbackLoginCookieBackupResult = .failed
        let authService = AuthService(webKitManager: webKitManager)
        authService.completeLogin(sapisid: "existing-session")
        authService.startLogin()
        guard let attemptID = authService.activeLoginAttemptID,
              let transaction = await webKitManager.beginLoginCookieBackup()
        else {
            Issue.record("Expected active login and cookie transaction")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )

        let didComplete = await gate.complete(
            expectedAttemptID: attemptID,
            transaction: transaction
        )

        #expect(!didComplete)
        #expect(webKitManager.clearAllDataCalled)
        #expect(authService.state == .loggedOut)
        #expect(authService.needsReauth)
        #expect(!authService.loginCleanupRequired)
    }

    @Test("Stable persistence commits the active login attempt")
    func stablePersistenceCommitsLogin() async {
        let webKitManager = MockWebKitManager()
        let authService = AuthService(webKitManager: webKitManager)
        authService.startLogin()
        guard let attemptID = authService.activeLoginAttemptID else {
            Issue.record("Expected an active login attempt")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )
        guard let transaction = await webKitManager.beginLoginCookieBackup() else {
            Issue.record("Expected a cookie backup transaction")
            return
        }

        let didComplete = await gate.complete(
            expectedAttemptID: attemptID,
            transaction: transaction
        )

        #expect(didComplete)
        #expect(webKitManager.forceBackupCookiesCallCount == 1)
        #expect(webKitManager.refreshLoginCookieBackupCallCount == 1)
        #expect(webKitManager.commitLoginCookieBackupCallCount == 1)
        #expect(webKitManager.finalizeLoginCookieBackupCallCount == 1)
        #expect(webKitManager.rollbackLoginCookieBackupCallCount == 0)
        #expect(authService.state.isLoggedIn)
    }

    @Test("Final cookie rotation updates the published session value")
    func finalCookieRotationUpdatesPublishedSession() async {
        let webKitManager = MockWebKitManager()
        webKitManager.loginCookieSessionValues = ["session-before-finalize", "session-after-finalize"]
        let authService = AuthService(webKitManager: webKitManager)
        authService.startLogin()
        guard let attemptID = authService.activeLoginAttemptID,
              let transaction = await webKitManager.beginLoginCookieBackup()
        else {
            Issue.record("Expected active login and cookie transaction")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )

        let didComplete = await gate.complete(
            expectedAttemptID: attemptID,
            transaction: transaction
        )

        #expect(didComplete)
        #expect(authService.state == .loggedIn(sapisid: "session-after-finalize"))
    }

    @Test("Final cookie capture runs inside the account-boundary drain")
    func finalCookieCaptureRunsInsideDrain() async {
        let webKitManager = MockWebKitManager()
        let drainCount = LockedCounter()
        webKitManager.finalizeLoginCookieBackupGate = {
            #expect(drainCount.count == 1)
        }
        let authService = AuthService(webKitManager: webKitManager)
        authService.setAccountBoundaryHandlers(
            willBegin: {},
            didEnd: {},
            drain: { drainCount.increment() }
        )
        authService.startLogin()
        guard let attemptID = authService.activeLoginAttemptID,
              let transaction = await webKitManager.beginLoginCookieBackup()
        else {
            Issue.record("Expected active login and cookie transaction")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )

        let didComplete = await gate.complete(
            expectedAttemptID: attemptID,
            transaction: transaction
        )

        #expect(didComplete)
        #expect(drainCount.count == 1)
    }

    @Test("Login completion rejects an unchanged cookie snapshot")
    func revertedSessionIsRejected() async {
        let webKitManager = MockWebKitManager()
        webKitManager.loginCookieSessionValue = "existing-session"
        webKitManager.loginCookieSnapshotChanged = false
        let authService = AuthService(webKitManager: webKitManager)
        authService.completeLogin(sapisid: "existing-session")
        authService.startLogin()
        guard let attemptID = authService.activeLoginAttemptID,
              let transaction = await webKitManager.beginLoginCookieBackup()
        else {
            Issue.record("Expected active login and cookie transaction")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )

        let didComplete = await gate.complete(
            expectedAttemptID: attemptID,
            transaction: transaction
        )

        #expect(!didComplete)
        #expect(webKitManager.rollbackLoginCookieBackupCallCount == 1)
        #expect(authService.state == .loggedIn(sapisid: "existing-session"))
    }

    @Test("Same primary cookie value completes when the cookie snapshot changed")
    func samePrimaryCookieValueCompletesAfterSnapshotChange() async {
        let webKitManager = MockWebKitManager()
        webKitManager.loginCookieSessionValue = "existing-session"
        let authService = AuthService(webKitManager: webKitManager)
        authService.completeLogin(sapisid: "existing-session")
        authService.startLogin()
        guard let attemptID = authService.activeLoginAttemptID,
              let transaction = await webKitManager.beginLoginCookieBackup()
        else {
            Issue.record("Expected active login and cookie transaction")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )

        let didComplete = await gate.complete(
            expectedAttemptID: attemptID,
            transaction: transaction
        )

        #expect(didComplete)
        #expect(webKitManager.rollbackLoginCookieBackupCallCount == 0)
        #expect(authService.state == .loggedIn(sapisid: "existing-session"))
    }

    @Test("Finalization rejects a snapshot that reverts to the pre-login state")
    func finalRevertedSessionIsRejected() async {
        let webKitManager = MockWebKitManager()
        webKitManager.loginCookieSessionValues = ["replacement-session", "existing-session"]
        webKitManager.loginCookieSnapshotChanged = false
        let authService = AuthService(webKitManager: webKitManager)
        authService.completeLogin(sapisid: "existing-session")
        authService.startLogin()
        guard let attemptID = authService.activeLoginAttemptID,
              let transaction = await webKitManager.beginLoginCookieBackup()
        else {
            Issue.record("Expected active login and cookie transaction")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )

        let didComplete = await gate.complete(
            expectedAttemptID: attemptID,
            transaction: transaction
        )

        #expect(!didComplete)
        #expect(webKitManager.finalizeLoginCookieBackupCallCount == 1)
        #expect(!webKitManager.clearAllDataCalled)
        #expect(authService.state == .loggedIn(sapisid: "existing-session"))
    }

    @Test("Cancellation during transaction finalization expires the new session")
    func cancellationDuringFinalizationExpiresSession() async {
        let webKitManager = MockWebKitManager()
        webKitManager.rollbackLoginCookieBackupResult = .failed
        let finalizationStarted = AsyncGate()
        let releaseFinalization = AsyncGate()
        webKitManager.finalizeLoginCookieBackupGate = {
            await finalizationStarted.open()
            await releaseFinalization.wait()
        }
        let authService = AuthService(webKitManager: webKitManager)
        authService.startLogin()
        guard let attemptID = authService.activeLoginAttemptID,
              let transaction = await webKitManager.beginLoginCookieBackup()
        else {
            Issue.record("Expected active login and cookie transaction")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )

        let completionTask = Task { @MainActor in
            await gate.complete(
                expectedAttemptID: attemptID,
                transaction: transaction
            )
        }
        await finalizationStarted.wait()
        completionTask.cancel()
        await releaseFinalization.open()

        #expect(await completionTask.value == false)
        #expect(webKitManager.clearAllDataCalled)
        #expect(authService.state == .loggedOut)
    }

    @Test("Finalization failure rolls back before clearing credentials")
    func finalizationFailureUsesRollbackWhenAvailable() async {
        let webKitManager = MockWebKitManager()
        webKitManager.finalizeLoginCookieBackupResult = false
        let authService = AuthService(webKitManager: webKitManager)
        authService.startLogin()
        guard let attemptID = authService.activeLoginAttemptID,
              let transaction = await webKitManager.beginLoginCookieBackup()
        else {
            Issue.record("Expected active login and cookie transaction")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )

        let didComplete = await gate.complete(
            expectedAttemptID: attemptID,
            transaction: transaction
        )

        #expect(!didComplete)
        #expect(webKitManager.rollbackLoginCookieBackupCallCount == 1)
        #expect(!webKitManager.clearAllDataCalled)
        #expect(authService.state == .initializing)
        #expect(!authService.loginCleanupRequired)
    }

    @Test("Superseded finalization rollback clears owned credentials")
    func supersededFinalizationRollbackClearsOwnedCredentials() async {
        let webKitManager = MockWebKitManager()
        webKitManager.finalizeLoginCookieBackupResult = false
        webKitManager.rollbackLoginCookieBackupResult = .superseded
        let authService = AuthService(webKitManager: webKitManager)
        authService.startLogin()
        guard let attemptID = authService.activeLoginAttemptID,
              let transaction = await webKitManager.beginLoginCookieBackup()
        else {
            Issue.record("Expected active login and cookie transaction")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )

        let didComplete = await gate.complete(
            expectedAttemptID: attemptID,
            transaction: transaction
        )

        #expect(!didComplete)
        #expect(webKitManager.rollbackLoginCookieBackupCallCount == 1)
        #expect(webKitManager.clearAllDataCalled)
        #expect(authService.state == .loggedOut)
        #expect(!authService.loginCleanupRequired)
    }

    @Test("Transaction finalization failure expires the new session")
    func finalizationFailureExpiresSession() async {
        let webKitManager = MockWebKitManager()
        webKitManager.finalizeLoginCookieBackupResult = false
        webKitManager.rollbackLoginCookieBackupResult = .failed
        let authService = AuthService(webKitManager: webKitManager)
        authService.startLogin()
        guard let attemptID = authService.activeLoginAttemptID,
              let transaction = await webKitManager.beginLoginCookieBackup()
        else {
            Issue.record("Expected active login and cookie transaction")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )

        let didComplete = await gate.complete(
            expectedAttemptID: attemptID,
            transaction: transaction
        )

        #expect(!didComplete)
        #expect(webKitManager.finalizeLoginCookieBackupCallCount == 1)
        #expect(webKitManager.clearAllDataCalled)
        #expect(authService.state == .loggedOut)
    }

    @Test("Failed durable cleanup opens a cleanup recovery attempt")
    func failedDurableCleanupOpensRecoveryAttempt() async {
        let webKitManager = MockWebKitManager()
        webKitManager.finalizeLoginCookieBackupResult = false
        webKitManager.rollbackLoginCookieBackupResult = .failed
        webKitManager.clearAllDataResult = false
        let authService = AuthService(webKitManager: webKitManager)
        authService.startLogin()
        guard let attemptID = authService.activeLoginAttemptID,
              let transaction = await webKitManager.beginLoginCookieBackup()
        else {
            Issue.record("Expected active login and cookie transaction")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )

        let didComplete = await gate.complete(
            expectedAttemptID: attemptID,
            transaction: transaction
        )

        #expect(!didComplete)
        #expect(webKitManager.clearAllDataCalled)
        #expect(authService.state == .loggedOut)
        #expect(authService.loginCleanupRequired)
        authService.startLogin()
        #expect(authService.activeLoginAttemptID != nil)
        #expect(authService.activeLoginAttemptID != attemptID)
        #expect(authService.state == .loggingIn)
        #expect(authService.loginCleanupRequired)
    }

    @Test("Stale cleanup cannot expire a replacement login attempt")
    func staleCleanupCannotExpireReplacementLogin() async {
        let webKitManager = MockWebKitManager()
        webKitManager.finalizeLoginCookieBackupResult = false
        webKitManager.rollbackLoginCookieBackupResult = .failed
        let cleanupStarted = AsyncGate()
        let releaseCleanup = AsyncGate()
        webKitManager.clearAllDataGate = {
            await cleanupStarted.open()
            await releaseCleanup.wait()
        }
        let authService = AuthService(webKitManager: webKitManager)
        authService.startLogin()
        guard let attemptID = authService.activeLoginAttemptID,
              let transaction = await webKitManager.beginLoginCookieBackup()
        else {
            Issue.record("Expected active login and cookie transaction")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )

        let completion = Task { @MainActor in
            await gate.complete(
                expectedAttemptID: attemptID,
                transaction: transaction
            )
        }
        await cleanupStarted.wait()
        #expect(authService.state == .loggingIn)
        #expect(authService.activeLoginAttemptID == attemptID)
        authService.sessionExpired()
        authService.startLogin()
        let replacementAttemptID = authService.activeLoginAttemptID
        await releaseCleanup.open()

        #expect(await completion.value == false)
        #expect(replacementAttemptID != nil)
        #expect(authService.activeLoginAttemptID == replacementAttemptID)
        #expect(authService.state == .loggingIn)
        #expect(!authService.loginCleanupRequired)
    }

    @Test("Superseded rollback clears credentials owned by the active attempt")
    func supersededRollbackClearsActiveAttemptCredentials() async {
        let webKitManager = MockWebKitManager()
        webKitManager.commitLoginCookieBackupResult = false
        webKitManager.rollbackLoginCookieBackupResult = .superseded
        let authService = AuthService(webKitManager: webKitManager)
        authService.startLogin()
        guard let attemptID = authService.activeLoginAttemptID,
              let transaction = await webKitManager.beginLoginCookieBackup()
        else {
            Issue.record("Expected active login and cookie transaction")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )

        let didComplete = await gate.complete(
            expectedAttemptID: attemptID,
            transaction: transaction
        )

        #expect(!didComplete)
        #expect(webKitManager.clearAllDataCalled)
        #expect(authService.state == .loggedOut)
    }

    @Test("Restoration-policy commit failure rolls back before authentication")
    func commitFailureExpiresSession() async {
        let webKitManager = MockWebKitManager()
        webKitManager.commitLoginCookieBackupResult = false
        let authService = AuthService(webKitManager: webKitManager)
        authService.startLogin()
        guard let attemptID = authService.activeLoginAttemptID else {
            Issue.record("Expected an active login attempt")
            return
        }
        let gate = LoginCompletionGate(
            webKitManager: webKitManager,
            authService: authService
        )
        guard let transaction = await webKitManager.beginLoginCookieBackup() else {
            Issue.record("Expected a cookie backup transaction")
            return
        }

        let didComplete = await gate.complete(
            expectedAttemptID: attemptID,
            transaction: transaction
        )

        #expect(!didComplete)
        #expect(webKitManager.forceBackupCookiesCallCount == 1)
        #expect(webKitManager.refreshLoginCookieBackupCallCount == 1)
        #expect(webKitManager.commitLoginCookieBackupCallCount == 1)
        #expect(webKitManager.finalizeLoginCookieBackupCallCount == 0)
        #expect(webKitManager.rollbackLoginCookieBackupCallCount == 1)
        #expect(!webKitManager.clearAllDataCalled)
        #expect(authService.state == .initializing)
        #expect(!authService.needsReauth)
    }
}
