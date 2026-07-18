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

    @Test("Session expired transitions to loggedOut and sets needsReauth")
    func sessionExpired() {
        self.authService.completeLogin(sapisid: "test-sapisid")
        self.authService.sessionExpired()

        #expect(self.authService.state == .loggedOut)
        #expect(self.authService.needsReauth == true)
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
        self.authService.enterGuestMode()
        #expect(await self.cachedResponseWasCleared(for: enterRequest))

        let exitRequest = try self.storeCachedResponse(identifier: "exit-guest-mode")
        self.authService.exitGuestMode()
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
    func loggedInGuestModeToggle() {
        self.authService.completeLogin(sapisid: "test-sapisid")
        let cacheGeneration = APICache.shared.generation

        self.authService.enterGuestMode()
        #expect(SongLikeStatusManager.shared.activeAccountID == SongLikeStatusManager.guestAccountID)
        #expect(self.authService.state.isLoggedIn == true)
        #expect(self.authService.isGuestModeEnabled == true)
        #expect(self.authService.hasPersonalAccount == false)
        #expect(self.authService.shouldPersistGuestPlaybackState == true)
        #expect(self.authService.shouldUseCookieFreePlaybackDataStore == true)
        #expect(APICache.shared.generation == cacheGeneration &+ 1)

        self.authService.enterGuestMode()
        #expect(APICache.shared.generation == cacheGeneration &+ 1)

        self.authService.exitGuestMode()
        #expect(SongLikeStatusManager.shared.activeAccountID != SongLikeStatusManager.guestAccountID)
        #expect(self.authService.state.isLoggedIn == true)
        #expect(self.authService.isGuestModeEnabled == false)
        #expect(self.authService.hasPersonalAccount == true)
        #expect(self.authService.shouldUseCookieFreePlaybackDataStore == false)
        #expect(APICache.shared.generation == cacheGeneration &+ 2)

        self.authService.exitGuestMode()
        #expect(APICache.shared.generation == cacheGeneration &+ 2)
    }

    @Test("Exit guest mode restores provided account like scope")
    func exitGuestModeRestoresProvidedAccountLikeScope() {
        self.authService.completeLogin(sapisid: "placeholder")
        self.authService.enterGuestMode()

        self.authService.exitGuestMode(activeAccountID: "brand-account")

        #expect(self.authService.isGuestModeEnabled == false)
        #expect(SongLikeStatusManager.shared.activeAccountID == "brand-account")
    }

    @Test("Completing login and sign out clear guest mode")
    func loginAndSignOutClearGuestMode() async {
        self.authService.completeLogin(sapisid: "test-sapisid")
        self.authService.enterGuestMode()

        self.authService.completeLogin(sapisid: "new-sapisid")
        #expect(self.authService.isGuestModeEnabled == false)
        #expect(self.authService.hasPersonalAccount == true)

        self.authService.enterGuestMode()
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

    @Test("Check login status waits for restore and logs out when SAPISID is missing")
    func checkLoginStatusLogsOut() async {
        await self.authService.checkLoginStatus()

        #expect(self.authService.state == .loggedOut)
        #expect(self.mockWebKitManager.waitForInitialCookieRestoreCalled == true)
        #expect(self.mockWebKitManager.waitForInitialCookieRestoreCallCount == 1)
        #expect(self.mockWebKitManager.getSAPISIDCallCount == 1)
        #expect(self.mockWebKitManager.callSequence == ["waitForInitialCookieRestore", "getSAPISID"])
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
