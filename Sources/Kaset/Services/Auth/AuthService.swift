import Foundation
import Observation
import os

/// Manages authentication state for YouTube Music.
@MainActor
@Observable
final class AuthService: AuthServiceProtocol {
    /// Authentication states.
    enum State: Equatable {
        case initializing
        case loggedOut
        case loggingIn
        case loggedIn(sapisid: String)

        var isLoggedIn: Bool {
            if case .loggedIn = self {
                return true
            }
            return false
        }

        var isInitializing: Bool {
            self == .initializing
        }
    }

    /// Current authentication state.
    private(set) var state: State

    /// Flag indicating whether re-authentication is needed.
    var needsReauth: Bool = false

    /// Changes whenever the authenticated Google-user identity must be treated as unverified.
    private(set) var accountIdentityGeneration: UInt64 = 0

    /// Whether a signed-in user is temporarily browsing as a guest.
    /// Cookies/accounts stay available so the user can switch back without signing in again.
    private(set) var isGuestModeEnabled = false

    /// Whether account-backed UI/actions/API requests should use the personal account.
    var hasPersonalAccount: Bool {
        self.state.isLoggedIn && !self.isGuestModeEnabled
    }

    /// Whether playback WebViews should use a cookie-free data store.
    /// Reauth prompts keep the existing account-cookie playback store so active
    /// playback is not torn down while the user re-authenticates.
    var shouldUseCookieFreePlaybackDataStore: Bool {
        if self.isGuestModeEnabled {
            return true
        }
        if self.state == .loggedOut, !self.needsReauth {
            return true
        }
        if self.state == .loggingIn, self.stateBeforeLogin == .loggedOut, !self.needsReauth {
            return true
        }
        return false
    }

    /// Whether account-scoped playback persistence should be tagged as guest-owned.
    /// A signed-out user can temporarily be `.loggingIn` while the login sheet is
    /// open; that flow should still preserve guest-owned queues if cancelled.
    var shouldPersistGuestPlaybackState: Bool {
        guard !self.needsReauth else { return false }
        if self.isGuestModeEnabled {
            return true
        }
        if self.state == .loggedOut {
            return true
        }
        if self.state == .loggingIn, self.stateBeforeLogin == .loggedOut {
            return true
        }
        return false
    }

    private let webKitManager: WebKitManagerProtocol
    private let logger = DiagnosticsLogger.auth
    private var stateBeforeLogin: State?
    private var loginCheckTask: Task<Void, Never>?
    private var loginCheckGeneration: UInt64 = 0
    private var signOutTask: Task<Void, Never>?
    private var signOutPreparation: (@MainActor @Sendable () async -> Void)?

    init(webKitManager: WebKitManagerProtocol = WebKitManager.shared) {
        self.webKitManager = webKitManager
        // In UI test mode with skip auth, start in logged-in state immediately
        // This avoids async delays that can cause UI test flakiness
        let isUITest = UITestConfig.isUITestMode
        let skipAuth = UITestConfig.shouldSkipAuth
        let forceLoggedOut = UITestConfig.environmentValue(for: UITestConfig.mockLoggedOutKey) == "true"
        self.logger.debug("AuthService init: isUITestMode=\(isUITest), shouldSkipAuth=\(skipAuth)")
        if isUITest, forceLoggedOut {
            self.logger.info("UI Test mode: forcing logged-out state")
            self.state = .loggedOut
        } else if isUITest, skipAuth {
            self.logger.info("UI Test mode with SkipAuth: starting in logged-in state")
            self.state = .loggedIn(sapisid: "mock-sapisid-for-ui-tests")
        } else {
            self.state = .initializing
        }
    }

    /// Temporarily uses public guest mode while preserving the signed-in session.
    func enterGuestMode() {
        guard self.state.isLoggedIn else { return }
        guard !self.isGuestModeEnabled else { return }
        self.logger.info("Entering guest mode")
        self.clearAPIResponseCaches()
        SongLikeStatusManager.shared.setActiveAccountID(SongLikeStatusManager.guestAccountID)
        FavoritesManager.shared.enterGuestMode()
        self.isGuestModeEnabled = true
    }

    /// Leaves guest mode and resumes the signed-in personal account.
    func exitGuestMode(activeAccountID: String? = nil) {
        guard self.isGuestModeEnabled else { return }
        self.logger.info("Leaving guest mode")
        self.clearAPIResponseCaches()
        SongLikeStatusManager.shared.setActiveAccountID(activeAccountID)
        FavoritesManager.shared.exitGuestMode()
        self.isGuestModeEnabled = false
    }

    /// Starts the login flow by presenting the login sheet.
    func startLogin() {
        self.logger.info("Starting login flow")
        guard self.signOutTask == nil else {
            self.logger.info("Ignoring login request while sign-out is in progress")
            return
        }
        self.invalidateLoginCheck()
        if self.state != .loggingIn {
            self.stateBeforeLogin = self.state
        }
        self.state = .loggingIn
    }

    /// Cancels an in-progress login presentation without changing an already
    /// completed authenticated session.
    func cancelLoginIfNeeded() {
        guard self.state == .loggingIn else { return }
        self.logger.info("Login flow cancelled")
        self.state = self.stateBeforeLogin ?? .loggedOut
        self.stateBeforeLogin = nil
    }

    /// Registers account-owned WebKit mutation cleanup that every sign-out must await.
    func setSignOutPreparation(_ preparation: @escaping @MainActor @Sendable () async -> Void) {
        self.signOutPreparation = preparation
    }

