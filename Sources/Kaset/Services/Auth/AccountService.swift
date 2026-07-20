// AccountService.swift
// Kaset
//
// Manages account state and brand account switching.

// swiftlint:disable file_length

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
final class AccountService { // swiftlint:disable:this type_body_length
    private struct FavoritesOwnerFinalization: Codable, Hashable {
        let sourceOwnerID: String
        let targetOwnerID: String
        let accountIDs: [String]

        init(sourceOwnerID: String, targetOwnerID: String, accountIDs: some Sequence<String>) {
            self.sourceOwnerID = sourceOwnerID
            self.targetOwnerID = targetOwnerID
            self.accountIDs = Array(Set(accountIDs)).sorted()
        }
    }

    private struct FavoritesOwnerState: Codable {
        var ownerIDsByAliasID: [String: String]
        var accountIDsByOwnerID: [String: [String]]
        var emailAliasIDs: [String]?
        var pendingFinalizations: [FavoritesOwnerFinalization]?
    }

    // MARK: - Dependencies

    private let ytMusicClient: any YTMusicClientProtocol
    private let authService: AuthService
    private let favoritesOwnerDefaults: UserDefaults?

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

    var currentFavoritesScopeID: String? {
        self.favoritesScopeID(for: self.currentAccount)
    }

    // MARK: - Private

    private let logger = DiagnosticsLogger.auth
    private let selectedBrandIdKey = "selectedBrandId"
    private static let favoritesOwnerStateKey = "favorites.ownerState"
    private var favoritesScopeByAccountID: [String: String] = [:]
    private var favoritesOwnerID: String?
    private var favoritesOwnerIDByAliasID: [String: String] = [:]
    private var favoritesAccountIDsByOwnerID: [String: Set<String>] = [:]
    private var favoritesEmailAliasIDs: Set<String> = []
    private var pendingFavoritesOwnerFinalizations: Set<FavoritesOwnerFinalization> = []
    /// Owner corroborated by an email alias in the current auth generation.
    private var verifiedFavoritesOwnerID: String?
    private var observedAuthIdentityGeneration: UInt64 = 0

    /// Single-flight handle for all WebView session-identity mutations (launch
    /// restore pin and the awaited switch). Routing every session pin through one
    /// handle lets a new switch cancel+await an in-flight one, so concurrent pins
    /// against the shared cookie store cannot leave the session on a stale
    /// identity. Replaced on each `fetchAccounts`/`switchAccount`.
    private var sessionPinTask: Task<Void, Never>?
    private var sessionPinGeneration = 0
    /// Awaitable barrier for cancelled WebKit session mutations from a prior auth identity.
    private var sessionMutationDrainTask: Task<Void, Never>?
    /// Set before sign-out or reauthentication starts so no new WebKit identity
    /// mutation can begin until the next personal authentication is established.
    private var isAuthenticationBoundaryInProgress = false

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

    /// Number of user-initiated account switches currently owning (or waiting to
    /// own) the shared WebKit session. Passive account-list refreshes must not
    /// start restore pins while this is non-zero, or they can race a switch and
    /// re-point cookies to a stale account. A count, rather than a Bool, is used
    /// because `switchAccount` is reentrant on the main actor and superseded
    /// switches can finish after a newer switch has already started.
    private var manualSwitchInFlightCount = 0
    private var needsAccountFetchAfterManualSwitch = false

    /// The authentication generation whose successful account list populated `accounts`.
    private var accountsAuthIdentityGeneration: UInt64?

    /// Bumped when account data/session mutations are invalidated (notably sign-out)
    /// so an older `fetchAccounts()` continuation cannot commit stale accounts or
    /// start a fresh session pin after cookies are being cleared.
    private var accountDataGeneration = 0

    private func markIdentityVerified(_ accountId: String?) {
        self.verifiedAccountId = accountId
        self.verifiedIdentitySequence &+= 1
    }

    private func updateFavoritesScopes(from response: AccountsListResponse) {
        guard let ownerID = self.resolveFavoritesOwnerID(from: response) else {
            self.favoritesScopeByAccountID = [:]
            return
        }

        var scopes: [String: String] = [:]
        for account in response.accounts {
            scopes[account.id] = FavoritesManager.accountScopeID(
                ownerID: ownerID,
                accountID: account.id
            )
        }
        self.favoritesScopeByAccountID = scopes
        for account in response.accounts {
            if let scopeID = scopes[account.id] {
                FavoritesManager.shared.recoverLegacyAccountFavorites(
                    accountID: account.id,
                    toScopeID: scopeID
                )
            }
        }
    }

