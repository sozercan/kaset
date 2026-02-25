// AccountService.swift
// Kaset
//
// Manages account state and brand account switching.

import Foundation
import os

/// Manages account state and switching between primary and brand accounts.
///
/// YouTube Music allows users to switch between their primary Google account
/// and associated brand accounts. This service handles:
/// - Fetching available accounts after login
/// - Switching between accounts
/// - Persisting the selected account across app launches
///
/// ## Usage
/// ```swift
/// // Fetch accounts after login
/// await accountService.fetchAccounts()
///
/// // Switch to a brand account
/// if let brandAccount = accountService.accounts.first(where: { !$0.isPrimary }) {
///     try await accountService.switchAccount(to: brandAccount)
/// }
/// ```
@Observable
@MainActor
final class AccountService {
    // MARK: - Dependencies

    private let ytMusicClient: any YTMusicClientProtocol
    private let authService: AuthService

    // MARK: - Published State

    /// All available accounts (primary + brand accounts).
    private(set) var accounts: [UserAccount] = []

    /// Currently selected/active account.
    private(set) var currentAccount: UserAccount?

    /// Whether an account operation is in progress.
    private(set) var isLoading: Bool = false

    /// Last error encountered, for toast display.
    private(set) var lastError: Error?

    /// Whether the last error was from fetching accounts (vs switching).
    private(set) var lastErrorWasFetch: Bool = false

    /// Incremented each time an error occurs, to trigger toast re-display.
    private(set) var errorSequence: Int = 0

    // MARK: - Computed Properties

    /// Returns `true` if the user has multiple accounts (brand accounts available).
    var hasBrandAccounts: Bool {
        self.accounts.count > 1
    }

    /// The brand ID of the currently selected account, if any.
    var currentBrandId: String? {
        self.currentAccount?.brandId
    }

    // MARK: - Private

    private let logger = DiagnosticsLogger.auth
    private let selectedBrandIdKey = "selectedBrandId"

    // MARK: - Initialization

    /// Creates an AccountService with the required dependencies.
    ///
    /// - Parameters:
    ///   - ytMusicClient: Client for YouTube Music API calls.
    ///   - authService: Service for checking authentication state.
    init(ytMusicClient: any YTMusicClientProtocol, authService: AuthService) {
        self.ytMusicClient = ytMusicClient
        self.authService = authService
    }

    // MARK: - Public Methods

    /// Fetches the list of available accounts from the API.
    ///
    /// This should be called after login to populate the accounts list.
    /// If a previously selected account ID is stored, that account will be
    /// automatically selected.
    func fetchAccounts() async {
        guard self.authService.state.isLoggedIn else {
            self.logger.debug("AccountService: Skipping fetch - not logged in")
            return
        }

        self.logger.info("AccountService: Fetching accounts list")
        self.isLoading = true

        defer {
            self.isLoading = false
        }

        do {
            let response = try await self.ytMusicClient.fetchAccountsList()
            self.accounts = response.accounts

            // Restore previously selected account if stored
            if let savedBrandId = UserDefaults.standard.string(forKey: self.selectedBrandIdKey) {
                self.logger.debug("AccountService: Found saved brand ID: \(savedBrandId)")

                // Find the account with the saved brand ID
                if let savedAccount = self.accounts.first(where: { $0.id == savedBrandId }) {
                    self.currentAccount = savedAccount
                    self.logger.info("AccountService: Restored previous account: \(savedAccount.name)")
                } else {
                    // Saved account no longer available, use API-selected
                    self.currentAccount = response.selectedAccount ?? self.accounts.first
                    self.logger.debug("AccountService: Saved account not found, using API-selected")
                }
            } else {
                // Default to the currently selected account from API response
                self.currentAccount = response.selectedAccount ?? self.accounts.first
                self.logger.debug("AccountService: Using API-selected account")
            }

            let currentLabel = self.currentAccount?.brandId ?? "primary"
            self.logger.info("AccountService: Fetched \(self.accounts.count) accounts, current: \(self.currentAccount?.name ?? "none") (brandId=\(currentLabel))")
        } catch {
            self.logger.error("AccountService: Failed to fetch accounts: \(error.localizedDescription)")
            self.lastError = error
            self.lastErrorWasFetch = true
            self.errorSequence += 1
        }
    }

    /// Switches to a different account.
    ///
    /// - Parameter account: The account to switch to.
    /// - Throws: An error if the switch fails.
    func switchAccount(to account: UserAccount) async throws {
        guard account != self.currentAccount else {
            self.logger.debug("AccountService: Already using account \(account.name)")
            return
        }

        let previousAccount = self.currentAccount
        self.logger.info("AccountService: Switching to account: \(account.name)")
        self.isLoading = true

        defer {
            self.isLoading = false
        }

        do {
            // Note: API call to switch server-side identity is not implemented yet.
            // Currently we only update local state. Server-side switching can be added
            // when the selectActiveIdentity endpoint is explored and documented.

            // Update local state
            self.currentAccount = account

            if UITestConfig.isUITestMode,
               UITestConfig.environmentValue(for: UITestConfig.mockAccountSwitchFailKey) == "true"
            {
                throw YTMusicError.apiError(message: "Mock account switch failure", code: nil)
            }

            // Reset client session state to avoid leaking continuations across accounts
            self.ytMusicClient.resetSessionStateForAccountSwitch()

            let brandLabel = account.brandId ?? "primary"
            self.logger.info("AccountService: Active account brandId=\(brandLabel)")

            // Persist selection
            UserDefaults.standard.set(account.id, forKey: self.selectedBrandIdKey)
            self.logger.debug("AccountService: Saved brand ID: \(account.id)")

            self.logger.info("AccountService: Successfully switched to account: \(account.name)")
        } catch {
            self.logger.error("AccountService: Failed to switch account: \(error.localizedDescription)")
            self.currentAccount = previousAccount
            self.lastError = error
            self.lastErrorWasFetch = false
            self.errorSequence += 1
            throw error
        }
    }

    /// Clears all account data.
    ///
    /// Should be called when the user logs out to reset state.
    func clearAccounts() {
        self.logger.info("AccountService: Clearing accounts data")

        self.accounts = []
        self.currentAccount = nil
        UserDefaults.standard.removeObject(forKey: self.selectedBrandIdKey)

        self.logger.debug("AccountService: Accounts cleared")
    }

    /// Clears the last error after it has been displayed.
    ///
    /// Call this after showing an error toast to reset the error state.
    func clearError() {
        self.lastError = nil
        self.lastErrorWasFetch = false
    }
}
