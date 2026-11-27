// swiftlint:disable file_length

import Foundation
import os

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

    private struct AccountContentScope {
        enum ProvisionalKind {
            case initialUnresolved
            case ownerConflict
        }

        let id: String
        var durableScopeID: String?
        var provisionalKind: ProvisionalKind?
    }

    private let ytMusicClient: any YTMusicClientProtocol
    private let authService: AuthService
    private let favoritesOwnerDefaults: UserDefaults?
    private var accountBoundaryWillBegin: (@MainActor @Sendable () -> Void)?
    private var accountBoundaryDidEnd: (@MainActor @Sendable () -> Void)?
    private var accountBoundaryDrain: (@MainActor @Sendable () async -> Void)?

    private let webKitManager: (any WebKitManagerProtocol)?

    private(set) var accounts: [UserAccount] = []

    private(set) var currentAccount: UserAccount?

    private(set) var verifiedAccountId: String?

    private(set) var verifiedIdentitySequence: Int = 0

    private(set) var isLoading: Bool = false

    private(set) var didCompleteAccountResolution: Bool = false

    private(set) var lastError: Error?

    private(set) var lastErrorWasFetch: Bool = false

    private(set) var errorSequence: Int = 0

    var hasBrandAccounts: Bool {
        self.accounts.count > 1
    }

    var currentBrandId: String? {
        self.currentAccount?.brandId
    }

    var currentAccountScopeID: String? {
        guard let currentAccount = self.currentAccount else { return nil }
        return self.contentScopeByAccountID[currentAccount.id]?.id
    }

    var currentFavoritesScopeID: String? {
        self.favoritesScopeID(for: self.currentAccount)
    }

    func setAccountBoundaryHandlers(
        willBegin: @escaping @MainActor @Sendable () -> Void,
        didEnd: @escaping @MainActor @Sendable () -> Void,
        drain: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.accountBoundaryWillBegin = willBegin
        self.accountBoundaryDidEnd = didEnd
        self.accountBoundaryDrain = drain
    }

    private let logger = DiagnosticsLogger.auth
    private let selectedBrandIdKey = "selectedBrandId"
    private static let favoritesOwnerStateKey = "favorites.ownerState"
    private var favoritesScopeByAccountID: [String: String] = [:]
    private var contentScopeByAccountID: [String: AccountContentScope] = [:]
    private var contentScopeGeneration: UInt64 = 0
    private var didDetectFavoritesOwnerConflict = false
    private var favoritesOwnerID: String?
    private var favoritesOwnerIDByAliasID: [String: String] = [:]
    private var favoritesAccountIDsByOwnerID: [String: Set<String>] = [:]
    private var favoritesEmailAliasIDs: Set<String> = []
    private var pendingFavoritesOwnerFinalizations: Set<FavoritesOwnerFinalization> = []
    private var verifiedFavoritesOwnerID: String?
    private var observedAuthIdentityGeneration: UInt64 = 0

    private var sessionPinTask: Task<Void, Never>?
    private var sessionPinGeneration = 0
    private var sessionMutationDrainTask: Task<Void, Never>?
    private var isAuthenticationBoundaryInProgress = false

    private var activeSwitchNavigation: Task<Void, Error>?

    private var switchGeneration: Int = 0

    private var manualSwitchInFlightCount = 0
    private var needsAccountFetchAfterManualSwitch = false

    private var accountsAuthIdentityGeneration: UInt64?

    private var accountDataGeneration = 0

    private func markIdentityVerified(_ accountId: String?) {
        self.verifiedAccountId = accountId
        self.verifiedIdentitySequence &+= 1
    }

    private func updateFavoritesScopes(from response: AccountsListResponse) {
        self.didDetectFavoritesOwnerConflict = false
        if let ownerID = self.resolveFavoritesOwnerID(from: response) {
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
        } else {
            self.favoritesScopeByAccountID = [:]
        }

        self.updateContentScopes(
            for: response.accounts,
            ownerConflict: self.didDetectFavoritesOwnerConflict
        )
    }

    private func updateContentScopes(
        for accounts: [UserAccount],
        ownerConflict: Bool
    ) {
        let accountIDs = Set(accounts.map(\.id))
        self.contentScopeByAccountID = self.contentScopeByAccountID.filter { accountIDs.contains($0.key) }

        for account in accounts {
            let durableScopeID = self.favoritesScopeByAccountID[account.id]
            guard var existingScope = self.contentScopeByAccountID[account.id] else {
                let provisionalKind: AccountContentScope.ProvisionalKind? = if durableScopeID != nil {
                    nil
                } else if ownerConflict {
                    .ownerConflict
                } else {
                    .initialUnresolved
                }
                self.contentScopeByAccountID[account.id] = AccountContentScope(
                    id: durableScopeID ?? self.issueProvisionalContentScopeID(for: account.id),
                    durableScopeID: durableScopeID,
                    provisionalKind: provisionalKind
                )
                continue
            }

            if ownerConflict, durableScopeID == nil {
                if existingScope.provisionalKind != .ownerConflict {
                    self.contentScopeByAccountID[account.id] = AccountContentScope(
                        id: self.issueProvisionalContentScopeID(for: account.id),
                        durableScopeID: nil,
                        provisionalKind: .ownerConflict
                    )
                }
                continue
            }

            switch (existingScope.durableScopeID, durableScopeID) {
            case let (existing?, resolved?) where existing != resolved:
                self.contentScopeByAccountID[account.id] = AccountContentScope(
                    id: resolved,
                    durableScopeID: resolved,
                    provisionalKind: nil
                )
            case (_?, nil):
                self.contentScopeByAccountID[account.id] = AccountContentScope(
                    id: self.issueProvisionalContentScopeID(for: account.id),
                    durableScopeID: nil,
                    provisionalKind: .ownerConflict
                )
            case (nil, let resolved?):
                if existingScope.provisionalKind == .ownerConflict {
                    self.contentScopeByAccountID[account.id] = AccountContentScope(
                        id: resolved,
                        durableScopeID: resolved,
                        provisionalKind: nil
                    )
                } else {
                    existingScope.durableScopeID = resolved
                    existingScope.provisionalKind = nil
                    self.contentScopeByAccountID[account.id] = existingScope
                }
            case (nil, nil), _:
                break
            }
        }
    }

    private func issueProvisionalContentScopeID(for accountID: String) -> String {
        self.contentScopeGeneration &+= 1
        return FavoritesManager.opaqueIdentityID(
            for: "session-account\u{1F}\(self.authService.accountIdentityGeneration)\u{1F}\(self.contentScopeGeneration)\u{1F}\(accountID)"
        )
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
                self.didDetectFavoritesOwnerConflict = true
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
        self.didCompleteAccountResolution = false
        self.verifiedAccountId = nil
        SongLikeStatusManager.shared.invalidateSession()
        SongLikeStatusManager.shared.clearCache()
        SongLikeStatusManager.shared.setActiveAccountID(nil)
        self.favoritesScopeByAccountID = [:]
        self.contentScopeByAccountID = [:]
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
        let expectedSwitchGeneration = self.switchGeneration
        let expectedAccountDataGeneration = self.accountDataGeneration
        let expectedAuthIdentityGeneration = self.authService.accountIdentityGeneration
        self.accountBoundaryWillBegin?()
        defer { self.accountBoundaryDidEnd?() }
        await self.accountBoundaryDrain?()
        guard expectedSwitchGeneration == self.switchGeneration,
              expectedAccountDataGeneration == self.accountDataGeneration,
              expectedAuthIdentityGeneration == self.authService.accountIdentityGeneration,
              !self.isAuthenticationBoundaryInProgress
        else { throw CancellationError() }
        let navigation = Task { @MainActor in
            try await webKitManager.switchSessionIdentity(
                to: signinURL,
                expectedBrandId: expectedBrandId
            )
        }
        self.activeSwitchNavigation = navigation
        defer {
            if self.activeSwitchNavigation == navigation {
                self.activeSwitchNavigation = nil
            }
        }
        try await navigation.value
    }

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

            let nextAccount = self.restoredAccount(from: response)
            let requiresBoundary = self.accountFetchRequiresBoundary(
                response: response,
                nextAccount: nextAccount
            )
            if requiresBoundary {
                self.accountBoundaryWillBegin?()
                defer { self.accountBoundaryDidEnd?() }
                await self.accountBoundaryDrain?()
                guard fetchGeneration == self.accountDataGeneration,
                      fetchAuthIdentityGeneration == self.authService.accountIdentityGeneration,
                      fetchSwitchGeneration == self.switchGeneration,
                      self.manualSwitchInFlightCount == 0,
                      self.authService.hasPersonalAccount,
                      !self.isAuthenticationBoundaryInProgress
                else {
                    self.logger.info("AccountService: Account fetch became stale while draining Library mutations")
                    return
                }
            }

            self.updateFavoritesScopes(from: response)
            self.accounts = response.accounts
            self.accountsAuthIdentityGeneration = fetchAuthIdentityGeneration
            self.currentAccount = nextAccount
            self.didCompleteAccountResolution = true

            SongLikeStatusManager.shared.setActiveAccountID(self.currentAccount?.id)
            FavoritesManager.shared.setActiveAccountScopeID(
                self.favoritesScopeID(for: self.currentAccount),
                legacyAccountID: self.currentAccount?.id
            )

            let currentLabel = self.currentAccount?.brandId ?? "primary"
            self.logger.info("AccountService: Fetched \(self.accounts.count) accounts, current: \(self.currentAccount?.name ?? "none") (brandId=\(currentLabel))")

            if self.verifiedAccountId != self.currentAccount?.id {
                self.scheduleRestoredSessionPin()
            }
        } catch is CancellationError {
            self.logger.debug("AccountService: Account fetch cancelled")
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
            self.didCompleteAccountResolution = true
        }
    }

    private func restoredAccount(from response: AccountsListResponse) -> UserAccount? {
        guard let savedAccountID = UserDefaults.standard.string(forKey: self.selectedBrandIdKey) else {
            self.logger.debug("AccountService: Using API-selected account")
            return response.selectedAccount ?? response.accounts.first
        }

        self.logger.debug("AccountService: Found saved brand ID: \(savedAccountID)")
        guard let savedAccount = response.accounts.first(where: { $0.id == savedAccountID }) else {
            self.logger.debug("AccountService: Saved account not found, using API-selected")
            return response.selectedAccount ?? response.accounts.first
        }

        self.logger.info("AccountService: Restored previous account: \(savedAccount.name)")
        return savedAccount
    }

    private func accountFetchRequiresBoundary(
        response: AccountsListResponse,
        nextAccount: UserAccount?
    ) -> Bool {
        guard let currentAccount = self.currentAccount,
              let nextAccount,
              currentAccount.id == nextAccount.id,
              let currentScope = self.contentScopeByAccountID[currentAccount.id]
        else { return true }

        if currentScope.provisionalKind == .ownerConflict {
            return true
        }

        guard let authFingerprintID = Self.favoritesAuthFingerprintID(from: self.authService.state),
              let emailAliasID = Self.favoritesEmailAliasID(from: response.googleEmail),
              let authBoundOwnerID = self.favoritesOwnerIDByAliasID[authFingerprintID]
        else { return false }

        let emailOwnerID = self.favoritesOwnerIDByAliasID[emailAliasID]
        return self.favoritesOwnerHasEmailAlias(authBoundOwnerID)
            && emailOwnerID != authBoundOwnerID
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    private func scheduleRestoredSessionPin() {
        guard !self.isAuthenticationBoundaryInProgress else { return }

        let priorPinTask = self.sessionPinTask
        let priorNavigation = self.activeSwitchNavigation
        let pinAuthIdentityGeneration = self.authService.accountIdentityGeneration
        priorPinTask?.cancel()
        self.sessionPinTask = nil
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
            self.accountBoundaryWillBegin?()
            defer { self.accountBoundaryDidEnd?() }
            await self.accountBoundaryDrain?()
            guard !Task.isCancelled,
                  self.sessionPinGeneration == pinGeneration,
                  pinAuthIdentityGeneration == self.authService.accountIdentityGeneration,
                  self.authService.hasPersonalAccount,
                  !self.isAuthenticationBoundaryInProgress,
                  self.currentAccount?.id == accountId,
                  self.switchGeneration == switchGenerationAtPinStart
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

        let expectedSwitchGeneration = self.switchGeneration
        let expectedAccountDataGeneration = self.accountDataGeneration
        self.accountBoundaryWillBegin?()
        defer { self.accountBoundaryDidEnd?() }
        await self.accountBoundaryDrain?()
        guard !Task.isCancelled,
              pinGeneration == self.sessionPinGeneration,
              expectedSwitchGeneration == self.switchGeneration,
              expectedAccountDataGeneration == self.accountDataGeneration,
              authIdentityGeneration == self.authService.accountIdentityGeneration,
              self.authService.hasPersonalAccount,
              !self.isAuthenticationBoundaryInProgress,
              self.currentAccount?.id == account.id
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
        guard !Task.isCancelled,
              self.sessionPinGeneration == pinGeneration,
              expectedSwitchGeneration == self.switchGeneration,
              expectedAccountDataGeneration == self.accountDataGeneration,
              authIdentityGeneration == self.authService.accountIdentityGeneration,
              self.authService.hasPersonalAccount,
              !self.isAuthenticationBoundaryInProgress,
              self.currentAccount?.id == account.id
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

    func authenticationIdentityDidChange() {
        self.resetFavoritesOwnerIfAuthenticationBoundaryChanged()
        if self.authService.hasPersonalAccount {
            self.isAuthenticationBoundaryInProgress = false
        }
    }

    func prepareForReauthentication() async {
        self.accountBoundaryWillBegin?()
        defer { self.accountBoundaryDidEnd?() }
        self.isAuthenticationBoundaryInProgress = true
        await self.accountBoundaryDrain?()
        self.resetFavoritesOwnerIfAuthenticationBoundaryChanged()
        await self.invalidateAndDrainSessionMutations()
    }

    func prepareForSignOut() async {
        self.accountBoundaryWillBegin?()
        defer { self.accountBoundaryDidEnd?() }
        self.isAuthenticationBoundaryInProgress = true
        await self.accountBoundaryDrain?()
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
    func switchAccount(to account: UserAccount) async throws {
        self.authService.cancelPendingGuestModeTransition()
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
                await self.completeGuestModeAccountSelectionIfNeeded(
                    shouldExitGuestModeOnSuccess,
                    accountID: account.id
                )
                return
            }
            self.markIdentityVerified(nil)
        }
        guard !isSameAccount || (account.signinURL != nil && self.verifiedAccountId != account.id && self.webKitManager != nil) else {
            self.logger.debug("AccountService: Already using account \(account.name)")
            await self.completeGuestModeAccountSelectionIfNeeded(
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

        self.switchGeneration &+= 1
        let myGeneration = self.switchGeneration
        let myAccountDataGeneration = self.accountDataGeneration
        var cancelledPriorSessionMutation = false

        self.accountBoundaryWillBegin?()
        defer { self.accountBoundaryDidEnd?() }
        await self.accountBoundaryDrain?()
        guard myGeneration == self.switchGeneration,
              myAccountDataGeneration == self.accountDataGeneration,
              switchAuthIdentityGeneration == self.authService.accountIdentityGeneration,
              !self.isAuthenticationBoundaryInProgress
        else {
            self.logger.info("AccountService: Switch to \(account.name) superseded while draining Library mutations")
            throw CancellationError()
        }

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

        var didStartSessionSwitch = false

        do {
            if UITestConfig.isUITestMode,
               UITestConfig.environmentValue(for: UITestConfig.mockAccountSwitchFailKey) == "true"
            {
                throw YTMusicError.apiError(message: "Mock account switch failure", code: nil)
            }

            if !UITestConfig.isUITestMode, let webKitManager = self.webKitManager {
                guard let signinURL = account.signinURL else {
                    throw SessionSwitchError.identityNotApplied(expectedBrandId: account.brandId)
                }
                didStartSessionSwitch = true
                self.markIdentityVerified(nil)
                try await self.runTrackedSessionSwitch(
                    with: webKitManager,
                    to: signinURL,
                    expectedBrandId: account.brandId
                )
            }

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

            self.currentAccount = account

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

            UserDefaults.standard.set(account.id, forKey: self.selectedBrandIdKey)
            self.logger.debug("AccountService: Saved brand ID: \(account.id)")

            self.markIdentityVerified(account.id)
            await self.completeGuestModeAccountSelectionIfNeeded(
                shouldExitGuestModeOnSuccess,
                accountID: account.id
            )

            self.logger.info("AccountService: Successfully switched to account: \(account.name)")
        } catch {
            self.logger.error("AccountService: Failed to switch account: \(error.localizedDescription)")

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

            if didStartSessionSwitch {
                Task { [weak self] in await self?.refreshAccountsAfterSwitchFailure() }
            }

            throw error
        }
    }

    // swiftlint:enable function_body_length cyclomatic_complexity

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
        } catch {
            self.logger.error("AccountService: Session rollback failed; session may remain on attempted identity: \(error.localizedDescription)")
        }
        return restoredPreviousAccount
    }

    private func completeGuestModeAccountSelectionIfNeeded(
        _ shouldExitGuestMode: Bool,
        accountID: String
    ) async {
        guard shouldExitGuestMode else { return }
        await self.authService.exitGuestMode(activeAccountID: accountID)
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

    func clearAccounts() {
        self.logger.info("AccountService: Clearing accounts data")
        self.accountDataGeneration &+= 1
        self.sessionPinGeneration &+= 1

        self.sessionPinTask?.cancel()
        self.sessionPinTask = nil
        self.activeSwitchNavigation?.cancel()
        self.activeSwitchNavigation = nil
        self.switchGeneration &+= 1

        self.accounts = []
        self.needsAccountFetchAfterManualSwitch = false
        self.accountsAuthIdentityGeneration = nil
        self.currentAccount = nil
        self.didCompleteAccountResolution = false
        self.verifiedAccountId = nil
        UserDefaults.standard.removeObject(forKey: self.selectedBrandIdKey)
        SongLikeStatusManager.shared.clearCache()
        SongLikeStatusManager.shared.setActiveAccountID(nil)
        FavoritesManager.shared.setActiveAccountScopeID(nil)
        self.favoritesScopeByAccountID = [:]
        self.contentScopeByAccountID = [:]
        self.verifiedFavoritesOwnerID = nil
        self.clearActiveFavoritesOwnerIdentity()
        self.observedAuthIdentityGeneration = self.authService.accountIdentityGeneration

        self.logger.debug("AccountService: Accounts cleared")
    }

    func clearError() {
        self.lastError = nil
        self.lastErrorWasFetch = false
    }
}