    /// Checks if the user is logged in based on existing cookies.
    /// Waits for the initial Keychain restore before reading WebKit cookies.
    func checkLoginStatus() async {
        if let signOutTask = self.signOutTask {
            await signOutTask.value
            if self.signOutTask == signOutTask {
                self.signOutTask = nil
            }
            return
        }
        if let loginCheckTask = self.loginCheckTask {
            await loginCheckTask.value
            return
        }

        self.loginCheckGeneration &+= 1
        let checkGeneration = self.loginCheckGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let resolvedState = await self.resolveLoginState()
            guard !Task.isCancelled,
                  checkGeneration == self.loginCheckGeneration
            else { return }

            self.transitionToResolvedState(resolvedState)
            if resolvedState.isLoggedIn {
                self.needsReauth = false
            }
        }
        self.loginCheckTask = task
        await task.value
        guard self.loginCheckTask == task else { return }
        self.loginCheckTask = nil
    }

    /// Called when a session expires (e.g., 401/403 from API).
    func sessionExpired() {
        self.logger.warning("Session expired, requiring re-authentication")
        self.invalidateLoginCheck()
        self.advanceAccountIdentityGeneration()
        self.needsReauth = true
        self.isGuestModeEnabled = false
        SongLikeStatusManager.shared.clearCache()
        self.state = .loggedOut
        self.stateBeforeLogin = nil
        // Drop cached personalized responses so a later login in the same
        // session can't be served the previous user's data (incl. the
        // account-unknown "pending" cache scope) before its TTL expires.
        self.clearAPIResponseCaches()
    }

    /// Expires only the authentication identity that originated an async request.
    func sessionExpired(ifIdentityGenerationMatches generation: UInt64) {
        guard generation == self.accountIdentityGeneration else { return }
        self.sessionExpired()
    }

    /// Signs out the user by draining account-owned WebKit mutations, then clearing all data.
    func signOut() async {
        if let signOutTask = self.signOutTask {
            await signOutTask.value
            return
        }
        self.logger.info("Signing out user")

        // Fence authenticated work synchronously before the account-owned drain
        // can suspend. The drain prevents old WebKit mutations from outliving the
        // later cookie deletion; this state change prevents new API mutations.
        self.invalidateLoginCheck()
        self.advanceAccountIdentityGeneration()
        self.clearAPIResponseCaches()
        self.state = .loggedOut
        self.isGuestModeEnabled = false
        self.needsReauth = false
        self.stateBeforeLogin = nil

        let preparation = self.signOutPreparation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await preparation?()
            await self.webKitManager.clearAllData()
            self.clearAPIResponseCaches()
            self.logger.info("User signed out successfully")
        }
        self.signOutTask = task
        await task.value
        if self.signOutTask == task {
            self.signOutTask = nil
        }
    }

    private func clearAPIResponseCaches() {
        APICache.shared.invalidateAll()
        URLCache.shared.removeAllCachedResponses()
    }

    /// Called when login completes successfully (from LoginSheet observation).
    func completeLogin(sapisid: String) {
        self.logger.info("Login completed successfully")
        guard self.signOutTask == nil else {
            self.logger.info("Ignoring login completion while sign-out is in progress")
            return
        }
        self.invalidateLoginCheck()
        if self.isGuestModeEnabled {
            self.exitGuestMode()
        }
        // Login completion is an explicit identity boundary even when Google
        // reuses the same SAPISID across multi-login accounts. Fence every older
        // authenticated request before publishing the resolved session.
        self.advanceAccountIdentityGeneration()
        self.clearAPIResponseCaches()
        self.state = .loggedIn(sapisid: sapisid)
        self.needsReauth = false
        self.stateBeforeLogin = nil
    }

    private func advanceAccountIdentityGeneration() {
        self.accountIdentityGeneration &+= 1
    }

    private func transitionToResolvedState(_ newState: State) {
        let previousIdentity = self.activeAuthenticationIdentity
        let nextIdentity: String? = if case let .loggedIn(sapisid) = newState {
            sapisid
        } else {
            nil
        }
        if let previousIdentity, previousIdentity != nextIdentity {
            self.advanceAccountIdentityGeneration()
            self.clearAPIResponseCaches()
        }
        self.state = newState
    }

    private var activeAuthenticationIdentity: String? {
        if case let .loggedIn(sapisid) = self.state {
            return sapisid
        }
        if self.state == .loggingIn,
           case let .loggedIn(sapisid)? = self.stateBeforeLogin
        {
            return sapisid
        }
        return nil
    }

    private func invalidateLoginCheck() {
        self.loginCheckGeneration &+= 1
        self.loginCheckTask?.cancel()
        self.loginCheckTask = nil
    }

    private func resolveLoginState() async -> State {
        if UITestConfig.isUITestMode,
           UITestConfig.environmentValue(for: UITestConfig.mockLoggedOutKey) == "true"
        {
            self.logger.info("UI Test mode: forcing logged out state")
            return .loggedOut
        }

        if UITestConfig.isUITestMode, UITestConfig.shouldSkipAuth {
            self.logger.info("UI Test mode: skipping auth check, assuming logged in")
            return .loggedIn(sapisid: "mock-sapisid-for-ui-tests")
        }

        self.logger.debug("Checking login status from cookies")
        await self.webKitManager.waitForInitialCookieRestore()
        guard !Task.isCancelled else { return self.state }
        self.logger.debug("Initial cookie restore completed, checking auth cookies")

        #if DEBUG
            await self.webKitManager.logAuthCookies()
            guard !Task.isCancelled else { return self.state }
        #endif

        if let sapisid = await self.webKitManager.getSAPISID() {
            self.logger.info("Found SAPISID cookie after initial restore, user is logged in")
            return .loggedIn(sapisid: sapisid)
        }

        self.logger.info("No SAPISID cookie found after initial restore, user is logged out")
        return .loggedOut
    }
}
