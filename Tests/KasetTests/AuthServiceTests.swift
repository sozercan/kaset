import Foundation
import Testing
@testable import Kaset

/// Tests for AuthService.
@Suite(.serialized, .tags(.service))
@MainActor
struct AuthServiceTests {
    var authService: AuthService
    var mockWebKitManager: MockWebKitManager

    init() {
        SongLikeStatusManager.shared.setActiveAccountID(nil)
        SongLikeStatusManager.shared.clearCache()
        self.mockWebKitManager = MockWebKitManager()
        self.authService = AuthService(webKitManager: self.mockWebKitManager)
    }

    @Test("Initial state is initializing")
    func initialState() {
        #expect(self.authService.state == .initializing)
        #expect(self.authService.needsReauth == false)
    }

    @Test("State isInitializing property")
    func isInitializing() {
        #expect(self.authService.state.isInitializing == true)
        #expect(self.authService.state.isLoggedIn == false)

        self.authService.completeLogin(sapisid: "test")
        #expect(self.authService.state.isInitializing == false)
        #expect(self.authService.state.isLoggedIn == true)
    }

    @Test("Start login transitions to loggingIn state")
    func startLogin() {
        self.authService.startLogin()
        #expect(self.authService.state == .loggingIn)
    }

    @Test("Cancel login restores prior logged-in session")
    func cancelLoginRestoresLoggedInState() {
        self.authService.completeLogin(sapisid: "existing-sapisid")

        self.authService.startLogin()
        self.authService.cancelLoginIfNeeded()

        #expect(self.authService.state == .loggedIn(sapisid: "existing-sapisid"))
    }

    @Test("Cancel login from signed out remains signed out")
    func cancelLoginFromSignedOutStaysSignedOut() async {
        await self.authService.checkLoginStatus()

        self.authService.startLogin()
        self.authService.cancelLoginIfNeeded()

        #expect(self.authService.state == .loggedOut)
    }

    @Test("Guest persistence flag remains true while signed-out login is open")
    func guestPersistenceFlagWhileLoginOpen() async {
        await self.authService.checkLoginStatus()

        self.authService.startLogin()

        #expect(self.authService.shouldPersistGuestPlaybackState == true)
    }

    @Test("Guest persistence flag is false for reauth")
    func guestPersistenceFlagFalseForReauth() {
        self.authService.completeLogin(sapisid: "existing-sapisid")

        self.authService.startLogin()

        #expect(self.authService.shouldPersistGuestPlaybackState == false)
        #expect(self.authService.shouldUseCookieFreePlaybackDataStore == false)
    }

    @Test("Guest persistence flag is false after session expiry")
    func guestPersistenceFlagFalseAfterSessionExpiry() {
        self.authService.completeLogin(sapisid: "expired-sapisid")
        self.authService.sessionExpired()

        #expect(self.authService.shouldPersistGuestPlaybackState == false)
    }

    @Test("Guest persistence and cookie-free playback remain false during reauth retry")
    func guestPersistenceAndCookieFreePlaybackRemainFalseDuringReauthRetry() {
        self.authService.completeLogin(sapisid: "expired-sapisid")
        self.authService.sessionExpired()

        self.authService.startLogin()

        #expect(self.authService.state == .loggingIn)
        #expect(self.authService.needsReauth == true)
        #expect(self.authService.shouldPersistGuestPlaybackState == false)
        #expect(self.authService.shouldUseCookieFreePlaybackDataStore == false)
    }

    @Test("Complete login transitions to loggedIn state")
    func completeLogin() {
        self.authService.completeLogin(sapisid: "test-sapisid")
        #expect(self.authService.state == .loggedIn(sapisid: "test-sapisid"))
        #expect(self.authService.needsReauth == false)
    }

    @Test("Complete login waits for account-boundary drain")
    func completeLoginWaitsForAccountBoundaryDrain() async {
        let drainStarted = AsyncGate()
        let releaseDrain = AsyncGate()
        self.authService.setAccountBoundaryHandlers(
            willBegin: {},
            didEnd: {},
            drain: {
                await drainStarted.open()
                await releaseDrain.wait()
            }
        )

        let completionTask = Task {
            await self.authService.completeLoginAfterDraining(sapisid: "test-sapisid")
        }
        await drainStarted.wait()
        #expect(self.authService.state == .initializing)

        await releaseDrain.open()
        await completionTask.value
        #expect(self.authService.state == .loggedIn(sapisid: "test-sapisid"))
    }