    private func resolveFavoritesOwnerID(from response: AccountsListResponse) -> String? {
        self.resumePendingFavoritesOwnerFinalizations()
        guard let authFingerprintID = Self.favoritesAuthFingerprintID(from: self.authService.state) else {
            return nil
        }
        let emailAliasID = Self.favoritesEmailAliasID(from: response.googleEmail)
        let authBoundOwnerID = self.favoritesOwnerIDByAliasID[authFingerprintID]
        let emailOwnerID = emailAliasID.flatMap { self.favoritesOwnerIDByAliasID[$0] }
        guard let ownerID = self.selectFavoritesOwnerID(
            authBoundOwnerID: authBoundOwnerID,
            emailOwnerID: emailOwnerID
        ) else {
            return nil
        }

        let currentAccountIDs = Set(response.accounts.map(\.id))
            .union(self.favoritesScopeByAccountID.keys)
        let sourceOwnerIDs = Set([self.favoritesOwnerID, authBoundOwnerID].compactMap(\.self))
            .subtracting([ownerID])

        let observedOwnerIDs = sourceOwnerIDs.isEmpty ? [ownerID] : Array(sourceOwnerIDs)
        for observedOwnerID in observedOwnerIDs {
            self.favoritesAccountIDsByOwnerID[observedOwnerID, default: []]
                .formUnion(currentAccountIDs)
        }
        guard self.persistFavoritesOwnerIdentity() else { return nil }

        var migrationAccountIDsBySource: [String: Set<String>] = [:]
        for sourceOwnerID in sourceOwnerIDs.sorted() {
            let migrationAccountIDs = self.favoritesAccountIDsByOwnerID[sourceOwnerID, default: []]
                .union(currentAccountIDs)
            migrationAccountIDsBySource[sourceOwnerID] = migrationAccountIDs
            guard FavoritesManager.shared.prepareAccountScopeMerge(
                fromOwnerID: sourceOwnerID,
                intoOwnerID: ownerID,
                accountIDs: Array(migrationAccountIDs)
            ) else {
                return self.activatableFavoritesOwnerID(sourceOwnerID)
            }
            guard FavoritesManager.shared.commitAccountScopeMerge(
                fromOwnerID: sourceOwnerID,
                intoOwnerID: ownerID,
                accountIDs: Array(migrationAccountIDs)
            ) else {
                return self.activatableFavoritesOwnerID(sourceOwnerID)
            }
        }

        let ownerFinalizations = sourceOwnerIDs.sorted().map { sourceOwnerID in
            FavoritesOwnerFinalization(
                sourceOwnerID: sourceOwnerID,
                targetOwnerID: ownerID,
                accountIDs: migrationAccountIDsBySource[sourceOwnerID] ?? currentAccountIDs
            )
        }
        self.pendingFavoritesOwnerFinalizations.formUnion(ownerFinalizations)

        for sourceOwnerID in sourceOwnerIDs {
            for (aliasID, mappedOwnerID) in self.favoritesOwnerIDByAliasID
                where mappedOwnerID == sourceOwnerID
            {
                self.favoritesOwnerIDByAliasID[aliasID] = ownerID
            }
            self.favoritesAccountIDsByOwnerID[ownerID, default: []]
                .formUnion(self.favoritesAccountIDsByOwnerID.removeValue(forKey: sourceOwnerID) ?? [])
        }
        self.bindFavoritesOwnerAliases(
            ownerID: ownerID,
            authFingerprintID: authFingerprintID,
            emailAliasID: emailAliasID,
            emailOwnerID: emailOwnerID
        )
        if let emailAliasID {
            if self.favoritesOwnerIDByAliasID[emailAliasID] == ownerID {
                self.verifiedFavoritesOwnerID = ownerID
            } else {
                self.verifiedFavoritesOwnerID = nil
            }
        }
        self.favoritesAccountIDsByOwnerID[ownerID, default: []].formUnion(currentAccountIDs)
        guard self.persistFavoritesOwnerIdentity() else { return nil }

        for finalization in ownerFinalizations where self.finalizeFavoritesOwnerMigration(finalization) {
            self.pendingFavoritesOwnerFinalizations.remove(finalization)
        }
        _ = self.persistFavoritesOwnerIdentity()
        // A persisted credential alias is not sufficient after a new auth
        // generation because Google can reuse one SAPISID across multi-login
        // identities. Require current-generation email corroboration first;
        // later partial responses in that same generation may omit email.
        guard self.verifiedFavoritesOwnerID == ownerID else { return nil }
        return self.activatableFavoritesOwnerID(ownerID)
    }

    private func selectFavoritesOwnerID(
        authBoundOwnerID: String?,
        emailOwnerID: String?
    ) -> String? {
        let authBoundOwnerHasEmail = authBoundOwnerID.map(self.favoritesOwnerHasEmailAlias) ?? false
        if let authBoundOwnerID,
           let emailOwnerID,
           emailOwnerID != authBoundOwnerID
        {
            guard !authBoundOwnerHasEmail else {
                self.logger.warning("AccountService: Conflicting durable favorites identities; leaving scope unresolved")
                self.verifiedFavoritesOwnerID = nil
                return nil
            }
            return emailOwnerID
        }
        return authBoundOwnerID
            ?? emailOwnerID
            ?? self.favoritesOwnerID
            ?? UUID().uuidString.lowercased()
    }

    private func bindFavoritesOwnerAliases(
        ownerID: String,
        authFingerprintID: String,
        emailAliasID: String?,
        emailOwnerID: String?
    ) {
        self.favoritesOwnerID = ownerID
        self.favoritesOwnerIDByAliasID[authFingerprintID] = ownerID
        guard let emailAliasID else { return }

        let ownerEmailAliasIDs = self.favoritesEmailAliasIDs.filter {
            self.favoritesOwnerIDByAliasID[$0] == ownerID
        }
        // A shared browser credential can participate in Google multi-login, so
        // an unclaimed changed email is not proof that the address belongs to this
        // owner. Keep the current scope for this response, but do not persist the
        // changed alias unless it was already known or this owner has no email yet.
        if emailOwnerID == ownerID || (emailOwnerID == nil && ownerEmailAliasIDs.isEmpty) {
            self.favoritesOwnerIDByAliasID[emailAliasID] = ownerID
            self.favoritesEmailAliasIDs.insert(emailAliasID)
        } else {
            self.logger.warning("AccountService: Ignoring conflicting favorites email fingerprint")
        }
    }

    private func activatableFavoritesOwnerID(_ ownerID: String) -> String? {
        self.favoritesOwnerHasEmailAlias(ownerID) ? ownerID : nil
    }

    private func favoritesOwnerHasEmailAlias(_ ownerID: String) -> Bool {
        self.favoritesEmailAliasIDs.contains { aliasID in
            self.favoritesOwnerIDByAliasID[aliasID] == ownerID
        }
    }

    private static func favoritesAuthFingerprintID(from state: AuthService.State) -> String? {
        guard case let .loggedIn(sapisid) = state else { return nil }
        return FavoritesManager.opaqueIdentityID(for: "credential\u{1F}\(sapisid)")
    }

