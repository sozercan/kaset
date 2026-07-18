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
        self.isGuestModeEnabled = true
    }

    /// Leaves guest mode and resumes the signed-in personal account.
    func exitGuestMode(activeAccountID: String? = nil) {
        guard self.isGuestModeEnabled else { return }
        self.logger.info("Leaving guest mode")
        self.clearAPIResponseCaches()
        SongLikeStatusManager.shared.setActiveAccountID(activeAccountID)
        self.isGuestModeEnabled = false
    }

    /// Starts the login flow by presenting the login sheet.
    func startLogin() {
        self.logger.info("Starting login flow")
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

    /// Checks if the user is logged in based on existing cookies.
    /// Waits for the initial Keychain restore before reading WebKit cookies.
    func checkLoginStatus() async {
        // In UI test mode with skip auth, immediately set logged in state
        if UITestConfig.isUITestMode, UITestConfig.environmentValue(for: UITestConfig.mockLoggedOutKey) == "true" {
            self.logger.info("UI Test mode: forcing logged out state")
            self.state = .loggedOut
            return
        }

        if UITestConfig.isUITestMode, UITestConfig.shouldSkipAuth {
            self.logger.info("UI Test mode: skipping auth check, assuming logged in")
            self.state = .loggedIn(sapisid: "mock-sapisid-for-ui-tests")
            return
        }

        self.logger.debug("Checking login status from cookies")

        await self.webKitManager.waitForInitialCookieRestore()
        self.logger.debug("Initial cookie restore completed, checking auth cookies")

        // Log detailed cookie info for debugging
        #if DEBUG
            await self.webKitManager.logAuthCookies()
        #endif

        if let sapisid = await self.webKitManager.getSAPISID() {
            self.logger.info("Found SAPISID cookie after initial restore, user is logged in")
            self.state = .loggedIn(sapisid: sapisid)
            self.needsReauth = false
            return
        }

        self.logger.info("No SAPISID cookie found after initial restore, user is logged out")
        self.state = .loggedOut
    }

    /// Called when a session expires (e.g., 401/403 from API).
    func sessionExpired() {
        self.logger.warning("Session expired, requiring re-authentication")
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

    /// Signs out the user by clearing all cookies and data.
    func signOut() async {
        self.logger.info("Signing out user")

        await self.webKitManager.clearAllData()
        self.clearAPIResponseCaches()

        self.state = .loggedOut
        self.isGuestModeEnabled = false
        self.needsReauth = false
        self.stateBeforeLogin = nil

        self.logger.info("User signed out successfully")
    }

    private func clearAPIResponseCaches() {
        APICache.shared.invalidateAll()
        URLCache.shared.removeAllCachedResponses()
    }

    /// Called when login completes successfully (from LoginSheet observation).
    func completeLogin(sapisid: String) {
        self.logger.info("Login completed successfully")
        self.state = .loggedIn(sapisid: sapisid)
        self.isGuestModeEnabled = false
        self.needsReauth = false
        self.stateBeforeLogin = nil
    }
}