    @Test("Session expired transitions to loggedOut and sets needsReauth")
    func sessionExpired() {
        self.authService.completeLogin(sapisid: "test-sapisid")
        let identityGeneration = self.authService.accountIdentityGeneration
        self.authService.sessionExpired()

        #expect(self.authService.state == .loggedOut)
        #expect(self.authService.needsReauth == true)
        #expect(self.authService.accountIdentityGeneration == identityGeneration &+ 1)
    }

    @Test("Stale auth failures cannot expire a newer identity")
    func staleAuthFailureDoesNotExpireNewerIdentity() {
        self.authService.completeLogin(sapisid: "current-session")
        let currentGeneration = self.authService.accountIdentityGeneration

        self.authService.sessionExpired(ifIdentityGenerationMatches: currentGeneration &+ 1)

        #expect(self.authService.state == .loggedIn(sapisid: "current-session"))
        #expect(self.authService.accountIdentityGeneration == currentGeneration)

        self.authService.sessionExpired(ifIdentityGenerationMatches: currentGeneration)
        #expect(self.authService.state == .loggedOut)
    }

    @Test("Replacing a logged-in identity advances the generation")
    func replacingLoggedInIdentityAdvancesGeneration() async throws {
        self.authService.completeLogin(sapisid: "session-A")
        let generation = self.authService.accountIdentityGeneration
        let request = try self.storeCachedResponse(identifier: "identity-replacement")

        self.authService.startLogin()
        self.authService.completeLogin(sapisid: "session-B")

        #expect(self.authService.accountIdentityGeneration == generation &+ 1)
        #expect(self.authService.state == .loggedIn(sapisid: "session-B"))
        #expect(await self.cachedResponseWasCleared(for: request))
        self.authService.sessionExpired(ifIdentityGenerationMatches: generation)
        #expect(self.authService.state == .loggedIn(sapisid: "session-B"))
    }

    @Test("Reconfirming the same cookie advances the identity generation")
    func reconfirmingSameCookieAdvancesGeneration() {
        self.authService.completeLogin(sapisid: "session-A")
        let generation = self.authService.accountIdentityGeneration

        self.authService.startLogin()
        self.authService.completeLogin(sapisid: "session-A")

        #expect(self.authService.accountIdentityGeneration == generation &+ 1)
    }

    @Test("Session expiry clears like state and invalidates liked-music requests")
    func sessionExpiryClearsLikeStateAndInvalidatesLikedMusicRequests() {
        self.authService.completeLogin(sapisid: "placeholder")

        let manager = SongLikeStatusManager.shared
        let videoId = "session-expiry-cached-like"
        manager.setStatus(.like, for: videoId)
        let requestSnapshot = manager.beginLikedMusicRequest()

        #expect(manager.status(for: videoId) == .like)
        #expect(manager.matchesCurrentScope(requestSnapshot))

        self.authService.sessionExpired()

        #expect(manager.status(for: videoId) == nil)
        #expect(manager.matchesCurrentScope(requestSnapshot) == false)
    }

    @Test("Guest mode transitions clear URL cache")
    func guestModeTransitionsClearURLCache() async throws {
        self.authService.completeLogin(sapisid: "placeholder")

        let enterRequest = try self.storeCachedResponse(identifier: "enter-guest-mode")
        await self.authService.enterGuestMode()
        #expect(await self.cachedResponseWasCleared(for: enterRequest))

        let exitRequest = try self.storeCachedResponse(identifier: "exit-guest-mode")
        await self.authService.exitGuestMode()
        #expect(await self.cachedResponseWasCleared(for: exitRequest))
    }

    @Test("Session expiry and sign out clear URL cache")
    func sessionExpiryAndSignOutClearURLCache() async throws {
        self.authService.completeLogin(sapisid: "placeholder")

        let expiryRequest = try self.storeCachedResponse(identifier: "session-expired")
        self.authService.sessionExpired()
        #expect(await self.cachedResponseWasCleared(for: expiryRequest))

        self.authService.completeLogin(sapisid: "placeholder-2")
        let signOutRequest = try self.storeCachedResponse(identifier: "sign-out")
        await self.authService.signOut()
        #expect(await self.cachedResponseWasCleared(for: signOutRequest))
    }