    private static func favoritesEmailAliasID(from googleEmail: String?) -> String? {
        guard let googleEmail = googleEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !googleEmail.isEmpty
        else {
            return nil
        }
        return FavoritesManager.identityID(for: "email\u{1F}\(googleEmail)")
    }

    private func restoreFavoritesOwnerIdentity() {
        guard let favoritesOwnerDefaults = self.favoritesOwnerDefaults else { return }

        let backupData = FavoritesManager.shared.loadOwnerStateBackup()
        let defaultsData = favoritesOwnerDefaults.data(forKey: Self.favoritesOwnerStateKey)
        let restored = [backupData, defaultsData].compactMap { data -> (Data, FavoritesOwnerState)? in
            guard let data,
                  let state = try? JSONDecoder().decode(FavoritesOwnerState.self, from: data)
            else { return nil }
            return (data, state)
        }.first
        guard let (data, state) = restored else { return }

        self.favoritesOwnerIDByAliasID = state.ownerIDsByAliasID
        self.favoritesAccountIDsByOwnerID = state.accountIDsByOwnerID.mapValues(Set.init)
        self.favoritesEmailAliasIDs = Set(state.emailAliasIDs ?? [])
        self.pendingFavoritesOwnerFinalizations = Set(state.pendingFinalizations ?? [])

        // Heal either redundant copy when the other one was missing or corrupt.
        _ = FavoritesManager.shared.saveOwnerStateBackup(data)
        favoritesOwnerDefaults.set(data, forKey: Self.favoritesOwnerStateKey)
    }

    @discardableResult
    private func persistFavoritesOwnerIdentity() -> Bool {
        guard let favoritesOwnerDefaults = self.favoritesOwnerDefaults else { return true }
        let state = FavoritesOwnerState(
            ownerIDsByAliasID: self.favoritesOwnerIDByAliasID,
            accountIDsByOwnerID: self.favoritesAccountIDsByOwnerID.mapValues { $0.sorted() },
            emailAliasIDs: self.favoritesEmailAliasIDs.sorted(),
            pendingFinalizations: self.pendingFavoritesOwnerFinalizations.sorted { lhs, rhs in
                if lhs.sourceOwnerID != rhs.sourceOwnerID {
                    return lhs.sourceOwnerID < rhs.sourceOwnerID
                }
                return lhs.targetOwnerID < rhs.targetOwnerID
            }
        )
        guard let data = try? JSONEncoder().encode(state),
              FavoritesManager.shared.saveOwnerStateBackup(data)
        else { return false }
        favoritesOwnerDefaults.set(data, forKey: Self.favoritesOwnerStateKey)
        return true
    }

    private func finalizeFavoritesOwnerMigration(_ finalization: FavoritesOwnerFinalization) -> Bool {
        FavoritesManager.shared.finalizeAccountScopeMerge(
            fromOwnerID: finalization.sourceOwnerID,
            intoOwnerID: finalization.targetOwnerID,
            accountIDs: finalization.accountIDs
        )
    }

    private func resumePendingFavoritesOwnerFinalizations() {
        guard !self.pendingFavoritesOwnerFinalizations.isEmpty else { return }

        var didChange = false
        for finalization in Array(self.pendingFavoritesOwnerFinalizations)
            where self.finalizeFavoritesOwnerMigration(finalization)
        {
            self.pendingFavoritesOwnerFinalizations.remove(finalization)
            didChange = true
        }
        if didChange {
            _ = self.persistFavoritesOwnerIdentity()
        }
    }

    private func clearActiveFavoritesOwnerIdentity() {
        self.favoritesOwnerID = nil
    }

    private func resetFavoritesOwnerIfAuthenticationBoundaryChanged() {
        guard self.observedAuthIdentityGeneration != self.authService.accountIdentityGeneration else { return }
        self.observedAuthIdentityGeneration = self.authService.accountIdentityGeneration
        self.accountDataGeneration &+= 1
        self.sessionPinGeneration &+= 1
        self.switchGeneration &+= 1
        let pinTask = self.sessionPinTask
        let navigationTask = self.activeSwitchNavigation
        let priorDrainTask = self.sessionMutationDrainTask
        pinTask?.cancel()
        navigationTask?.cancel()
        self.sessionPinTask = nil
        self.activeSwitchNavigation = nil
        if priorDrainTask != nil || pinTask != nil || navigationTask != nil {
            self.sessionMutationDrainTask = Task { @MainActor in
                await priorDrainTask?.value
                await pinTask?.value
                _ = try? await navigationTask?.value
            }
        }
        self.accountsAuthIdentityGeneration = nil
        self.accounts = []
        self.currentAccount = nil
        self.verifiedAccountId = nil
        SongLikeStatusManager.shared.invalidateSession()
        SongLikeStatusManager.shared.clearCache()
        SongLikeStatusManager.shared.setActiveAccountID(nil)
        self.favoritesScopeByAccountID = [:]
        self.verifiedFavoritesOwnerID = nil
        self.clearActiveFavoritesOwnerIdentity()
        FavoritesManager.shared.setActiveAccountScopeID(nil)
    }

    private func favoritesScopeID(for account: UserAccount?) -> String? {
        guard let account else { return nil }
        return self.favoritesScopeByAccountID[account.id]
    }

    private func runTrackedSessionSwitch(
        with webKitManager: any WebKitManagerProtocol,
        to signinURL: URL,
        expectedBrandId: String?
    ) async throws {
        let navigation = Task { @MainActor in
            try await webKitManager.switchSessionIdentity(
                to: signinURL,
                expectedBrandId: expectedBrandId
            )
        }
        self.activeSwitchNavigation = navigation
        // Only clear the handle if it is still OURS: a newer switch may have
        // replaced it while we were suspended, and clearing it then would make
        // the newer navigation uncancellable. (`Task` conforms to
        // `Equatable`/`Hashable` by identity, so `==` compares handles.)
        defer {
            if self.activeSwitchNavigation == navigation {
                self.activeSwitchNavigation = nil
            }
        }
        try await navigation.value
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
        webKitManager: (any WebKitManagerProtocol)? = nil,
        favoritesOwnerDefaults: UserDefaults? = nil
    ) {
        self.ytMusicClient = ytMusicClient
        self.authService = authService
        self.favoritesOwnerDefaults = favoritesOwnerDefaults
            ?? (UITestConfig.isUITestMode || UITestConfig.isRunningUnitTests ? nil : .standard)
        self.webKitManager = webKitManager
        self.observedAuthIdentityGeneration = authService.accountIdentityGeneration
        self.restoreFavoritesOwnerIdentity()
        self.resumePendingFavoritesOwnerFinalizations()
        authService.setSignOutPreparation { [weak self] in
            await self?.prepareForSignOut()
        }
    }

