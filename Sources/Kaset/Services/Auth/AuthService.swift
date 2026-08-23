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

    /// Whether a failed login cleanup must be retried before another sign-in.
    private(set) var loginCleanupRequired = false

    /// Whether failed-login cleanup still owns the account boundary.
    private(set) var isLoginCleanupInProgress = false

    /// Whether pending cleanup originated from a guest/logged-out login attempt.
    private var loginCleanupPersistsGuestPlaybackState = false

    /// Changes synchronously whenever an explicit sign-out begins.
    private(set) var signOutSequence: UInt64 = 0

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
        if self.loginCleanupRequired {
            return true
        }
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
        if self.loginCleanupRequired {
            return self.loginCleanupPersistsGuestPlaybackState
        }
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
    private var nextLoginAttemptID: UInt64 = 0
    private(set) var activeLoginAttemptID: LoginAttemptID?
    private var cancellingLoginAttemptID: LoginAttemptID?
    private var signOutTask: Task<Bool, Never>?
    private var signOutPreparation: (@MainActor @Sendable () async -> Void)?
    private var accountBoundaryWillBegin: (@MainActor @Sendable () -> Void)?
    private var accountBoundaryDidEnd: (@MainActor @Sendable () -> Void)?
    private var accountBoundaryDrain: (@MainActor @Sendable () async -> Void)?
    private var guestModeTransitionGeneration: UInt64 = 0
    private var loginCleanupOperationGeneration: UInt64 = 0

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

    func setLoginCleanupRequired(_ required: Bool) {
        self.updateLoginCleanupRequirement(
            required,
            requiresReauthentication: self.loginFailureRequiresReauthentication
        )
    }

    /// Temporarily uses public guest mode while preserving the signed-in session.
    func enterGuestMode() async {
        guard self.state.isLoggedIn else { return }
        guard !self.isGuestModeEnabled else { return }
        self.guestModeTransitionGeneration &+= 1
        let transitionGeneration = self.guestModeTransitionGeneration
        self.accountBoundaryWillBegin?()
        defer { self.accountBoundaryDidEnd?() }
        await self.accountBoundaryDrain?()
        guard transitionGeneration == self.guestModeTransitionGeneration,
              self.state.isLoggedIn,
              !self.isGuestModeEnabled
        else { return }
        self.applyGuestMode()
    }

    private func applyGuestMode() {
        self.logger.info("Entering guest mode")
        self.clearAPIResponseCaches()
        SongLikeStatusManager.shared.setActiveAccountID(SongLikeStatusManager.guestAccountID)
        FavoritesManager.shared.enterGuestMode()
        self.isGuestModeEnabled = true
    }

    /// Leaves guest mode and resumes the signed-in personal account.
    func exitGuestMode(activeAccountID: String? = nil) async {
        guard self.isGuestModeEnabled else { return }
        self.guestModeTransitionGeneration &+= 1
        let transitionGeneration = self.guestModeTransitionGeneration
        self.accountBoundaryWillBegin?()
        defer { self.accountBoundaryDidEnd?() }
        await self.accountBoundaryDrain?()
        guard transitionGeneration == self.guestModeTransitionGeneration,
              self.isGuestModeEnabled
        else { return }
        self.applyPersonalMode(activeAccountID: activeAccountID)
    }

    func cancelPendingGuestModeTransition() {
        self.guestModeTransitionGeneration &+= 1
    }

    private func applyPersonalMode(activeAccountID: String?) {
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
        guard !self.isLoginCleanupInProgress else {
            self.logger.info("Ignoring login request while failed-login cleanup is in progress")
            return
        }
        guard self.state != .loggingIn, self.activeLoginAttemptID == nil else {
            self.logger.info("Ignoring login request while an attempt is active")
            return
        }
        self.invalidateLoginCheck()
        self.stateBeforeLogin = self.state
        self.nextLoginAttemptID &+= 1
        self.activeLoginAttemptID = LoginAttemptID(rawValue: self.nextLoginAttemptID)
        self.cancellingLoginAttemptID = nil
        self.state = .loggingIn
    }

    /// Cancels an in-progress login presentation without changing an already
    /// completed authenticated session.
    func cancelLoginIfNeeded(expectedAttemptID: LoginAttemptID? = nil) {
        guard self.beginLoginCancellation(expectedAttemptID: expectedAttemptID) else { return }
        self.finishLoginCancellation()
    }

    func beginLoginCancellation(expectedAttemptID: LoginAttemptID?) -> Bool {
        guard self.state == .loggingIn else { return false }
        if let expectedAttemptID,
           self.activeLoginAttemptID != expectedAttemptID
        {
            self.logger.info("Ignoring cancellation from a stale login attempt")
            return false
        }
        self.logger.info("Login flow cancellation started")
        self.invalidateLoginCheck()
        self.cancellingLoginAttemptID = self.activeLoginAttemptID
        return true
    }

    func finishLoginCancellation() {
        guard self.state == .loggingIn,
              let cancellingLoginAttemptID = self.cancellingLoginAttemptID,
              self.activeLoginAttemptID == cancellingLoginAttemptID
        else { return }
        self.activeLoginAttemptID = nil
        self.cancellingLoginAttemptID = nil
        self.state = self.stateBeforeLogin ?? .loggedOut
        self.stateBeforeLogin = nil
        self.logger.info("Login flow cancelled")
    }

    /// Registers account-owned WebKit mutation cleanup that every sign-out must await.
    func setSignOutPreparation(_ preparation: @escaping @MainActor @Sendable () async -> Void) {
        self.signOutPreparation = preparation
    }

    /// Registers synchronous cancellation for account-scoped work before cookies,
    /// guest mode, or authenticated identity can change.
    func setAccountBoundaryHandlers(
        willBegin: @escaping @MainActor @Sendable () -> Void,
        didEnd: @escaping @MainActor @Sendable () -> Void,
        drain: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.accountBoundaryWillBegin = willBegin
        self.accountBoundaryDidEnd = didEnd
        self.accountBoundaryDrain = drain
    }

    /// Checks if the user is logged in based on existing cookies.
    /// Waits for the initial Keychain restore before reading WebKit cookies.
    func checkLoginStatus() async {
        if let signOutTask = self.signOutTask {
            _ = await signOutTask.value
            if self.signOutTask == signOutTask {
                self.signOutTask = nil
            }
            return
        }
        if let loginCheckTask = self.loginCheckTask {
            await loginCheckTask.value
            return
        }
        guard self.activeLoginAttemptID == nil, self.state != .loggingIn else {
            self.logger.info("Ignoring login-status check while a login attempt is active")
            return
        }
        guard !self.loginCleanupRequired else {
            self.logger.error("Refusing to evaluate authentication until cookie cleanup succeeds")
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

            guard await self.transitionToResolvedState(
                resolvedState,
                expectedLoginCheckGeneration: checkGeneration
            ) else { return }
            if resolvedState.isLoggedIn {
                self.needsReauth = false
                self.updateLoginCleanupRequirement(false, requiresReauthentication: false)
            }
        }
        self.loginCheckTask = task
        await task.value
        guard self.loginCheckTask == task else { return }
        self.loginCheckTask = nil
    }

    /// Called when a session expires (e.g., 401/403 from API).
    func sessionExpired() {
        self.cancelPendingGuestModeTransition()
        self.accountBoundaryWillBegin?()
        defer { self.accountBoundaryDidEnd?() }
        self.applySessionExpiration()
    }

    /// Expires only the authentication identity that originated an async request.
    func sessionExpired(ifIdentityGenerationMatches generation: UInt64) {
        guard generation == self.accountIdentityGeneration else { return }
        self.sessionExpired()
    }

    /// Signs out the user by draining account-owned WebKit mutations, then clearing all data.
    @discardableResult
    func signOut() async -> Bool {
        if let signOutTask = self.signOutTask {
            return await signOutTask.value
        }
        self.logger.info("Signing out user")
        guard self.webKitManager.invalidateAuthCookieRestoration() else {
            self.logger.error("Could not persist sign-out intent before account drain")
            return false
        }
        self.signOutSequence &+= 1
        self.cancelPendingGuestModeTransition()
        self.accountBoundaryWillBegin?()

        // Fence authenticated work synchronously before the first suspension.
        self.invalidateLoginCheck()
        self.activeLoginAttemptID = nil
        self.cancellingLoginAttemptID = nil
        self.advanceAccountIdentityGeneration()
        self.clearAPIResponseCaches()
        self.state = .loggedOut
        self.isGuestModeEnabled = false
        self.needsReauth = false
        self.stateBeforeLogin = nil

        let preparation = self.signOutPreparation
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer { self.accountBoundaryDidEnd?() }
            await self.accountBoundaryDrain?()
            await preparation?()
            let didInvalidatePersistedCookies = await self.webKitManager.clearAllData()
            self.clearAPIResponseCaches()
            self.updateLoginCleanupRequirement(
                !didInvalidatePersistedCookies,
                requiresReauthentication: false
            )
            if didInvalidatePersistedCookies {
                self.logger.info("User signed out successfully")
            } else {
                self.logger.error("User signed out, but durable cookie invalidation failed")
            }
            return didInvalidatePersistedCookies
        }
        self.signOutTask = task
        let didSignOutDurably = await task.value
        if self.signOutTask == task {
            self.signOutTask = nil
        }
        return didSignOutDurably
    }

    private func clearAPIResponseCaches() {
        APICache.shared.invalidateAll()
        URLCache.shared.removeAllCachedResponses()
    }

    /// Commits a detected login only if its attempt remains current while account work drains.
    func completeLoginAfterDraining(
        expectedAttemptID: LoginAttemptID,
        persistBeforeCommit: @escaping @MainActor @Sendable () async -> String?,
        persistFinalSession: @escaping @MainActor @Sendable () async -> String?,
        willPublishLogin: @escaping @MainActor @Sendable () -> Void
    ) async -> Bool {
        guard self.signOutTask == nil,
              self.state == .loggingIn,
              self.activeLoginAttemptID == expectedAttemptID,
              self.cancellingLoginAttemptID != expectedAttemptID
        else {
            self.logger.info("Ignoring login completion without the matching active attempt")
            return false
        }
        self.cancelPendingGuestModeTransition()
        self.accountBoundaryWillBegin?()
        defer { self.accountBoundaryDidEnd?() }
        self.invalidateLoginCheck()
        await self.accountBoundaryDrain?()
        guard !Task.isCancelled,
              self.signOutTask == nil,
              self.state == .loggingIn,
              self.activeLoginAttemptID == expectedAttemptID,
              self.cancellingLoginAttemptID != expectedAttemptID
        else {
            self.logger.info("Ignoring login completion superseded while draining account work")
            return false
        }
        guard await persistBeforeCommit() != nil else {
            self.logger.info("Ignoring login completion because durable persistence did not commit")
            return false
        }
        guard !Task.isCancelled,
              self.signOutTask == nil,
              self.state == .loggingIn,
              self.activeLoginAttemptID == expectedAttemptID,
              self.cancellingLoginAttemptID != expectedAttemptID,
              let finalSessionValue = await persistFinalSession(),
              !Task.isCancelled,
              self.signOutTask == nil,
              self.state == .loggingIn,
              self.activeLoginAttemptID == expectedAttemptID,
              self.cancellingLoginAttemptID != expectedAttemptID
        else {
            self.logger.info("Ignoring login completion superseded during final persistence")
            return false
        }
        willPublishLogin()
        self.applyCompletedLogin(sapisid: finalSessionValue)
        self.activeLoginAttemptID = nil
        self.cancellingLoginAttemptID = nil
        self.logger.info("Login completed successfully")
        return true
    }

    private var loginFailureRequiresReauthentication: Bool {
        if self.needsReauth || self.state.isLoggedIn {
            return true
        }
        if self.state == .loggingIn, self.stateBeforeLogin?.isLoggedIn == true {
            return true
        }
        return false
    }

    func resolveLoginRollbackAfterDraining(
        expectedAttemptID: LoginAttemptID?,
        prepareRollback: @escaping @MainActor @Sendable () async -> Bool,
        rollback: @escaping @MainActor @Sendable (_ forceCleanup: Bool) async -> CookieBackupRollbackResult
    ) async -> CookieBackupRollbackResult {
        let requiresReauthentication = self.loginFailureRequiresReauthentication
        let ownsAttempt = expectedAttemptID != nil
            && self.activeLoginAttemptID == expectedAttemptID
            && self.state == .loggingIn
        if ownsAttempt {
            _ = self.beginLoginCancellation(expectedAttemptID: expectedAttemptID)
        }

        self.accountBoundaryWillBegin?()
        defer { self.accountBoundaryDidEnd?() }
        let didPrepareRollback = await prepareRollback()
        await self.accountBoundaryDrain?()
        if !didPrepareRollback {
            self.logger.error("Could not disable cookie restoration before login rollback; forcing cleanup")
        }
        let result = await rollback(!didPrepareRollback)

        guard ownsAttempt,
              self.activeLoginAttemptID == expectedAttemptID
        else {
            if result == .failed, self.state == .loggedOut {
                self.updateLoginCleanupRequirement(
                    true,
                    requiresReauthentication: requiresReauthentication
                )
            }
            return result
        }

        switch result {
        case .rolledBack:
            self.updateLoginCleanupRequirement(false, requiresReauthentication: false)
            self.finishLoginCancellation()
        case .superseded:
            self.updateLoginCleanupRequirement(
                true,
                requiresReauthentication: requiresReauthentication
            )
            self.applySessionExpiration()
            self.needsReauth = requiresReauthentication
        case .cleared:
            self.updateLoginCleanupRequirement(false, requiresReauthentication: false)
            self.applySessionExpiration()
            self.needsReauth = requiresReauthentication
        case .failed:
            self.updateLoginCleanupRequirement(
                true,
                requiresReauthentication: requiresReauthentication
            )
            self.applySessionExpiration()
            self.needsReauth = requiresReauthentication
        }
        return result
    }

    func clearFailedLoginAfterDraining(
        expectedAttemptID: LoginAttemptID,
        expectedSignOutSequence: UInt64,
        clearCookies: @escaping @MainActor @Sendable () async -> Bool
    ) async -> Bool? {
        guard self.signOutSequence == expectedSignOutSequence else { return nil }
        let requiresReauthentication = self.loginFailureRequiresReauthentication
        let ownsActiveAttempt = self.activeLoginAttemptID == expectedAttemptID
        let ownsLoggedOutResidual = self.activeLoginAttemptID == nil
            && expectedAttemptID.rawValue == self.nextLoginAttemptID
            && self.state == .loggedOut
            && self.signOutTask == nil
        guard ownsActiveAttempt || ownsLoggedOutResidual else { return nil }
        guard self.webKitManager.invalidateAuthCookieRestoration() else {
            self.updateLoginCleanupRequirement(
                true,
                requiresReauthentication: requiresReauthentication
            )
            self.logger.error("Could not persist failed-login cleanup intent before account drain")
            return false
        }

        self.loginCleanupOperationGeneration &+= 1
        let cleanupOperationGeneration = self.loginCleanupOperationGeneration
        self.isLoginCleanupInProgress = true
        defer {
            if self.loginCleanupOperationGeneration == cleanupOperationGeneration {
                self.isLoginCleanupInProgress = false
            }
        }

        self.cancelPendingGuestModeTransition()
        self.accountBoundaryWillBegin?()
        defer { self.accountBoundaryDidEnd?() }
        self.updateLoginCleanupRequirement(
            true,
            requiresReauthentication: requiresReauthentication
        )
        self.applySessionExpiration()
        self.needsReauth = requiresReauthentication
        let cleanupGeneration = self.accountIdentityGeneration

        await self.accountBoundaryDrain?()
        guard cleanupGeneration == self.accountIdentityGeneration,
              self.signOutSequence == expectedSignOutSequence,
              self.state == .loggedOut
        else { return nil }

        let didClear = await clearCookies()
        guard cleanupGeneration == self.accountIdentityGeneration,
              self.signOutSequence == expectedSignOutSequence,
              self.state == .loggedOut
        else { return nil }
        self.updateLoginCleanupRequirement(
            !didClear,
            requiresReauthentication: requiresReauthentication
        )
        return didClear
    }

    private func updateLoginCleanupRequirement(
        _ required: Bool,
        requiresReauthentication: Bool
    ) {
        self.loginCleanupRequired = required
        self.loginCleanupPersistsGuestPlaybackState = required && !requiresReauthentication
    }

    private func applySessionExpiration() {
        self.logger.warning("Session expired, requiring re-authentication")
        self.invalidateLoginCheck()
        self.activeLoginAttemptID = nil
        self.cancellingLoginAttemptID = nil
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

    #if DEBUG
        /// Test-only fast path for isolated AuthService instances with no account-boundary wiring.
        func completeLogin(sapisid: String) {
            precondition(
                self.accountBoundaryWillBegin == nil
                    && self.accountBoundaryDidEnd == nil
                    && self.accountBoundaryDrain == nil,
                "Use completeLoginAfterDraining(expectedAttemptID:persistBeforeCommit:persistFinalSession:willPublishLogin:) when account-boundary handlers are installed"
            )
            self.logger.info("Login completed successfully")
            guard self.signOutTask == nil else {
                self.logger.info("Ignoring login completion while sign-out is in progress")
                return
            }
            self.cancelPendingGuestModeTransition()
            self.invalidateLoginCheck()
            self.applyCompletedLogin(sapisid: sapisid)
            self.activeLoginAttemptID = nil
            self.cancellingLoginAttemptID = nil
        }
    #endif

    private func applyCompletedLogin(sapisid: String) {
        if self.isGuestModeEnabled {
            self.applyPersonalMode(activeAccountID: nil)
        }
        // Login completion is an explicit identity boundary even when Google
        // reuses the same SAPISID across multi-login accounts. Fence every older
        // authenticated request before publishing the resolved session.
        self.advanceAccountIdentityGeneration()
        self.clearAPIResponseCaches()
        self.state = .loggedIn(sapisid: sapisid)
        self.needsReauth = false
        self.updateLoginCleanupRequirement(false, requiresReauthentication: false)
        self.stateBeforeLogin = nil
    }

    private func advanceAccountIdentityGeneration() {
        self.accountIdentityGeneration &+= 1
    }

    private func transitionToResolvedState(
        _ newState: State,
        expectedLoginCheckGeneration: UInt64
    ) async -> Bool {
        let previousIdentity = self.activeAuthenticationIdentity
        let nextIdentity: String? = if case let .loggedIn(sapisid) = newState {
            sapisid
        } else {
            nil
        }
        let identityChanged = previousIdentity != nil && previousIdentity != nextIdentity
        if identityChanged {
            self.cancelPendingGuestModeTransition()
            self.accountBoundaryWillBegin?()
        }
        defer {
            if identityChanged {
                self.accountBoundaryDidEnd?()
            }
        }
        if identityChanged {
            await self.accountBoundaryDrain?()
        }
        guard expectedLoginCheckGeneration == self.loginCheckGeneration,
              self.activeLoginAttemptID == nil,
              self.state != .loggingIn,
              !Task.isCancelled
        else { return false }
        if identityChanged {
            self.advanceAccountIdentityGeneration()
            self.clearAPIResponseCaches()
        }
        self.state = newState
        self.activeLoginAttemptID = nil
        self.cancellingLoginAttemptID = nil
        return true
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

        guard !self.loginCleanupRequired else {
            self.logger.error("Cookie cleanup is pending; resolving authentication as logged out")
            return .loggedOut
        }

        self.logger.debug("Checking login status from cookies")
        let canEvaluateAuthentication = await self.webKitManager.waitForInitialCookieRestore()
        guard !Task.isCancelled else { return self.state }
        guard !self.loginCleanupRequired else { return .loggedOut }
        guard canEvaluateAuthentication else {
            self.logger.error("Initial cookie cleanup failed; refusing to evaluate authentication cookies")
            self.updateLoginCleanupRequirement(true, requiresReauthentication: true)
            self.needsReauth = true
            return .loggedOut
        }
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
