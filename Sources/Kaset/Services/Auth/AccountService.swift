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

    /// WebKit session manager used to re-point the playback session's active
    /// delegated identity on account switch. Optional so SwiftUI previews and
    /// lightweight constructions can omit it; when nil, switching falls back to
    /// local-state-only (history will not record to brand accounts).
    private let webKitManager: (any WebKitManagerProtocol)?

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

    /// Tracks the off-path restore-pin so it can be observed in tests and is not
    /// orphaned. Replaced on each `fetchAccounts`.
    private var brandSessionPinTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Creates an AccountService with the required dependencies.
    ///
    /// - Parameters:
    ///   - ytMusicClient: Client for YouTube Music API calls.
    ///   - authService: Service for checking authentication state.
    ///   - webKitManager: WebKit session manager used to switch the playback
    ///     session's active identity on account switch. Omit (nil) in previews.
    init(
        ytMusicClient: any YTMusicClientProtocol,
        authService: AuthService,
        webKitManager: (any WebKitManagerProtocol)? = nil
    ) {
        self.ytMusicClient = ytMusicClient
        self.authService = authService
        self.webKitManager = webKitManager
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

            SongLikeStatusManager.shared.setActiveAccountID(self.currentAccount?.id)

            let currentLabel = self.currentAccount?.brandId ?? "primary"
            self.logger.info("AccountService: Fetched \(self.accounts.count) accounts, current: \(self.currentAccount?.name ?? "none") (brandId=\(currentLabel))")

            // Re-establish the WebView session identity for a restored brand
            // account. Without this, a relaunch leaves native reads brand-aware
            // while the playback session is still primary, so playback would
            // record history to the primary account (the issue-#277 bug, on every
            // cold launch). Run it OFF the fetch path (after isLoading clears) so
            // a real ≤20s navigation never stalls launch or holds the account
            // spinner; it is best-effort and surfaced via logs on failure.
            self.scheduleRestoredBrandSessionPin()
        } catch {
            self.logger.error("AccountService: Failed to fetch accounts: \(error.localizedDescription)")
            self.lastError = error
            self.lastErrorWasFetch = true
            self.errorSequence += 1
        }
    }

    /// Schedules a best-effort WebView session pin for a restored brand account,
    /// off the `fetchAccounts` path so it never blocks launch or holds
    /// `isLoading`.
    ///
    /// No-op for the primary account (the default session identity) or when no
    /// WebKit manager is injected. Verification failures are logged, not thrown.
    private func scheduleRestoredBrandSessionPin() {
        guard !UITestConfig.isUITestMode,
              let webKitManager = self.webKitManager,
              let account = self.currentAccount,
              let brandId = account.brandId,
              let signinURL = account.signinURL
        else {
            return
        }

        self.brandSessionPinTask?.cancel()
        self.brandSessionPinTask = Task { [weak self] in
            do {
                try await webKitManager.switchSessionIdentity(to: signinURL, expectedBrandId: brandId)
                self?.logger.info("AccountService: Restored brand session identity for \(account.name)")
            } catch {
                self?.logger.error("AccountService: Could not restore brand session identity: \(error.localizedDescription)")
            }
        }
    }

    /// Awaits the in-flight restored-brand-session pin, if any. Test hook.
    func awaitRestoredBrandSessionPinForTesting() async {
        await self.brandSessionPinTask?.value
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
            if UITestConfig.isUITestMode,
               UITestConfig.environmentValue(for: UITestConfig.mockAccountSwitchFailKey) == "true"
            {
                throw YTMusicError.apiError(message: "Mock account switch failure", code: nil)
            }

            // Re-point the playback session's active delegated identity BEFORE
            // committing the new account. History is recorded by the playback
            // WebView's own stats pings, which attribute to the identity baked
            // into the served document (ytcfg.DATASYNC_ID). Navigating the
            // server-issued signin URL switches that identity for the shared
            // cookie session; verifying it here means a failed/unverified switch
            // throws into the catch block below and reverts, rather than silently
            // recording plays to the wrong account.
            //
            // Skipped in UI test mode (no real WebKit session) and when no
            // webKitManager was injected (e.g. previews).
            if !UITestConfig.isUITestMode, let webKitManager = self.webKitManager {
                guard let signinURL = account.signinURL else {
                    throw SessionSwitchError.identityNotApplied(expectedBrandId: account.brandId)
                }
                try await webKitManager.switchSessionIdentity(
                    to: signinURL,
                    expectedBrandId: account.brandId
                )
            }

            // Update local state
            self.currentAccount = account

            // Reset client session state to avoid leaking continuations across accounts
            self.ytMusicClient.resetSessionStateForAccountSwitch()
            SongLikeStatusManager.shared.setActiveAccountID(account.id)

            let brandLabel = account.brandId ?? "primary"
            self.logger.info("AccountService: Active account brandId=\(brandLabel)")

            // Persist selection
            UserDefaults.standard.set(account.id, forKey: self.selectedBrandIdKey)
            self.logger.debug("AccountService: Saved brand ID: \(account.id)")

            self.logger.info("AccountService: Successfully switched to account: \(account.name)")
        } catch {
            self.logger.error("AccountService: Failed to switch account: \(error.localizedDescription)")
            self.currentAccount = previousAccount
            SongLikeStatusManager.shared.setActiveAccountID(previousAccount?.id)
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
        SongLikeStatusManager.shared.clearCache()
        SongLikeStatusManager.shared.setActiveAccountID(nil)

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