    @Test("Logged-in users can enter and exit guest mode")
    func loggedInGuestModeToggle() async {
        self.authService.completeLogin(sapisid: "test-sapisid")
        let cacheGeneration = APICache.shared.generation

        await self.authService.enterGuestMode()
        #expect(SongLikeStatusManager.shared.activeAccountID == SongLikeStatusManager.guestAccountID)
        #expect(self.authService.state.isLoggedIn == true)
        #expect(self.authService.isGuestModeEnabled == true)
        #expect(self.authService.hasPersonalAccount == false)
        #expect(self.authService.shouldPersistGuestPlaybackState == true)
        #expect(self.authService.shouldUseCookieFreePlaybackDataStore == true)
        #expect(APICache.shared.generation == cacheGeneration &+ 1)

        await self.authService.enterGuestMode()
        #expect(APICache.shared.generation == cacheGeneration &+ 1)

        await self.authService.exitGuestMode()
        #expect(SongLikeStatusManager.shared.activeAccountID != SongLikeStatusManager.guestAccountID)
        #expect(self.authService.state.isLoggedIn == true)
        #expect(self.authService.isGuestModeEnabled == false)
        #expect(self.authService.hasPersonalAccount == true)
        #expect(self.authService.shouldUseCookieFreePlaybackDataStore == false)
        #expect(APICache.shared.generation == cacheGeneration &+ 2)

        await self.authService.exitGuestMode()
        #expect(APICache.shared.generation == cacheGeneration &+ 2)
    }

    @Test("Guest mode boundaries prepare account-scoped work before state changes")
    func guestModeBoundariesPrepareAccountWork() async {
        self.authService.completeLogin(sapisid: "test-sapisid")
        let begins = LockedCounter()
        let ends = LockedCounter()
        let enterDrainStarted = AsyncGate()
        let releaseEnterDrain = AsyncGate()
        self.authService.setAccountBoundaryHandlers(
            willBegin: { begins.increment() },
            didEnd: { ends.increment() },
            drain: {
                await enterDrainStarted.open()
                await releaseEnterDrain.wait()
            }
        )

        let enterTask = Task { await self.authService.enterGuestMode() }
        await enterDrainStarted.wait()
        #expect(begins.count == 1)
        #expect(ends.isEmpty)
        #expect(!self.authService.isGuestModeEnabled)
        await releaseEnterDrain.open()
        await enterTask.value
        #expect(ends.count == 1)
        #expect(self.authService.isGuestModeEnabled)

        let exitDrainStarted = AsyncGate()
        let releaseExitDrain = AsyncGate()
        self.authService.setAccountBoundaryHandlers(
            willBegin: { begins.increment() },
            didEnd: { ends.increment() },
            drain: {
                await exitDrainStarted.open()
                await releaseExitDrain.wait()
            }
        )

        let exitTask = Task { await self.authService.exitGuestMode() }
        await exitDrainStarted.wait()
        #expect(begins.count == 2)
        #expect(ends.count == 1)
        #expect(self.authService.isGuestModeEnabled)
        await releaseExitDrain.open()
        await exitTask.value
        #expect(ends.count == 2)
        #expect(!self.authService.isGuestModeEnabled)
    }

    @Test("Completing login cancels pending guest-mode entry")
    func completingLoginCancelsPendingGuestModeEntry() async {
        self.authService.completeLogin(sapisid: "test-sapisid")
        let drainStarted = AsyncGate()
        let releaseDrain = AsyncGate()
        self.authService.setAccountBoundaryHandlers(
            willBegin: {},
            didEnd: {},
            drain: {
                await drainStarted.open()
                await releaseDrain.wait()
            }
        )

        let guestTask = Task { await self.authService.enterGuestMode() }
        await drainStarted.wait()
        let loginTask = Task {
            await self.authService.completeLoginAfterDraining(sapisid: "replacement-session")
        }
        await releaseDrain.open()
        await guestTask.value
        await loginTask.value

        #expect(!self.authService.isGuestModeEnabled)
        #expect(self.authService.hasPersonalAccount)
        #expect(self.authService.state == .loggedIn(sapisid: "replacement-session"))
    }

