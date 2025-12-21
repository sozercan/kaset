import Foundation
import Observation
import os

/// Manages authentication state for YouTube Music.
@MainActor
@Observable
final class AuthService: AuthServiceProtocol {
    /// Authentication states.
    enum State: Equatable, Sendable {
        case initializing
        case loggedOut
        case loggingIn
        case loggedIn(sapisid: String)

        var isLoggedIn: Bool {
            if case .loggedIn = self { return true }
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

    private let webKitManager: WebKitManagerProtocol
    private let logger = DiagnosticsLogger.auth

    init(webKitManager: WebKitManagerProtocol = WebKitManager.shared) {
        self.webKitManager = webKitManager
        // In UI test mode with skip auth, start in logged-in state immediately
        // This avoids async delays that can cause UI test flakiness
        let isUITest = UITestConfig.isUITestMode
        let skipAuth = UITestConfig.shouldSkipAuth
        logger.debug("AuthService init: isUITestMode=\(isUITest), shouldSkipAuth=\(skipAuth)")
        if isUITest, skipAuth {
            logger.info("UI Test mode with SkipAuth: starting in logged-in state")
            self.state = .loggedIn(sapisid: "mock-sapisid-for-ui-tests")
        } else {
            self.state = .initializing
        }
    }

    /// Starts the login flow by presenting the login sheet.
    func startLogin() {
        logger.info("Starting login flow")
        state = .loggingIn
    }

    /// Checks if the user is logged in based on existing cookies.
    /// Includes retry logic to handle WebKit cookie store lazy loading.
    func checkLoginStatus() async {
        // In UI test mode with skip auth, immediately set logged in state
        if UITestConfig.isUITestMode, UITestConfig.shouldSkipAuth {
            logger.info("UI Test mode: skipping auth check, assuming logged in")
            state = .loggedIn(sapisid: "mock-sapisid-for-ui-tests")
            return
        }

        logger.debug("Checking login status from cookies")

        // Wait for WebKitManager to finish restoring cookies from Keychain
        // This is important because restoration happens async in init()
        try? await Task.sleep(for: .milliseconds(500))

        // Log detailed cookie info for debugging
        #if DEBUG
            await webKitManager.logAuthCookies()
        #endif

        // Retry a few times to handle WebKit cookie store lazy loading
        // Cookies may not be immediately available on cold start
        // Increased attempts and delay to account for disk I/O
        let maxAttempts = 5
        let delayBetweenAttempts: Duration = .milliseconds(800)

        for attempt in 1 ... maxAttempts {
            logger.debug("Login check attempt \(attempt) of \(maxAttempts)")

            if let sapisid = await webKitManager.getSAPISID() {
                logger.info("Found SAPISID cookie on attempt \(attempt), user is logged in")
                state = .loggedIn(sapisid: sapisid)
                needsReauth = false
                return
            }

            if attempt < maxAttempts {
                logger.debug("No cookies found, waiting before retry...")
                try? await Task.sleep(for: delayBetweenAttempts)
            }
        }

        logger.info("No SAPISID cookie found after \(maxAttempts) attempts, user is logged out")
        state = .loggedOut
    }

    /// Called when a session expires (e.g., 401/403 from API).
    func sessionExpired() {
        logger.warning("Session expired, requiring re-authentication")
        state = .loggedOut
        needsReauth = true
    }

    /// Signs out the user by clearing all cookies and data.
    func signOut() async {
        logger.info("Signing out user")

        await webKitManager.clearAllData()

        state = .loggedOut
        needsReauth = false

        logger.info("User signed out successfully")
    }

    /// Called when login completes successfully (from LoginSheet observation).
    func completeLogin(sapisid: String) {
        logger.info("Login completed successfully")
        state = .loggedIn(sapisid: sapisid)
        needsReauth = false
    }
}
