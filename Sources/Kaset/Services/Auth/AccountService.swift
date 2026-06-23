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

    /// The account whose playback session identity has been *verified* (the
    /// WebView's `ytcfg.DATASYNC_ID` confirmed to match). Distinct from
    /// `currentAccount`, which is set the moment a switch is committed: on cold
    /// launch the restored brand is `currentAccount` while its session pin is
    /// still in flight. Observe `verifiedIdentitySequence` to drive work that
    /// must run under the confirmed playback identity (e.g. re-pointing the
    /// in-flight track/video) rather than under an unverified one.
    private(set) var verifiedAccountId: String?

    /// Bumped each time a session identity is verified (manual switch or launch
    /// restore). A monotonically increasing trigger for `verifiedAccountId`.
    private(set) var verifiedIdentitySequence: Int = 0

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

    /// Single-flight handle for all WebView session-identity mutations (launch
    /// restore pin and the awaited switch). Routing every session pin through one
    /// handle lets a new switch cancel+await an in-flight one, so concurrent pins
    /// against the shared cookie store cannot leave the session on a stale
    /// identity. Replaced on each `fetchAccounts`/`switchAccount`.
    private var sessionPinTask: Task<Void, Never>?

    /// The in-flight manual-switch navigation, tracked separately so a newer
    /// switch (or logout) can CANCEL it — not merely gate its commit. Without
    /// this, two quick switches would run two concurrent `/signin` navigations
    /// and whichever landed last would win the shared cookie store.
    private var activeSwitchNavigation: Task<Void, Error>?

    /// Monotonic generation for account-switch operations. A switch captures the
    /// value at entry and re-checks it before committing; if a newer switch (or a
    /// fetch-scheduled restore pin) has started in the meantime, the older one
    /// aborts without committing or persisting, so two overlapping switches can
    /// never leave `currentAccount`/`verifiedAccountId` disagreeing with the
    /// last-launched navigation against the shared cookie store.
    private var switchGeneration: Int = 0

    private func markIdentityVerified(_ accountId: String?) {
        self.verifiedAccountId = accountId
        self.verifiedIdentitySequence &+= 1
    }

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
            var restoredBrandVanished = false
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
                    // The shared WebKit session may still be delegated to the now-
                    // removed brand; if we fell back to primary, the session must be
                    // re-pinned to primary rather than left brand-delegated.
                    restoredBrandVanished = (savedBrandId != "primary")
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
            self.scheduleRestoredSessionPin(forcePrimaryRepin: restoredBrandVanished)
        } catch {
            self.logger.error("AccountService: Failed to fetch accounts: \(error.localizedDescription)")
            self.lastError = error
            self.lastErrorWasFetch = true
            self.errorSequence += 1
        }
    }

    /// Schedules a best-effort WebView session pin for the restored account, off
    /// the `fetchAccounts` path so it never blocks launch or holds `isLoading`.
    ///
    /// Normally a no-op for the primary account (the default session identity).
    /// When `forcePrimaryRepin` is true — i.e. a saved brand vanished and we fell
    /// back to primary — the shared session may still be delegated to the removed
    /// brand, so primary is explicitly re-pinned (verified with `expectedBrandId:
    /// nil`) provided it exposes a `signinURL`. No-op when no WebKit manager is
    /// injected. On success it bumps `verifiedIdentitySequence`. Failures logged.
    private func scheduleRestoredSessionPin(forcePrimaryRepin: Bool = false) {
        // Cancel any in-flight pin FIRST, before the guard: a later fetch that
        // resolves to primary / a brand without a signinURL / a removed account
        // must not leave an older brand pin running, or it could still verify and
        // bump `verifiedIdentitySequence` for an account the app no longer
        // considers active (e.g. after logout/re-auth or an account-list refresh).
        self.sessionPinTask?.cancel()
        self.sessionPinTask = nil
        // NOTE: do NOT bump switchGeneration here. A passive fetch/launch restore
        // must not supersede an in-flight *manual* switch: doing so would make the
        // switch abandon its commit (and skip rollback) after its /signin already
        // mutated the shared cookies, leaving the session on the attempted account
        // while currentAccount reflects the fetch — a split-brain. A manual switch
        // intentionally wins over a passive fetch; the fetch only cancels a prior
        // (also-passive) pin via the cancel above.

        guard !UITestConfig.isUITestMode,
              let webKitManager = self.webKitManager,
              let account = self.currentAccount,
              let signinURL = account.signinURL
        else {
            return
        }
        // Pin a brand always; pin primary only on the brand-vanished fallback
        // (otherwise a normal primary launch needn't touch the session).
        guard account.brandId != nil || forcePrimaryRepin else {
            return
        }
        let expectedBrandId = account.brandId

        self.sessionPinTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                try await webKitManager.switchSessionIdentity(to: signinURL, expectedBrandId: expectedBrandId)
                guard let self, !Task.isCancelled else { return }
                self.logger.info("AccountService: Restored session identity for \(account.name)")
                self.markIdentityVerified(account.id)
            } catch is CancellationError {
                // Superseded by a newer switch; the survivor owns the session.
            } catch {
                self?.logger.error("AccountService: Could not restore session identity: \(error.localizedDescription)")
            }
        }
    }

    /// Awaits the in-flight session pin (launch restore or switch), if any.
    /// Test hook.
    func awaitRestoredBrandSessionPinForTesting() async {
        await self.sessionPinTask?.value
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

        // Claim this switch's generation FIRST, before any await. A prior switch
        // suspended on its navigation will then observe the bumped generation when
        // it resumes and abandon its commit, rather than racing to commit a stale
        // account. Synchronous sections are atomic on the main actor; only the
        // awaits below can interleave.
        self.switchGeneration &+= 1
        let myGeneration = self.switchGeneration

        // Now cancel and await any in-flight session mutation (a cold-launch brand
        // restore pin AND/OR a prior manual switch's navigation) so neither can
        // land AFTER this switch and re-point the shared cookie session to a stale
        // identity. `switchSessionIdentity` is cooperatively cancellable, so this
        // returns promptly. (Generation already bumped, so the awaited prior
        // switch is guaranteed to abandon its own commit.)
        self.sessionPinTask?.cancel()
        await self.sessionPinTask?.value
        self.sessionPinTask = nil
        let priorNavigation = self.activeSwitchNavigation
        self.activeSwitchNavigation = nil
        priorNavigation?.cancel()
        _ = try? await priorNavigation?.value

        // Tracks whether the session-mutating navigation was actually started, so
        // the catch only rolls the session back when there is something to undo.
        var didStartSessionSwitch = false

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
                didStartSessionSwitch = true
                // Run the navigation as a cancellable tracked task so a newer
                // switch (or logout) cancels THIS navigation, not just gates its
                // commit. Otherwise two quick switches would run two concurrent
                // /signin WebViews and whichever landed last would win the shared
                // cookie store even though commits are generation-gated.
                let navigation = Task { @MainActor in
                    try await webKitManager.switchSessionIdentity(
                        to: signinURL,
                        expectedBrandId: account.brandId
                    )
                }
                self.activeSwitchNavigation = navigation
                // Only clear the handle if it is still OURS: a newer switch may
                // have replaced it while we were suspended, and clearing it then
                // would make the newer navigation uncancellable. (`Task` conforms
                // to `Equatable`/`Hashable` by identity, so `==` compares handles.)
                defer {
                    if self.activeSwitchNavigation == navigation {
                        self.activeSwitchNavigation = nil
                    }
                }
                try await navigation.value
            }

            // If a newer switch/pin superseded this one while we were navigating,
            // abort: the newer operation owns the session and the committed state.
            // Do NOT roll back the session here — the survivor is mid-flight and
            // will establish the correct identity.
            guard myGeneration == self.switchGeneration else {
                self.logger.info("AccountService: Switch to \(account.name) superseded; abandoning commit")
                self.isLoading = false
                return
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

            // The session identity is now verified for this account; signal
            // observers (e.g. MainWindow) to re-point in-flight playback.
            self.markIdentityVerified(account.id)

            self.logger.info("AccountService: Successfully switched to account: \(account.name)")
        } catch {
            self.logger.error("AccountService: Failed to switch account: \(error.localizedDescription)")

            // If a newer switch/pin superseded this one, do not touch shared state
            // on the failure path either — the survivor owns currentAccount and the
            // session. Surface nothing; the newer operation drives the outcome.
            guard myGeneration == self.switchGeneration else {
                self.logger.info("AccountService: Failed switch to \(account.name) was superseded; not reverting")
                throw error
            }

            self.currentAccount = previousAccount
            SongLikeStatusManager.shared.setActiveAccountID(previousAccount?.id)

            // If the /signin navigation already mutated the shared cookie session
            // before verification failed, the session may be left on the attempted
            // identity while native state says `previousAccount`. Best-effort
            // re-pin the previous identity so playback records to the account the
            // app believes is active. Skipped for throws that occurred before the
            // navigation (UI-test mock, missing signinURL).
            if didStartSessionSwitch,
               !UITestConfig.isUITestMode,
               let webKitManager = self.webKitManager,
               let previous = previousAccount,
               let previousSigninURL = previous.signinURL
            {
                do {
                    try await webKitManager.switchSessionIdentity(
                        to: previousSigninURL,
                        expectedBrandId: previous.brandId
                    )
                    // Only claim the verified identity if nothing superseded us
                    // during the rollback navigation.
                    if myGeneration == self.switchGeneration {
                        self.markIdentityVerified(previous.id)
                    }
                } catch {
                    self.logger.error("AccountService: Session rollback failed; session may remain on attempted identity: \(error.localizedDescription)")
                }
            }

            self.lastError = error
            self.lastErrorWasFetch = false
            self.errorSequence += 1

            // The cached signinURL may be single-use/expired (see ADR-0023). If
            // the switch actually attempted a navigation, refresh the account list
            // in the background so a retry uses a fresh signinURL instead of
            // reusing the stale one. Best-effort; does not affect the thrown error.
            if didStartSessionSwitch {
                Task { [weak self] in await self?.refreshAccountsAfterSwitchFailure() }
            }

            throw error
        }
    }

    /// Re-fetches the account list after a failed switch so a retry has fresh
    /// signin URLs. Guarded so it does not run while another operation is active.
    private func refreshAccountsAfterSwitchFailure() async {
        guard !self.isLoading else { return }
        await self.fetchAccounts()
    }

    /// Clears all account data.
    ///
    /// Should be called when the user logs out to reset state.
    func clearAccounts() {
        self.logger.info("AccountService: Clearing accounts data")

        // Invalidate any in-flight session mutation: cancel the pin and the
        // active switch navigation, and bump the generation so a switch currently
        // awaiting verification abandons its commit instead of repopulating
        // currentAccount/UserDefaults and leaving the (now-cleared) WebKit session
        // re-pinned to the old account.
        self.sessionPinTask?.cancel()
        self.sessionPinTask = nil
        self.activeSwitchNavigation?.cancel()
        self.activeSwitchNavigation = nil
        self.switchGeneration &+= 1

        self.accounts = []
        self.currentAccount = nil
        self.verifiedAccountId = nil
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