    @Test("Exit guest mode restores provided account like scope")
    func exitGuestModeRestoresProvidedAccountLikeScope() async {
        self.authService.completeLogin(sapisid: "placeholder")
        await self.authService.enterGuestMode()

        await self.authService.exitGuestMode(activeAccountID: "brand-account")

        #expect(self.authService.isGuestModeEnabled == false)
        #expect(SongLikeStatusManager.shared.activeAccountID == "brand-account")
    }

    @Test("Completing login and sign out clear guest mode")
    func loginAndSignOutClearGuestMode() async {
        self.authService.completeLogin(sapisid: "test-sapisid")
        await self.authService.enterGuestMode()

        self.authService.completeLogin(sapisid: "new-sapisid")
        #expect(self.authService.isGuestModeEnabled == false)
        #expect(self.authService.hasPersonalAccount == true)
        #expect(FavoritesManager.shared.activeScopeID != "guest")

        await self.authService.enterGuestMode()
        await self.authService.signOut()
        #expect(self.authService.isGuestModeEnabled == false)
        #expect(self.authService.hasPersonalAccount == false)
    }

    @Test("State isLoggedIn property")
    func stateIsLoggedIn() {
        #expect(self.authService.state.isLoggedIn == false)

        self.authService.completeLogin(sapisid: "test")
        #expect(self.authService.state.isLoggedIn == true)
    }

    @Test("Sign out clears state and calls mock")
    func signOut() async {
        self.authService.completeLogin(sapisid: "test-sapisid")
        self.authService.needsReauth = true

        await self.authService.signOut()

        #expect(self.authService.state == .loggedOut)
        #expect(self.authService.needsReauth == false)
        #expect(self.mockWebKitManager.clearAllDataCalled == true)
    }

    @Test("Check login status waits for restore and logs in from SAPISID")
    func checkLoginStatusLogsIn() async {
        self.authService.needsReauth = true
        self.mockWebKitManager.sapisidValue = "persisted-sapisid"

        await self.authService.checkLoginStatus()

        #expect(self.authService.state == .loggedIn(sapisid: "persisted-sapisid"))
        #expect(self.authService.needsReauth == false)
        #expect(self.mockWebKitManager.waitForInitialCookieRestoreCalled == true)
        #expect(self.mockWebKitManager.waitForInitialCookieRestoreCallCount == 1)
        #expect(self.mockWebKitManager.getSAPISIDCallCount == 1)
        #expect(self.mockWebKitManager.callSequence == ["waitForInitialCookieRestore", "getSAPISID"])
    }

    @Test("Checking login status fences replacement of a logged-in identity")
    func checkLoginStatusFencesIdentityReplacement() async {
        self.authService.completeLogin(sapisid: "session-a")
        let begins = LockedCounter()
        let ends = LockedCounter()
        self.authService.setAccountBoundaryHandlers(
            willBegin: { begins.increment() },
            didEnd: { ends.increment() },
            drain: {}
        )
        self.mockWebKitManager.sapisidValue = "session-b"

        await self.authService.checkLoginStatus()

        #expect(self.authService.state == .loggedIn(sapisid: "session-b"))
        #expect(begins.count == 1)
        #expect(ends.count == 1)
    }

    @Test("Check login status waits for restore and logs out when SAPISID is missing")
    func checkLoginStatusLogsOut() async {
        await self.authService.checkLoginStatus()

        #expect(self.authService.state == .loggedOut)
        #expect(self.mockWebKitManager.waitForInitialCookieRestoreCalled == true)
        #expect(self.mockWebKitManager.waitForInitialCookieRestoreCallCount == 1)
        #expect(self.mockWebKitManager.getSAPISIDCallCount == 1)
        #expect(self.mockWebKitManager.callSequence == ["waitForInitialCookieRestore", "getSAPISID"])
    }

    @Test("Concurrent login checks share one cookie read")
    func concurrentLoginChecksAreSingleFlight() async {
        self.mockWebKitManager.sapisidValue = "persisted-sapisid"
        let release = AsyncGate()
        self.mockWebKitManager.getSAPISIDGate = { await release.wait() }

        async let first: Void = self.authService.checkLoginStatus()
        async let second: Void = self.authService.checkLoginStatus()
        for _ in 0 ..< 100 where self.mockWebKitManager.getSAPISIDCallCount == 0 {
            await Task.yield()
        }
        await release.open()
        await first
        await second

        #expect(self.mockWebKitManager.waitForInitialCookieRestoreCallCount == 1)
        #expect(self.mockWebKitManager.getSAPISIDCallCount == 1)
        #expect(self.authService.state == .loggedIn(sapisid: "persisted-sapisid"))
    }