    // MARK: - Public Methods

    /// Fetches the list of available accounts from the API.
    ///
    /// This should be called after login to populate the accounts list.
    /// If a previously selected account ID is stored, that account will be
    /// automatically selected.
    func fetchAccounts() async {
        guard self.authService.hasPersonalAccount, !self.isAuthenticationBoundaryInProgress else {
            self.logger.debug("AccountService: Skipping fetch - no mutable personal session active")
            return
        }
        guard self.manualSwitchInFlightCount == 0 else {
            if self.accountsAuthIdentityGeneration != self.authService.accountIdentityGeneration {
                self.logger.info("AccountService: Deferring new-identity account fetch while a manual switch unwinds")
                self.needsAccountFetchAfterManualSwitch = true
            } else {
                self.logger.info("AccountService: Ignoring passive account fetch while a manual switch is in flight")
            }
            return
        }

        self.resetFavoritesOwnerIfAuthenticationBoundaryChanged()
        await self.awaitSessionMutationDrain()
        guard self.authService.hasPersonalAccount, !self.isAuthenticationBoundaryInProgress else {
            self.logger.debug("AccountService: Account fetch abandoned while draining prior session identity")
            return
        }
        self.logger.info("AccountService: Fetching accounts list")
        self.isLoading = true
        defer { self.isLoading = false }
        let fetchGeneration = self.accountDataGeneration
        let fetchAuthIdentityGeneration = self.authService.accountIdentityGeneration
        let fetchSwitchGeneration = self.switchGeneration

        do {
            let response = try await self.ytMusicClient.fetchAccountsList()
            guard fetchGeneration == self.accountDataGeneration,
                  fetchAuthIdentityGeneration == self.authService.accountIdentityGeneration,
                  fetchSwitchGeneration == self.switchGeneration,
                  self.manualSwitchInFlightCount == 0,
                  self.authService.hasPersonalAccount,
                  !self.isAuthenticationBoundaryInProgress
            else {
                self.logger.info("AccountService: Ignoring stale account fetch after auth/account state changed")
                return
            }

            if response.accounts.isEmpty {
                self.logger.warning("AccountService: 0 accounts returned, marking session as expired")
                self.authService.sessionExpired()
                return
            }

            self.updateFavoritesScopes(from: response)
            self.accounts = response.accounts
            self.accountsAuthIdentityGeneration = fetchAuthIdentityGeneration

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
            FavoritesManager.shared.setActiveAccountScopeID(
                self.favoritesScopeID(for: self.currentAccount),
                legacyAccountID: self.currentAccount?.id
            )

            let currentLabel = self.currentAccount?.brandId ?? "primary"
            self.logger.info("AccountService: Fetched \(self.accounts.count) accounts, current: \(self.currentAccount?.name ?? "none") (brandId=\(currentLabel))")

            // Re-establish the WebView session identity for the restored account.
            // Without this, a relaunch can leave native reads and playback history
            // attribution on different identities. Run it OFF the fetch path (after
            // isLoading clears) so a real ≤20s navigation never stalls launch or
            // holds the account spinner; it is best-effort and surfaced via logs.
            if self.verifiedAccountId != self.currentAccount?.id {
                self.scheduleRestoredSessionPin()
            }
        } catch {
            guard fetchGeneration == self.accountDataGeneration,
                  fetchAuthIdentityGeneration == self.authService.accountIdentityGeneration,
                  fetchSwitchGeneration == self.switchGeneration,
                  self.manualSwitchInFlightCount == 0,
                  self.authService.hasPersonalAccount,
                  !self.isAuthenticationBoundaryInProgress
            else {
                self.logger.info("AccountService: Ignoring stale account fetch error after auth/account state changed")
                return
            }
            self.logger.error("AccountService: Failed to fetch accounts: \(error.localizedDescription)")
            self.lastError = error
            self.lastErrorWasFetch = true
            self.errorSequence += 1
        }
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    /// Schedules a best-effort WebView session pin for the restored account, off
    /// the `fetchAccounts` path so it never blocks launch or holds `isLoading`.
    ///
    /// Pins any restored account that exposes a `signinURL`, including primary.
    /// Primary usually is the default identity, but the shared session can be left
    /// brand-delegated after a crash or failed rollback, so a primary restore must
    /// also verify/re-pin when the server supplies a switch URL. No-op when no
    /// WebKit manager/signin URL is injected. On success it bumps
    /// `verifiedIdentitySequence`. Failures logged.
    private func scheduleRestoredSessionPin() {
        guard !self.isAuthenticationBoundaryInProgress else { return }

        // Cancel any in-flight pin FIRST, before the guard: a later fetch that
        // resolves to primary / a brand without a signinURL / a removed account
        // must not leave an older brand pin running, or it could still verify and
        // bump `verifiedIdentitySequence` for an account the app no longer
        // considers active (e.g. after logout/re-auth or an account-list refresh).
        let priorPinTask = self.sessionPinTask
        let priorNavigation = self.activeSwitchNavigation
        let pinAuthIdentityGeneration = self.authService.accountIdentityGeneration
        priorPinTask?.cancel()
        self.sessionPinTask = nil
        // NOTE: do NOT bump switchGeneration here. A passive fetch/launch restore
        // must not supersede an in-flight *manual* switch: doing so would make the
        // switch abandon its commit (and skip rollback) after its /signin already
        // mutated the shared cookies, leaving the session on the attempted account
        // while currentAccount reflects the fetch — a split-brain. A manual switch
        // intentionally wins over a passive fetch; the fetch only cancels a prior
        // (also-passive) pin via the cancel above.
        guard self.manualSwitchInFlightCount == 0 else {
            self.logger.info("AccountService: Skipping restored session pin while a manual switch is in flight")
            self.sessionPinGeneration &+= 1
            return
        }
        if let priorNavigation {
            self.logger.info("AccountService: Cancelling previous restored session navigation before scheduling a new pin")
            priorNavigation.cancel()
            self.activeSwitchNavigation = nil
        }

        guard !UITestConfig.isUITestMode,
              let webKitManager = self.webKitManager,
              let account = self.currentAccount
        else {
            return
        }
        guard let signinURL = account.signinURL else {
            guard account.brandId != nil else {
                if self.verifiedAccountId != account.id {
                    self.markIdentityVerified(nil)
                }
                return
            }
            self.sessionPinGeneration &+= 1
            let pinGeneration = self.sessionPinGeneration
            let error = SessionSwitchError.identityNotApplied(expectedBrandId: account.brandId)
            self.sessionPinTask = Task { [weak self, priorPinTask, priorNavigation] in
                defer {
                    if let self, self.sessionPinGeneration == pinGeneration {
                        self.sessionPinTask = nil
                    }
                }
                await priorPinTask?.value
                _ = try? await priorNavigation?.value
                guard !Task.isCancelled,
                      let self,
                      self.sessionPinGeneration == pinGeneration,
                      pinAuthIdentityGeneration == self.authService.accountIdentityGeneration,
                      self.authService.hasPersonalAccount,
                      !self.isAuthenticationBoundaryInProgress
                else { return }
                await self.handleRestoredSessionPinFailure(
                    for: account,
                    error: error,
                    pinGeneration: pinGeneration,
                    authIdentityGeneration: pinAuthIdentityGeneration
                )
            }
            return
        }
        guard self.verifiedAccountId != account.id else {
            self.logger.debug("AccountService: Restored session identity already verified for \(account.name)")
            return
        }
        let expectedBrandId = account.brandId
        let accountId = account.id
        let switchGenerationAtPinStart = self.switchGeneration

        self.sessionPinGeneration &+= 1
        let pinGeneration = self.sessionPinGeneration

        self.sessionPinTask = Task { [weak self, priorPinTask, priorNavigation] in
            defer {
                if let self, self.sessionPinGeneration == pinGeneration {
                    self.sessionPinTask = nil
                }
            }
            await priorPinTask?.value
            _ = try? await priorNavigation?.value
            guard !Task.isCancelled,
                  let self,
                  pinAuthIdentityGeneration == self.authService.accountIdentityGeneration,
                  self.authService.hasPersonalAccount,
                  !self.isAuthenticationBoundaryInProgress
            else { return }
            do {
                try await webKitManager.switchSessionIdentity(to: signinURL, expectedBrandId: expectedBrandId)
                guard !Task.isCancelled else { return }
                guard self.sessionPinGeneration == pinGeneration,
                      pinAuthIdentityGeneration == self.authService.accountIdentityGeneration,
                      self.authService.hasPersonalAccount,
                      !self.isAuthenticationBoundaryInProgress,
                      self.currentAccount?.id == accountId,
                      self.switchGeneration == switchGenerationAtPinStart,
                      self.activeSwitchNavigation == nil
                else {
                    self.logger.info("AccountService: Restored session identity for \(account.name) was superseded; not marking verified")
                    return
                }
                self.logger.info("AccountService: Restored session identity for \(account.name)")
                self.markIdentityVerified(account.id)
            } catch is CancellationError {
                // Superseded by a newer switch; the survivor owns the session.
            } catch {
                guard !Task.isCancelled,
                      self.sessionPinGeneration == pinGeneration,
                      pinAuthIdentityGeneration == self.authService.accountIdentityGeneration,
                      self.authService.hasPersonalAccount
                else { return }
                await self.handleRestoredSessionPinFailure(
                    for: account,
                    error: error,
                    pinGeneration: pinGeneration,
                    authIdentityGeneration: pinAuthIdentityGeneration
                )
            }
        }
    }

    // swiftlint:enable cyclomatic_complexity function_body_length

    private func handleRestoredSessionPinFailure(
        for account: UserAccount,
        error: Error,
        pinGeneration: Int,
        authIdentityGeneration: UInt64
    ) async {
        guard pinGeneration == self.sessionPinGeneration,
              authIdentityGeneration == self.authService.accountIdentityGeneration,
              self.authService.hasPersonalAccount,
              self.currentAccount?.id == account.id
        else { return }
        self.logger.error("AccountService: Could not restore session identity: \(error.localizedDescription)")
        self.lastError = error
        self.lastErrorWasFetch = false
        self.errorSequence += 1
        guard account.brandId != nil else { return }

        let fallback = self.accounts.first(where: { $0.isPrimary }) ?? self.accounts.first
        guard let fallback, fallback.id != account.id
        else { return }

        var didVerifyFallback = false
        if let webKitManager = self.webKitManager, let fallbackSigninURL = fallback.signinURL {
            do {
                try await self.runTrackedSessionSwitch(
                    with: webKitManager,
                    to: fallbackSigninURL,
                    expectedBrandId: fallback.brandId
                )
                didVerifyFallback = true
            } catch {
                self.logger.error("AccountService: Could not restore fallback session identity: \(error.localizedDescription)")
            }
        }
        guard self.sessionPinGeneration == pinGeneration,
              authIdentityGeneration == self.authService.accountIdentityGeneration,
              self.authService.hasPersonalAccount
        else { return }

        self.ytMusicClient.resetSessionStateForAccountSwitch()
        self.currentAccount = fallback
        SongLikeStatusManager.shared.setActiveAccountID(fallback.id)
        FavoritesManager.shared.setActiveAccountScopeID(
            self.favoritesScopeID(for: fallback),
            legacyAccountID: fallback.id
        )
        UserDefaults.standard.set(fallback.id, forKey: self.selectedBrandIdKey)
        self.markIdentityVerified(didVerifyFallback ? fallback.id : nil)
    }

    /// Awaits the in-flight session pin (launch restore or switch), if any.
    /// Test hook.
    func awaitRestoredSessionPinForTesting() async {
        await self.sessionPinTask?.value
    }

    private func awaitSessionMutationDrain() async {
        while let drainTask = self.sessionMutationDrainTask {
            await drainTask.value
            if self.sessionMutationDrainTask == drainTask {
                self.sessionMutationDrainTask = nil
            }
        }
    }

    /// Invalidates account work immediately after AuthService advances its identity generation.
    func authenticationIdentityDidChange() {
        self.resetFavoritesOwnerIfAuthenticationBoundaryChanged()
        if self.authService.hasPersonalAccount {
            self.isAuthenticationBoundaryInProgress = false
        }
    }

    /// Drains old WebView session-identity mutations before reauthentication clears
    /// or samples cookies. The expired auth state already prevents new mutations.
    func prepareForReauthentication() async {
        self.isAuthenticationBoundaryInProgress = true
        self.resetFavoritesOwnerIfAuthenticationBoundaryChanged()
        await self.invalidateAndDrainSessionMutations()
    }

    /// Cancels and awaits any WebView session-identity mutation before the caller
    /// clears cookies/data. This prevents an in-flight hidden `/signin` navigation
    /// from writing cookies back into the shared data store after sign-out cleanup.
    func prepareForSignOut() async {
        // Set the fence before the first suspension. AuthService is still logged in
        // until this method returns, so its state alone cannot reject new work.
        self.isAuthenticationBoundaryInProgress = true
        await self.invalidateAndDrainSessionMutations()
    }

    private func invalidateAndDrainSessionMutations() async {
        self.accountDataGeneration &+= 1
        self.sessionPinGeneration &+= 1
        self.switchGeneration &+= 1

        let pinTask = self.sessionPinTask
        let navigationTask = self.activeSwitchNavigation
        self.sessionPinTask = nil
        self.activeSwitchNavigation = nil

        pinTask?.cancel()
        navigationTask?.cancel()

        await self.awaitSessionMutationDrain()
        await pinTask?.value
        _ = try? await navigationTask?.value
        await self.awaitSessionMutationDrain()
    }

    // swiftlint:disable function_body_length cyclomatic_complexity
    /// Switches to a different account.
    ///
    /// - Parameter account: The account to switch to.
    /// - Throws: An error if the switch fails.
    func switchAccount(to account: UserAccount) async throws {
        let shouldExitGuestModeOnSuccess = self.authService.isGuestModeEnabled
        guard self.authService.state.isLoggedIn, !self.isAuthenticationBoundaryInProgress else {
            self.logger.info("AccountService: Rejecting account switch while authentication is unavailable")
            throw CancellationError()
        }
        let switchAuthIdentityGeneration = self.authService.accountIdentityGeneration
        guard self.accountsAuthIdentityGeneration == switchAuthIdentityGeneration else {
            self.logger.info("AccountService: Rejecting account switch from stale account data")
            throw CancellationError()
        }
        guard var account = self.accounts.first(where: { $0.id == account.id }) else {
            self.logger.info("AccountService: Rejecting account switch to an account outside the current snapshot")
            throw CancellationError()
        }
        let isSameAccount = account.id == self.currentAccount?.id
        let hadInFlightSessionMutation = self.sessionPinTask != nil || self.activeSwitchNavigation != nil
        if isSameAccount, hadInFlightSessionMutation {
            self.logger.info("AccountService: Cancelling pending session mutation for same-account no-op")
            self.switchGeneration &+= 1
            let cancelGeneration = self.switchGeneration
            let pinTask = self.sessionPinTask
            let navigationTask = self.activeSwitchNavigation
            if pinTask != nil {
                self.sessionPinGeneration &+= 1
            }
            self.sessionPinTask = nil
            self.activeSwitchNavigation = nil
            pinTask?.cancel()
            navigationTask?.cancel()
            await pinTask?.value
            _ = try? await navigationTask?.value
            guard cancelGeneration == self.switchGeneration,
                  switchAuthIdentityGeneration == self.authService.accountIdentityGeneration,
                  self.currentAccount?.id == account.id
            else { throw CancellationError() }

            if account.signinURL == nil,
               let refreshedAccount = await self.refreshAccountForRollback(matching: account)
            {
                account = refreshedAccount
            }
            guard cancelGeneration == self.switchGeneration,
                  switchAuthIdentityGeneration == self.authService.accountIdentityGeneration,
                  self.currentAccount?.id == account.id
            else { throw CancellationError() }
            guard account.signinURL != nil else {
                self.completeGuestModeAccountSelectionIfNeeded(
                    shouldExitGuestModeOnSuccess,
                    accountID: account.id
                )
                return
            }
            self.markIdentityVerified(nil)
        }
        guard !isSameAccount || (account.signinURL != nil && self.verifiedAccountId != account.id && self.webKitManager != nil) else {
            self.logger.debug("AccountService: Already using account \(account.name)")
            self.completeGuestModeAccountSelectionIfNeeded(
                shouldExitGuestModeOnSuccess,
                accountID: account.id
            )
            return
        }
        if isSameAccount {
            self.logger.info("AccountService: Retrying unverified session identity for account: \(account.name)")
        }

        let previousAccount = self.currentAccount
        var rollbackAccount = previousAccount
        self.logger.info("AccountService: Switching to account: \(account.name)")
        self.isLoading = true
        defer { self.isLoading = false }
        self.manualSwitchInFlightCount += 1
        defer {
            self.manualSwitchInFlightCount -= 1
            if self.manualSwitchInFlightCount == 0,
               self.needsAccountFetchAfterManualSwitch
            {
                self.needsAccountFetchAfterManualSwitch = false
                Task { [weak self] in
                    await self?.fetchAccounts()
                }
            }
        }

        // Claim this switch's generation FIRST, before any await. A prior switch
        // suspended on its navigation will then observe the bumped generation when
        // it resumes and abandon its commit, rather than racing to commit a stale
        // account. Synchronous sections are atomic on the main actor; only the
        // awaits below can interleave.
        self.switchGeneration &+= 1
        let myGeneration = self.switchGeneration
        let myAccountDataGeneration = self.accountDataGeneration
        var cancelledPriorSessionMutation = false

        // Now cancel and await any in-flight session mutation (a cold-launch brand
        // restore pin AND/OR a prior manual switch's navigation) so neither can
        // land AFTER this switch and re-point the shared cookie session to a stale
        // identity. `switchSessionIdentity` is cooperatively cancellable, so this
        // returns promptly. (Generation already bumped, so the awaited prior
        // switch is guaranteed to abandon its own commit.)
        if self.sessionPinTask != nil || self.activeSwitchNavigation != nil {
            cancelledPriorSessionMutation = true
        }
        let priorPinTask = self.sessionPinTask
        let priorNavigation = self.activeSwitchNavigation
        if priorPinTask != nil {
            self.sessionPinGeneration &+= 1
        }
        priorPinTask?.cancel()
        priorNavigation?.cancel()
        await priorPinTask?.value
        self.sessionPinTask = nil
        guard myGeneration == self.switchGeneration,
              myAccountDataGeneration == self.accountDataGeneration,
              switchAuthIdentityGeneration == self.authService.accountIdentityGeneration
        else {
            self.logger.info("AccountService: Switch to \(account.name) superseded before navigation; abandoning")
            throw CancellationError()
        }
        _ = try? await priorNavigation?.value
        if let priorNavigation, self.activeSwitchNavigation == priorNavigation {
            self.activeSwitchNavigation = nil
        }
        guard myGeneration == self.switchGeneration,
              myAccountDataGeneration == self.accountDataGeneration,
              switchAuthIdentityGeneration == self.authService.accountIdentityGeneration
        else {
            self.logger.info("AccountService: Switch to \(account.name) superseded while awaiting prior navigation; abandoning")
            throw CancellationError()
        }

        if !UITestConfig.isUITestMode,
           self.webKitManager != nil,
           let previous = rollbackAccount,
           previous.signinURL == nil
        {
            rollbackAccount = await self.refreshAccountForRollback(matching: previous) ?? previous
            guard myGeneration == self.switchGeneration,
                  myAccountDataGeneration == self.accountDataGeneration,
                  switchAuthIdentityGeneration == self.authService.accountIdentityGeneration
            else {
                self.logger.info("AccountService: Switch to \(account.name) superseded while refreshing rollback token; abandoning")
                throw CancellationError()
            }
        }

        // Tracks whether the session-mutating navigation was actually started, so
        // the catch only rolls the session back when there is something to undo.
        var didStartSessionSwitch = false

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
                // Once a session-mutating navigation starts, the previously
                // verified identity is no longer trustworthy until the target
                // switch (or a rollback) verifies its landing identity.
                self.markIdentityVerified(nil)
                // Run the navigation as a cancellable tracked task so a newer
                // switch (or logout) cancels THIS navigation, not just gates its
                // commit. Otherwise two quick switches would run two concurrent
                // /signin WebViews and whichever landed last would win the shared
                // cookie store even though commits are generation-gated.
                try await self.runTrackedSessionSwitch(
                    with: webKitManager,
                    to: signinURL,
                    expectedBrandId: account.brandId
                )
            }

            // If a newer switch/pin superseded this one while we were navigating,
            // abort: the newer operation owns the session and the committed state.
            // Do NOT roll back the session here — the survivor is mid-flight and
            // will establish the correct identity.
            guard myGeneration == self.switchGeneration,
                  myAccountDataGeneration == self.accountDataGeneration,
                  switchAuthIdentityGeneration == self.authService.accountIdentityGeneration
            else {
                self.logger.info("AccountService: Switch to \(account.name) superseded; abandoning commit")
                throw CancellationError()
            }

            guard self.accounts.contains(where: { $0.id == account.id }) else {
                self.logger.info("AccountService: Account data cleared before switch to \(account.name) could commit; abandoning")
                throw CancellationError()
            }

            // Update local state
            self.currentAccount = account

            // Reset client session state to avoid leaking continuations across accounts
            self.ytMusicClient.resetSessionStateForAccountSwitch()
            if !self.authService.isGuestModeEnabled {
                SongLikeStatusManager.shared.setActiveAccountID(account.id)
            }
            let favoritesScopeID = self.favoritesScopeID(for: account)
            if self.authService.isGuestModeEnabled {
                FavoritesManager.shared.setDeferredAccountScopeID(
                    favoritesScopeID,
                    legacyAccountID: account.id
                )
            } else {
                FavoritesManager.shared.setActiveAccountScopeID(
                    favoritesScopeID,
                    legacyAccountID: account.id
                )
            }

            let brandLabel = account.brandId ?? "primary"
            self.logger.info("AccountService: Active account brandId=\(brandLabel)")

            // Persist selection
            UserDefaults.standard.set(account.id, forKey: self.selectedBrandIdKey)
            self.logger.debug("AccountService: Saved brand ID: \(account.id)")

            // The session identity is now verified for this account; signal
            // observers (e.g. MainWindow) to re-point in-flight playback.
            self.markIdentityVerified(account.id)
            self.completeGuestModeAccountSelectionIfNeeded(
                shouldExitGuestModeOnSuccess,
                accountID: account.id
            )

            self.logger.info("AccountService: Successfully switched to account: \(account.name)")
        } catch {
            self.logger.error("AccountService: Failed to switch account: \(error.localizedDescription)")

            // If a newer switch/pin superseded this one, do not touch shared state
            // on the failure path either — the survivor owns currentAccount and the
            // session. Surface nothing; the newer operation drives the outcome.
            guard myGeneration == self.switchGeneration,
                  myAccountDataGeneration == self.accountDataGeneration,
                  switchAuthIdentityGeneration == self.authService.accountIdentityGeneration
            else {
                self.logger.info("AccountService: Failed switch to \(account.name) was superseded; not reverting")
                throw CancellationError()
            }

            let restoredPreviousAccount = await self.rollbackSessionAfterFailedSwitch(
                didStartSessionSwitch: didStartSessionSwitch || cancelledPriorSessionMutation,
                previousAccount: rollbackAccount,
                generation: myGeneration,
                authIdentityGeneration: switchAuthIdentityGeneration
            )
            guard myGeneration == self.switchGeneration,
                  myAccountDataGeneration == self.accountDataGeneration,
                  switchAuthIdentityGeneration == self.authService.accountIdentityGeneration
            else {
                self.logger.info("AccountService: Failed switch to \(account.name) was superseded during rollback; not surfacing failure")
                throw CancellationError()
            }

            self.currentAccount = restoredPreviousAccount
            if self.authService.isGuestModeEnabled {
                SongLikeStatusManager.shared.setActiveAccountID(SongLikeStatusManager.guestAccountID)
            } else {
                SongLikeStatusManager.shared.setActiveAccountID(restoredPreviousAccount?.id)
            }
            let restoredFavoritesScopeID = self.favoritesScopeID(for: restoredPreviousAccount)
            if self.authService.isGuestModeEnabled {
                FavoritesManager.shared.setDeferredAccountScopeID(
                    restoredFavoritesScopeID,
                    legacyAccountID: restoredPreviousAccount?.id
                )
            } else {
                FavoritesManager.shared.setActiveAccountScopeID(
                    restoredFavoritesScopeID,
                    legacyAccountID: restoredPreviousAccount?.id
                )
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

    // swiftlint:enable function_body_length cyclomatic_complexity

    /// Re-fetches the account list after a failed switch so a retry has fresh
    /// signin URLs. Guarded so it does not run while another operation is active.
    private func refreshAccountsAfterSwitchFailure() async {
        guard !self.isLoading else { return }
        await self.fetchAccounts()
    }

    private func rollbackSessionAfterFailedSwitch(
        didStartSessionSwitch: Bool,
        previousAccount: UserAccount?,
        generation: Int,
        authIdentityGeneration: UInt64
    ) async -> UserAccount? {
        var restoredPreviousAccount = previousAccount
        if didStartSessionSwitch,
           !UITestConfig.isUITestMode,
           let previous = previousAccount,
           let freshPrevious = await self.refreshAccountForRollback(matching: previous)
        {
            restoredPreviousAccount = freshPrevious
        }
        guard generation == self.switchGeneration,
              authIdentityGeneration == self.authService.accountIdentityGeneration
        else {
            return restoredPreviousAccount
        }

        // If the /signin navigation already mutated the shared cookie session
        // before verification failed, the session may be left on the attempted
        // identity while native state says `previousAccount`. Best-effort re-pin
        // the previous identity with a fresh token when available.
        guard didStartSessionSwitch,
              !UITestConfig.isUITestMode,
              let webKitManager = self.webKitManager,
              let previous = restoredPreviousAccount,
              let previousSigninURL = previous.signinURL
        else {
            return restoredPreviousAccount
        }

        do {
            try await self.runTrackedSessionSwitch(
                with: webKitManager,
                to: previousSigninURL,
                expectedBrandId: previous.brandId
            )
            if generation == self.switchGeneration,
               authIdentityGeneration == self.authService.accountIdentityGeneration
            {
                self.markIdentityVerified(previous.id)
            }
        } catch is CancellationError {
            // Superseded by a newer switch/logout, which owns the next session
            // mutation and native account state.
        } catch {
            self.logger.error("AccountService: Session rollback failed; session may remain on attempted identity: \(error.localizedDescription)")
        }
        return restoredPreviousAccount
    }

    private func completeGuestModeAccountSelectionIfNeeded(
        _ shouldExitGuestMode: Bool,
        accountID: String
    ) {
        guard shouldExitGuestMode else { return }
        self.authService.exitGuestMode(activeAccountID: accountID)
    }

    private func refreshAccountForRollback(matching account: UserAccount) async -> UserAccount? {
        do {
            let response = try await self.ytMusicClient.fetchAccountsList(
                allowGuestMode: self.authService.isGuestModeEnabled
            )
            return response.accounts.first { $0.id == account.id }
        } catch {
            self.logger.error("AccountService: Could not refresh rollback account token: \(error.localizedDescription)")
            return nil
        }
    }

    /// Clears all account data.
    ///
    /// Should be called when the user logs out to reset state.
    func clearAccounts() {
        self.logger.info("AccountService: Clearing accounts data")
        self.accountDataGeneration &+= 1
        self.sessionPinGeneration &+= 1

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
        self.needsAccountFetchAfterManualSwitch = false
        self.accountsAuthIdentityGeneration = nil
        self.currentAccount = nil
        self.verifiedAccountId = nil
        UserDefaults.standard.removeObject(forKey: self.selectedBrandIdKey)
        SongLikeStatusManager.shared.clearCache()
        SongLikeStatusManager.shared.setActiveAccountID(nil)
        FavoritesManager.shared.setActiveAccountScopeID(nil)
        self.favoritesScopeByAccountID = [:]
        self.verifiedFavoritesOwnerID = nil
        self.clearActiveFavoritesOwnerIdentity()
        self.observedAuthIdentityGeneration = self.authService.accountIdentityGeneration

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
