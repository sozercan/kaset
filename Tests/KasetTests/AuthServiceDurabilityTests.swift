import Testing
@testable import Kaset

@Suite("AuthService durability", .serialized, .tags(.service))
@MainActor
struct AuthServiceDurabilityTests {
    @Test("Sign out stops before account drain when the restoration fence cannot persist")
    func signOutStopsWhenRestorationFenceFails() async {
        let webKitManager = MockWebKitManager()
        let authService = AuthService(webKitManager: webKitManager)
        authService.completeLogin(sapisid: "test-sapisid")
        webKitManager.invalidateAuthCookieRestorationResult = false
        let identityGeneration = authService.accountIdentityGeneration
        let signOutSequence = authService.signOutSequence
        let boundaryBegins = LockedCounter()
        let boundaryEnds = LockedCounter()
        let drains = LockedCounter()
        authService.setAccountBoundaryHandlers(
            willBegin: { boundaryBegins.increment() },
            didEnd: { boundaryEnds.increment() },
            drain: { drains.increment() }
        )

        let didSignOutDurably = await authService.signOut()

        #expect(!didSignOutDurably)
        #expect(authService.state == .loggedIn(sapisid: "test-sapisid"))
        #expect(authService.accountIdentityGeneration == identityGeneration)
        #expect(authService.signOutSequence == signOutSequence)
        #expect(!webKitManager.clearAllDataCalled)
        #expect(boundaryBegins.isEmpty)
        #expect(boundaryEnds.isEmpty)
        #expect(drains.isEmpty)
    }

    @Test("Rollback preparation failure still drains and runs cleanup")
    func rollbackPreparationFailureStillDrainsBoundary() async throws {
        let authService = AuthService(webKitManager: MockWebKitManager())
        authService.startLogin()
        let attemptID = try #require(authService.activeLoginAttemptID)
        let drains = LockedCounter()
        let rollbackCalls = LockedCounter()
        authService.setAccountBoundaryHandlers(
            willBegin: {},
            didEnd: {},
            drain: { drains.increment() }
        )

        let result = await authService.resolveLoginRollbackAfterDraining(
            expectedAttemptID: attemptID,
            prepareRollback: { false },
            rollback: { forceCleanup in
                #expect(forceCleanup)
                rollbackCalls.increment()
                return .cleared
            }
        )

        #expect(result == .cleared)
        #expect(drains.count == 1)
        #expect(rollbackCalls.count == 1)
        #expect(authService.state == .loggedOut)
        #expect(!authService.loginCleanupRequired)
    }

    @Test("Failed-login cleanup persists invalidation before draining")
    func failedLoginCleanupRequiresDurableInvalidation() async throws {
        let webKitManager = MockWebKitManager()
        webKitManager.invalidateAuthCookieRestorationResult = false
        let authService = AuthService(webKitManager: webKitManager)
        authService.startLogin()
        let attemptID = try #require(authService.activeLoginAttemptID)
        let drains = LockedCounter()
        let clearCalls = LockedCounter()
        authService.setAccountBoundaryHandlers(
            willBegin: {},
            didEnd: {},
            drain: { drains.increment() }
        )

        let result = await authService.clearFailedLoginAfterDraining(
            expectedAttemptID: attemptID,
            expectedSignOutSequence: authService.signOutSequence,
            clearCookies: {
                clearCalls.increment()
                return true
            }
        )

        #expect(result == false)
        #expect(authService.state == .loggingIn)
        #expect(authService.loginCleanupRequired)
        #expect(authService.shouldPersistGuestPlaybackState)
        #expect(drains.isEmpty)
        #expect(clearCalls.isEmpty)
        #expect(webKitManager.invalidateAuthCookieRestorationCalled)
    }

    @Test("Verified rollback clears a transient cleanup latch")
    func verifiedRollbackClearsCleanupLatch() async throws {
        let authService = AuthService(webKitManager: MockWebKitManager())
        authService.startLogin()
        authService.setLoginCleanupRequired(true)
        let attemptID = try #require(authService.activeLoginAttemptID)

        let result = await authService.resolveLoginRollbackAfterDraining(
            expectedAttemptID: attemptID,
            prepareRollback: { true },
            rollback: { forceCleanup in
                #expect(!forceCleanup)
                return .rolledBack
            }
        )

        #expect(result == .rolledBack)
        #expect(!authService.loginCleanupRequired)
    }

    @Test("Stale residual cleanup cannot claim a later logged-out attempt")
    func staleResidualCleanupCannotClaimLaterAttempt() async throws {
        let webKitManager = MockWebKitManager()
        let authService = AuthService(webKitManager: webKitManager)
        authService.sessionExpired()
        authService.startLogin()
        let staleAttemptID = try #require(authService.activeLoginAttemptID)
        let expectedSignOutSequence = authService.signOutSequence
        authService.cancelLoginIfNeeded(expectedAttemptID: staleAttemptID)

        authService.startLogin()
        let replacementAttemptID = try #require(authService.activeLoginAttemptID)
        authService.completeLogin(sapisid: "replacement-session")
        authService.sessionExpired()
        let identityGeneration = authService.accountIdentityGeneration
        let clearCalls = LockedCounter()

        let result = await authService.clearFailedLoginAfterDraining(
            expectedAttemptID: staleAttemptID,
            expectedSignOutSequence: expectedSignOutSequence,
            clearCookies: {
                clearCalls.increment()
                return true
            }
        )

        #expect(replacementAttemptID != staleAttemptID)
        #expect(result == nil)
        #expect(!webKitManager.invalidateAuthCookieRestorationCalled)
        #expect(clearCalls.isEmpty)
        #expect(authService.accountIdentityGeneration == identityGeneration)
        #expect(authService.state == .loggedOut)
    }

    @Test("Reauthentication cleanup preserves account-owned playback state")
    func reauthenticationCleanupPreservesAccountOwnership() async throws {
        let authService = AuthService(webKitManager: MockWebKitManager())
        authService.completeLogin(sapisid: "existing-session")
        authService.startLogin()
        let attemptID = try #require(authService.activeLoginAttemptID)

        let result = await authService.resolveLoginRollbackAfterDraining(
            expectedAttemptID: attemptID,
            prepareRollback: { true },
            rollback: { forceCleanup in
                #expect(!forceCleanup)
                return .failed
            }
        )

        #expect(result == .failed)
        #expect(authService.loginCleanupRequired)
        #expect(authService.needsReauth)
        #expect(!authService.shouldPersistGuestPlaybackState)
    }

    @Test("Cleanup in progress blocks a replacement login attempt")
    func cleanupInProgressBlocksReplacementLogin() async throws {
        let authService = AuthService(webKitManager: MockWebKitManager())
        authService.startLogin()
        let attemptID = try #require(authService.activeLoginAttemptID)
        let cleanupStarted = AsyncGate()
        let releaseCleanup = AsyncGate()

        let cleanup = Task { @MainActor in
            await authService.clearFailedLoginAfterDraining(
                expectedAttemptID: attemptID,
                expectedSignOutSequence: authService.signOutSequence,
                clearCookies: {
                    await cleanupStarted.open()
                    await releaseCleanup.wait()
                    return true
                }
            )
        }
        await cleanupStarted.wait()
        #expect(authService.loginCleanupRequired)
        #expect(authService.isLoginCleanupInProgress)

        authService.startLogin()

        #expect(authService.activeLoginAttemptID == nil)
        #expect(authService.state == .loggedOut)
        await releaseCleanup.open()
        #expect(await cleanup.value == true)
        #expect(!authService.loginCleanupRequired)
        #expect(!authService.isLoginCleanupInProgress)
    }
}