    @Test("Starting login cancels an in-flight login-status probe")
    func startLoginCancelsInFlightStatusProbe() async {
        let release = AsyncGate()
        self.mockWebKitManager.getSAPISIDGate = { await release.wait() }
        self.mockWebKitManager.sapisidValue = "stale-session"

        let check = Task { @MainActor in
            await self.authService.checkLoginStatus()
        }
        for _ in 0 ..< 100 where self.mockWebKitManager.getSAPISIDCallCount == 0 {
            await Task.yield()
        }

        self.authService.startLogin()
        await release.open()
        await check.value

        #expect(self.authService.state == .loggingIn)
    }

    @Test("A stale login check cannot overwrite a completed login")
    func staleLoginCheckCannotOverwriteCompletedLogin() async {
        let release = AsyncGate()
        self.mockWebKitManager.getSAPISIDGate = { await release.wait() }

        let check = Task { @MainActor in
            await self.authService.checkLoginStatus()
        }
        for _ in 0 ..< 100 where self.mockWebKitManager.getSAPISIDCallCount == 0 {
            await Task.yield()
        }

        self.authService.completeLogin(sapisid: "new-session")
        await release.open()
        await check.value

        #expect(self.authService.state == .loggedIn(sapisid: "new-session"))
    }

    @Test("Sign out fences account work before cookie deletion completes")
    func signOutFencesBeforeCookieDeletionCompletes() async {
        self.authService.completeLogin(sapisid: "current-session")
        let identityGeneration = self.authService.accountIdentityGeneration
        let cachedRequest = try? self.storeCachedResponse(identifier: "sign-out-fence")
        let release = AsyncGate()
        self.mockWebKitManager.clearAllDataGate = { await release.wait() }

        let signOut = Task { @MainActor in
            await self.authService.signOut()
        }
        for _ in 0 ..< 100 where !self.mockWebKitManager.clearAllDataCalled {
            await Task.yield()
        }

        #expect(self.authService.state == .loggedOut)
        #expect(self.authService.accountIdentityGeneration == identityGeneration &+ 1)
        if let cachedRequest {
            #expect(await self.cachedResponseWasCleared(for: cachedRequest))
        }

        self.authService.completeLogin(sapisid: "replacement-session")
        #expect(self.authService.state == .loggedOut)

        let loginCheck = Task { @MainActor in
            await self.authService.checkLoginStatus()
        }
        await Task.yield()
        #expect(self.mockWebKitManager.getSAPISIDCallCount == 0)

        await release.open()
        await signOut.value
        await loginCheck.value
        #expect(self.authService.state == .loggedOut)
        #expect(self.mockWebKitManager.getSAPISIDCallCount == 0)
    }

    @Test("State equality")
    func stateEquatable() {
        let state1 = AuthService.State.loggedOut
        let state2 = AuthService.State.loggedOut
        #expect(state1 == state2)

        let state3 = AuthService.State.loggedIn(sapisid: "test")
        let state4 = AuthService.State.loggedIn(sapisid: "test")
        #expect(state3 == state4)

        let state5 = AuthService.State.loggedIn(sapisid: "different")
        #expect(state3 != state5)
    }

    private func cachedResponseWasCleared(for request: URLRequest) async -> Bool {
        for _ in 0 ..< 20 {
            if URLCache.shared.cachedResponse(for: request) == nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return URLCache.shared.cachedResponse(for: request) == nil
    }

    private func storeCachedResponse(identifier: String) throws -> URLRequest {
        let url = try #require(URL(string: "https://music.youtube.com/cache-boundary-\(identifier)"))
        let request = URLRequest(url: url)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Cache-Control": "max-age=300"]
            )
        )
        URLCache.shared.storeCachedResponse(
            CachedURLResponse(response: response, data: Data("placeholder-cache-data-\(identifier)".utf8)),
            for: request
        )
        #expect(URLCache.shared.cachedResponse(for: request) != nil)
        return request
    }
}
