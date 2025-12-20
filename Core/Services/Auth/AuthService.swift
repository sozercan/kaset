import Foundation
import Observation
import os

/// Manages authentication state for YouTube Music.
@MainActor
@Observable
final class AuthService {
    /// Authentication states.
    enum State: Equatable, Sendable {
        case loggedOut
        case loggingIn
        case loggedIn(sapisid: String)

        var isLoggedIn: Bool {
            if case .loggedIn = self { return true }
            return false
        }
    }

    /// Current authentication state.
    private(set) var state: State = .loggedOut

    /// Flag indicating whether re-authentication is needed.
    var needsReauth: Bool = false

    private let webKitManager: WebKitManager
    private let logger = DiagnosticsLogger.auth

    init(webKitManager: WebKitManager = .shared) {
        self.webKitManager = webKitManager
    }

    /// Starts the login flow by presenting the login sheet.
    func startLogin() {
        logger.info("Starting login flow")
        state = .loggingIn
    }

    /// Checks if the user is logged in based on existing cookies.
    func checkLoginStatus() async {
        logger.debug("Checking login status from cookies")

        guard let sapisid = await webKitManager.getSAPISID() else {
            logger.info("No SAPISID cookie found, user is logged out")
            state = .loggedOut
            return
        }

        logger.info("Found SAPISID cookie, user is logged in")
        state = .loggedIn(sapisid: sapisid)
        needsReauth = false
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
