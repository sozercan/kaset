import Foundation
import Observation

// MARK: - FavoritesManager

/// Manages Favorites persistence and state, scoped per account.
@MainActor
@Observable
final class FavoritesManager { // swiftlint:disable:this type_body_length
    private struct ScopeMergeKey: Hashable {
        let sourceScopeID: String
        let targetScopeID: String
    }

    static let shared = FavoritesManager()
    private static let guestScopeID = "guest"

    private(set) var items: [FavoriteItem] = []
    private(set) var activeScopeID: String?

    private let skipPersistence: Bool
    let storageDirectory: URL
    /// In-memory store for `skipPersistence` test instances.
    private var itemsByScope: [String: [FavoriteItem]] = [:]
    /// Latest snapshots that could not be written during a scope transition.
    private var pendingItemsByScope: [String: [FavoriteItem]] = [:]
    private var preparedMergeItems: [ScopeMergeKey: [FavoriteItem]] = [:]
    private var mergeBaselineItems: [ScopeMergeKey: [FavoriteItem]] = [:]
    private var lastAccountScopeID: String?
    private var lastLegacyAccountID: String?
    private var pendingInitialItems: [FavoriteItem]?
    private var saveTask: Task<Void, Never>?
    var recoveryRetryTasks: [String: Task<Void, Never>] = [:]
    var legacyRecoveryScopeBySourceName: [String: String] = [:]
    /// False when `items` is only an empty fallback after a failed scope load.
    var canPersistActiveSnapshot = false

    private init() {
        let isUITest = UITestConfig.isUITestMode
        self.skipPersistence = isUITest || UITestConfig.isRunningUnitTests
        self.storageDirectory = Self.defaultStorageDirectory

        if isUITest {
            self.loadMockData()
        }
    }

    /// Test/preview initializer — skips disk I/O when `skipLoad` is true.
    init(skipLoad: Bool) {
        self.skipPersistence = skipLoad
        self.storageDirectory = Self.defaultStorageDirectory
    }

    /// Disk-backed initializer for persistence tests using an isolated directory.
    init(storageDirectory: URL) {
        self.skipPersistence = false
        self.storageDirectory = storageDirectory
    }

    /// Switches the signed-in account scope. `nil` clears visible favorites without deleting files.
    func setActiveAccountScopeID(_ scopeID: String?, legacyAccountID: String? = nil) {
        self.setDeferredAccountScopeID(scopeID, legacyAccountID: legacyAccountID)

        // Account selection can change while Guest Mode still owns the visible
        // scope. Remember the next signed-in scope without exposing its items
        // until AuthService exits Guest Mode. A nil scope still clears guest data
        // at a real authentication boundary.
        if self.activeScopeID == Self.guestScopeID, scopeID != nil {
            return
        }
        self.switchScope(
            to: scopeID,
            migratesLegacyFavorites: scopeID != nil,
            legacyAccountID: legacyAccountID
        )
    }

    /// Updates the scope Guest Mode should restore without changing the visible guest scope.
    func setDeferredAccountScopeID(_ scopeID: String?, legacyAccountID: String? = nil) {
        self.lastAccountScopeID = scopeID
        self.lastLegacyAccountID = scopeID == nil ? nil : legacyAccountID
    }

    /// Claims a prior account-ID-scoped favorites file for its resolved opaque scope.
    func recoverLegacyAccountFavorites(accountID: String, toScopeID scopeID: String) {
        guard !self.skipPersistence,
              let legacyURL = self.legacyAccountFavoritesURL(accountID: accountID),
              self.reserveLegacySource(legacyURL, for: scopeID)
        else { return }

        let retryKey = Self.accountRecoveryRetryKey(accountID: accountID, scopeID: scopeID)
        self.cancelRecoveryRetry(key: retryKey)
        let reloadActiveScope = self.activeScopeID == scopeID
        if reloadActiveScope, !self.flushActiveScope() {
            self.scheduleAccountRecoveryRetry(accountID: accountID, scopeID: scopeID, attempt: 0)
            return
        }
        guard self.materializePendingItemsIfNeeded(for: scopeID) else {
            if reloadActiveScope {
                self.loadScopeAfterFailedRecovery(scopeID)
            }
            self.scheduleAccountRecoveryRetry(accountID: accountID, scopeID: scopeID, attempt: 0)
            return
        }

        let migrationResult = self.migrateLegacyAccountFavoritesIfNeeded(
            accountID: accountID,
            toScopeID: scopeID
        )
        if migrationResult.requiresReadOnlyRetry {
            if reloadActiveScope {
                self.loadScopeAfterFailedRecovery(scopeID)
            }
            self.scheduleAccountRecoveryRetry(accountID: accountID, scopeID: scopeID, attempt: 0)
        } else if reloadActiveScope {
            self.load(scopeID: scopeID)
        }
    }

    private func scheduleAccountRecoveryRetry(accountID: String, scopeID: String, attempt: Int) {
        let key = Self.accountRecoveryRetryKey(accountID: accountID, scopeID: scopeID)
        self.scheduleRecoveryRetry(key: key, attempt: attempt) { [weak self] in
            guard let self else { return true }
            if self.activeScopeID == scopeID, !self.flushActiveScope() {
                return false
            }
            guard let legacyURL = self.legacyAccountFavoritesURL(accountID: accountID),
                  self.reserveLegacySource(legacyURL, for: scopeID),
                  self.materializePendingItemsIfNeeded(for: scopeID)
            else { return false }

            let result = self.migrateLegacyAccountFavoritesIfNeeded(
                accountID: accountID,
                toScopeID: scopeID
            )
            if self.activeScopeID == scopeID {
                if result.requiresReadOnlyRetry {
                    self.loadScopeAfterFailedRecovery(scopeID)
                } else {
                    self.load(scopeID: scopeID)
                }
            }
            return !result.requiresReadOnlyRetry
        }
    }

    func enterGuestMode() {
        self.switchScope(
            to: Self.guestScopeID,
            migratesLegacyFavorites: false,
            legacyAccountID: Self.guestScopeID
        )
    }

    func exitGuestMode() {
        self.switchScope(
            to: self.lastAccountScopeID,
            migratesLegacyFavorites: true,
            legacyAccountID: self.lastLegacyAccountID
        )
    }

    func prepareAccountScopeMerge(fromOwnerID: String, intoOwnerID: String, accountIDs: [String]) -> Bool {
        guard fromOwnerID != intoOwnerID else { return true }

        guard self.flushActiveScope() else { return false }
        for accountID in Set(accountIDs).sorted() {
            let sourceScopeID = Self.accountScopeID(ownerID: fromOwnerID, accountID: accountID)
            let targetScopeID = Self.accountScopeID(ownerID: intoOwnerID, accountID: accountID)
            guard self.prepareStoredScopeMerge(
                from: sourceScopeID,
                into: targetScopeID,
                legacyAccountID: accountID
            ) else {
                return false
            }
        }
        return true
    }

    func commitAccountScopeMerge(fromOwnerID: String, intoOwnerID: String, accountIDs: [String]) -> Bool {
        guard fromOwnerID != intoOwnerID else { return true }

        for accountID in Set(accountIDs).sorted() {
            let sourceScopeID = Self.accountScopeID(ownerID: fromOwnerID, accountID: accountID)
            let targetScopeID = Self.accountScopeID(ownerID: intoOwnerID, accountID: accountID)
            guard self.commitPreparedScopeMerge(from: sourceScopeID, into: targetScopeID) else {
                return false
            }
        }
        return true
    }

    @discardableResult
    func finalizeAccountScopeMerge(fromOwnerID: String, intoOwnerID: String, accountIDs: [String]) -> Bool {
        guard fromOwnerID != intoOwnerID else { return true }

        var didFinalize = true
        var scopeMappings: [String: String] = [:]
        for accountID in Set(accountIDs).sorted() {
            let sourceScopeID = Self.accountScopeID(ownerID: fromOwnerID, accountID: accountID)
            let targetScopeID = Self.accountScopeID(ownerID: intoOwnerID, accountID: accountID)
            scopeMappings[sourceScopeID] = targetScopeID
        }
        if let activeScopeID = self.activeScopeID,
           scopeMappings.values.contains(activeScopeID),
           !self.flushActiveScope()
        {
            return false
        }
        for accountID in Set(accountIDs).sorted() {
            let sourceScopeID = Self.accountScopeID(ownerID: fromOwnerID, accountID: accountID)
            let targetScopeID = Self.accountScopeID(ownerID: intoOwnerID, accountID: accountID)
            guard self.canFinalizeScopeMerge(
                from: sourceScopeID,
                into: targetScopeID,
                legacyAccountID: accountID
            ) else {
                return false
            }
            self.retargetPendingLegacyRecovery(
                from: sourceScopeID,
                into: targetScopeID,
                accountID: accountID
            )
            if !self.cleanupPreparedScopeMerge(
                from: sourceScopeID,
                into: targetScopeID,
                legacyAccountID: accountID
            ) {
                didFinalize = false
            }
        }
        if let activeScopeID = self.activeScopeID {
            if let targetScopeID = scopeMappings[activeScopeID] {
                self.activeScopeID = targetScopeID
                self.load(scopeID: targetScopeID)
            } else if scopeMappings.values.contains(activeScopeID) {
                self.load(scopeID: activeScopeID)
            }
        }
        if let lastAccountScopeID = self.lastAccountScopeID,
           let targetScopeID = scopeMappings[lastAccountScopeID]
        {
            self.lastAccountScopeID = targetScopeID
        }
        return didFinalize
    }

    private func switchScope(
        to scopeID: String?,
        migratesLegacyFavorites: Bool,
        legacyAccountID: String?
    ) {
        if let scopeID {
            self.cancelRecoveryRetry(key: Self.scopeRecoveryRetryKey(scopeID: scopeID))
            if let legacyAccountID {
                self.cancelRecoveryRetry(
                    key: Self.accountRecoveryRetryKey(accountID: legacyAccountID, scopeID: scopeID)
                )
            }
        }
        guard self.activeScopeID != scopeID else {
            if let scopeID {
                _ = self.flushActiveScope()
                let didRecover = self.recoverScope(
                    scopeID,
                    migratesLegacyFavorites: migratesLegacyFavorites,
                    legacyAccountID: legacyAccountID
                )
                self.finishScopeRecovery(
                    scopeID: scopeID,
                    didRecover: didRecover,
                    migratesLegacyFavorites: migratesLegacyFavorites,
                    legacyAccountID: legacyAccountID
                )
            } else {
                self.items = []
            }
            return
        }

        _ = self.flushActiveScope()
        self.activeScopeID = scopeID
        self.canPersistActiveSnapshot = false

        guard let scopeID else {
            self.items = []
            return
        }

        let didRecover = self.recoverScope(
            scopeID,
            migratesLegacyFavorites: migratesLegacyFavorites,
            legacyAccountID: legacyAccountID
        )
        self.finishScopeRecovery(
            scopeID: scopeID,
            didRecover: didRecover,
            migratesLegacyFavorites: migratesLegacyFavorites,
            legacyAccountID: legacyAccountID
        )
    }

    private func finishScopeRecovery(
        scopeID: String,
        didRecover: Bool,
        migratesLegacyFavorites: Bool,
        legacyAccountID: String?
    ) {
        if didRecover {
            self.load(scopeID: scopeID)
            return
        }

        self.loadScopeAfterFailedRecovery(scopeID)
        self.scheduleScopeRecoveryRetry(
            scopeID: scopeID,
            migratesLegacyFavorites: migratesLegacyFavorites,
            legacyAccountID: legacyAccountID,
            attempt: 0
        )
    }

    private func loadScopeAfterFailedRecovery(_ scopeID: String) {
        self.saveTask?.cancel()
        self.saveTask = nil
        if let pendingItems = self.pendingItemsByScope[scopeID] {
            self.items = pendingItems
        } else {
            self.load(scopeID: scopeID)
        }
        self.canPersistActiveSnapshot = false
    }

    func scheduleScopeRecoveryRetry(
        scopeID: String,
        migratesLegacyFavorites: Bool,
        legacyAccountID: String?,
        attempt: Int
    ) {
        let key = Self.scopeRecoveryRetryKey(scopeID: scopeID)
        self.scheduleRecoveryRetry(key: key, attempt: attempt) { [weak self] in
            guard let self else { return true }
            if self.activeScopeID == scopeID, !self.flushActiveScope() {
                return false
            }
            let didRecover = self.recoverScope(
                scopeID,
                migratesLegacyFavorites: migratesLegacyFavorites,
                legacyAccountID: legacyAccountID
            )
            if self.activeScopeID == scopeID {
                if didRecover {
                    self.load(scopeID: scopeID)
                } else {
                    self.loadScopeAfterFailedRecovery(scopeID)
                }
            }
            return didRecover
        }
    }

    private func recoverScope(
        _ scopeID: String,
        migratesLegacyFavorites: Bool,
        legacyAccountID: String?
    ) -> Bool {
        if self.skipPersistence {
            if migratesLegacyFavorites,
               let pendingInitialItems = self.pendingInitialItems,
               self.itemsByScope[scopeID] == nil
            {
                self.itemsByScope[scopeID] = pendingInitialItems
                self.pendingInitialItems = nil
            }
        } else if migratesLegacyFavorites {
            let globalLegacyURL = self.storageDirectory.appendingPathComponent("favorites.json")
            let canRecoverGlobalFavorites = self.reserveLegacySource(globalLegacyURL, for: scopeID)
            let accountLegacyURL = legacyAccountID.flatMap { self.legacyAccountFavoritesURL(accountID: $0) }
            let canRecoverAccountFavorites = accountLegacyURL.map {
                self.reserveLegacySource($0, for: scopeID)
            } ?? true
            guard self.materializePendingItemsIfNeeded(for: scopeID) else { return false }
            let globalResult = canRecoverGlobalFavorites
                ? self.migrateLegacyFavoritesIfNeeded(toScopeID: scopeID)
                : .deferred
            let accountResult = if let legacyAccountID, canRecoverAccountFavorites {
                self.migrateLegacyAccountFavoritesIfNeeded(
                    accountID: legacyAccountID,
                    toScopeID: scopeID
                )
            } else {
                LegacyMigrationResult.completed
            }
            return !globalResult.requiresReadOnlyRetry && !accountResult.requiresReadOnlyRetry
        }
        return true
    }

    private func flushActiveScope() -> Bool {
        guard let activeScopeID = self.activeScopeID else { return true }

        self.saveTask?.cancel()
        self.saveTask = nil
        guard self.canPersistActiveSnapshot else { return true }

        if self.skipPersistence {
            self.itemsByScope[activeScopeID] = self.items
            return true
        } else {
            let didWrite = Self.write(self.items, to: self.fileURL(for: activeScopeID))
            if didWrite {
                self.pendingItemsByScope.removeValue(forKey: activeScopeID)
            } else {
                self.pendingItemsByScope[activeScopeID] = self.items
            }
            return didWrite
        }
    }

    // MARK: - Load & Save

    private func load(scopeID: String) {
        if self.skipPersistence {
            self.items = self.itemsByScope[scopeID] ?? []
            self.canPersistActiveSnapshot = true
            return
        }

        if let pendingItems = self.pendingItemsByScope.removeValue(forKey: scopeID) {
            self.items = pendingItems
            self.canPersistActiveSnapshot = true
            self.save()
            return
        }

        let fileURL = self.fileURL(for: scopeID)
        do {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                self.items = []
                self.canPersistActiveSnapshot = true
                return
            }
            let data = try Data(contentsOf: fileURL)
            self.items = try JSONDecoder().decode([FavoriteItem].self, from: data)
            self.canPersistActiveSnapshot = true
            DiagnosticsLogger.ui.info("Loaded \(self.items.count) favorite items")
        } catch {
            DiagnosticsLogger.ui.error("Failed to load favorites: \(error.localizedDescription)")
            self.items = []
            self.canPersistActiveSnapshot = false
        }
    }

    private func save() {
        guard let activeScopeID = self.activeScopeID else { return }
        self.canPersistActiveSnapshot = true

        if self.skipPersistence {
            self.itemsByScope[activeScopeID] = self.items
            return
        }

        self.saveTask?.cancel()
        let itemsSnapshot = self.items
        let targetURL = self.fileURL(for: activeScopeID)
        self.saveTask = Task(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            if Self.write(itemsSnapshot, to: targetURL) {
                self.pendingItemsByScope.removeValue(forKey: activeScopeID)
            } else {
                self.pendingItemsByScope[activeScopeID] = itemsSnapshot
            }
        }
    }

    private func fileURL(for scopeID: String) -> URL {
        self.storageDirectory.appendingPathComponent("favorites-\(scopeID).json")
    }

    private var ownerStateBackupURL: URL {
        self.storageDirectory.appendingPathComponent(".favorites-owner-state.json")
    }

    func loadOwnerStateBackup() -> Data? {
        guard !self.skipPersistence,
              FileManager.default.fileExists(atPath: self.ownerStateBackupURL.path)
        else { return nil }

        do {
            return try Data(contentsOf: self.ownerStateBackupURL)
        } catch {
            DiagnosticsLogger.ui.error("Failed to load favorites owner-state backup: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func saveOwnerStateBackup(_ data: Data) -> Bool {
        guard !self.skipPersistence else { return true }

        do {
            try FileManager.default.createDirectory(
                at: self.storageDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: self.ownerStateBackupURL, options: .atomic)
            return true
        } catch {
            DiagnosticsLogger.ui.error("Failed to save favorites owner-state backup: \(error.localizedDescription)")
            return false
        }
    }

    private func materializePendingItemsIfNeeded(for scopeID: String) -> Bool {
        guard let pendingItems = self.pendingItemsByScope[scopeID] else { return true }
        guard Self.write(pendingItems, to: self.fileURL(for: scopeID)) else { return false }
        self.pendingItemsByScope.removeValue(forKey: scopeID)
        return true
    }

    private func migrateLegacyFavoritesIfNeeded(toScopeID targetScopeID: String) -> LegacyMigrationResult {
        let legacyURL = self.storageDirectory.appendingPathComponent("favorites.json")
        return self.migrateLegacyFileIfNeeded(from: legacyURL, toScopeID: targetScopeID)
    }

    private func migrateLegacyAccountFavoritesIfNeeded(
        accountID: String,
        toScopeID targetScopeID: String
    ) -> LegacyMigrationResult {
        guard let legacyURL = self.legacyAccountFavoritesURL(accountID: accountID) else { return .completed }
        return self.migrateLegacyFileIfNeeded(from: legacyURL, toScopeID: targetScopeID)
    }

    private func migrateLegacyFileIfNeeded(
        from legacyURL: URL,
        toScopeID targetScopeID: String
    ) -> LegacyMigrationResult {
        guard self.reserveLegacySource(legacyURL, for: targetScopeID) else { return .deferred }
        defer { self.releaseLegacySourceIfBoundOrAbsent(legacyURL, from: targetScopeID) }

        let targetURL = self.fileURL(for: targetScopeID)
        guard legacyURL != targetURL else { return .completed }

        let claimURL = self.legacyClaimURL(for: legacyURL, boundTo: targetScopeID)
        guard FileManager.default.fileExists(atPath: legacyURL.path)
            || FileManager.default.fileExists(atPath: claimURL.path)
        else { return .completed }

        do {
            try FileManager.default.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: claimURL.path) {
                let result = self.commitLegacyClaim(at: claimURL, to: targetURL)
                guard result == .completed else { return result }
            }

            guard FileManager.default.fileExists(atPath: legacyURL.path) else { return .completed }
            guard FileManager.default.fileExists(atPath: targetURL.path) else {
                try FileManager.default.moveItem(at: legacyURL, to: targetURL)
                return .completed
            }

            // Consume the globally discoverable name before changing an existing destination.
            // A failed commit or cleanup can then only be resumed by this destination scope.
            try FileManager.default.moveItem(at: legacyURL, to: claimURL)
            return self.commitLegacyClaim(at: claimURL, to: targetURL)
        } catch {
            DiagnosticsLogger.ui.error("Failed to migrate favorites: \(error.localizedDescription)")
            return .requiresReadOnlyRetry
        }
    }

    private func commitLegacyClaim(at claimURL: URL, to targetURL: URL) -> LegacyMigrationResult {
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            do {
                try FileManager.default.moveItem(at: claimURL, to: targetURL)
                return .completed
            } catch {
                DiagnosticsLogger.ui.error("Failed to promote favorites claim: \(error.localizedDescription)")
                return .requiresReadOnlyRetry
            }
        }

        let claimData: Data
        do {
            claimData = try Data(contentsOf: claimURL)
        } catch {
            DiagnosticsLogger.ui.error("Cannot read legacy favorites claim: \(error.localizedDescription)")
            return .requiresReadOnlyRetry
        }

        let claimedItems: [FavoriteItem]
        do {
            claimedItems = try JSONDecoder().decode([FavoriteItem].self, from: claimData)
        } catch {
            DiagnosticsLogger.ui.error("Deferring malformed legacy favorites claim: \(error.localizedDescription)")
            return .deferred
        }

        let existingItems: [FavoriteItem]
        do {
            existingItems = try JSONDecoder().decode([FavoriteItem].self, from: Data(contentsOf: targetURL))
        } catch {
            DiagnosticsLogger.ui.error("Cannot merge favorites into an invalid target: \(error.localizedDescription)")
            return .requiresReadOnlyRetry
        }

        do {
            try JSONEncoder().encode(Self.merging(existingItems, appending: claimedItems))
                .write(to: targetURL, options: .atomic)
            try FileManager.default.removeItem(at: claimURL)
            return .completed
        } catch {
            DiagnosticsLogger.ui.error("Failed to commit favorites claim: \(error.localizedDescription)")
            return .requiresReadOnlyRetry
        }
    }

    private func canFinalizeScopeMerge(
        from sourceScopeID: String,
        into targetScopeID: String,
        legacyAccountID: String
    ) -> Bool {
        let mergeKey = ScopeMergeKey(sourceScopeID: sourceScopeID, targetScopeID: targetScopeID)
        if self.skipPersistence {
            if self.itemsByScope[targetScopeID] != nil {
                return true
            }
            return self.itemsByScope[sourceScopeID] == nil
                && self.preparedMergeItems[mergeKey] == nil
        }

        guard self.materializePendingItemsIfNeeded(for: targetScopeID) else { return false }
        let targetURL = self.fileURL(for: targetScopeID)
        if FileManager.default.fileExists(atPath: targetURL.path) {
            do {
                _ = try JSONDecoder().decode([FavoriteItem].self, from: Data(contentsOf: targetURL))
                return true
            } catch {
                DiagnosticsLogger.ui.error("Cannot finalize favorites migration with an invalid target: \(error.localizedDescription)")
                return false
            }
        }

        // Empty accounts legitimately have no source, prepared merge, claims, or
        // target file. They must not block finalization of other migrated scopes.
        let recoveryURLs = [
            self.fileURL(for: sourceScopeID),
            self.preparedMergeURL(for: mergeKey),
        ] + self.legacyClaimURLs(
            boundTo: sourceScopeID,
            legacyAccountID: legacyAccountID
        )
        return self.pendingItemsByScope[sourceScopeID] == nil
            && recoveryURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
    }

    private func prepareStoredScopeMerge(
        from sourceScopeID: String,
        into targetScopeID: String,
        legacyAccountID: String
    ) -> Bool {
        let mergeKey = ScopeMergeKey(sourceScopeID: sourceScopeID, targetScopeID: targetScopeID)
        if self.skipPersistence {
            guard let sourceItems = self.itemsByScope[sourceScopeID] else { return true }
            let baselineItems = self.mergeBaselineItems[mergeKey]
                ?? self.itemsByScope[targetScopeID]
                ?? []
            self.mergeBaselineItems[mergeKey] = baselineItems
            let currentTargetItems = self.itemsByScope[targetScopeID] ?? []
            let targetOwnedItems = Self.targetOwnedItems(
                baselineItems: baselineItems,
                currentTargetItems: currentTargetItems,
                previousPreparedItems: self.preparedMergeItems[mergeKey]
            )
            self.mergeBaselineItems[mergeKey] = targetOwnedItems
            self.preparedMergeItems[mergeKey] = Self.merging(targetOwnedItems, appending: sourceItems)
            return true
        }

        let sourceURL = self.fileURL(for: sourceScopeID)
        let targetURL = self.fileURL(for: targetScopeID)
        let baselineURL = self.mergeBaselineURL(for: mergeKey)
        let preparedURL = self.preparedMergeURL(for: mergeKey)

        do {
            try FileManager.default.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)
            var sourceItems: [FavoriteItem]?
            if let pendingSourceItems = self.pendingItemsByScope[sourceScopeID] {
                sourceItems = pendingSourceItems
            } else if FileManager.default.fileExists(atPath: sourceURL.path) {
                sourceItems = try JSONDecoder().decode(
                    [FavoriteItem].self,
                    from: Data(contentsOf: sourceURL)
                )
            }
            for claimURL in self.legacyClaimURLs(
                boundTo: sourceScopeID,
                legacyAccountID: legacyAccountID
            ) where FileManager.default.fileExists(atPath: claimURL.path) {
                // Claims remain source-owned until owner migration commits and finalizes.
                let claimItems = try JSONDecoder().decode(
                    [FavoriteItem].self,
                    from: Data(contentsOf: claimURL)
                )
                sourceItems = Self.merging(sourceItems ?? [], appending: claimItems)
            }
            guard let sourceItems else { return true }

            let currentTargetItems: [FavoriteItem] = if let pendingTargetItems = self.pendingItemsByScope[targetScopeID] {
                pendingTargetItems
            } else if FileManager.default.fileExists(atPath: targetURL.path) {
                try JSONDecoder().decode(
                    [FavoriteItem].self,
                    from: Data(contentsOf: targetURL)
                )
            } else {
                []
            }

            let baselineItems: [FavoriteItem]
            if FileManager.default.fileExists(atPath: baselineURL.path) {
                baselineItems = try JSONDecoder().decode(
                    [FavoriteItem].self,
                    from: Data(contentsOf: baselineURL)
                )
            } else {
                baselineItems = currentTargetItems
                try JSONEncoder().encode(baselineItems).write(to: baselineURL, options: .atomic)
            }
            let previousPreparedItems: [FavoriteItem]? = if FileManager.default.fileExists(atPath: preparedURL.path) {
                try JSONDecoder().decode([FavoriteItem].self, from: Data(contentsOf: preparedURL))
            } else {
                nil
            }
            let targetOwnedItems = Self.targetOwnedItems(
                baselineItems: baselineItems,
                currentTargetItems: currentTargetItems,
                previousPreparedItems: previousPreparedItems
            )
            try JSONEncoder().encode(targetOwnedItems).write(to: baselineURL, options: .atomic)
            try JSONEncoder().encode(Self.merging(targetOwnedItems, appending: sourceItems))
                .write(to: preparedURL, options: .atomic)
            return true
        } catch {
            DiagnosticsLogger.ui.error("Failed to merge favorites scopes: \(error.localizedDescription)")
            return false
        }
    }

    private func commitPreparedScopeMerge(from sourceScopeID: String, into targetScopeID: String) -> Bool {
        let mergeKey = ScopeMergeKey(sourceScopeID: sourceScopeID, targetScopeID: targetScopeID)
        if self.skipPersistence {
            guard let preparedItems = self.preparedMergeItems[mergeKey] else { return true }
            self.itemsByScope[targetScopeID] = preparedItems
            if self.activeScopeID == targetScopeID {
                self.items = preparedItems
                self.canPersistActiveSnapshot = true
            }
            return true
        }

        let preparedURL = self.preparedMergeURL(for: mergeKey)
        guard FileManager.default.fileExists(atPath: preparedURL.path) else { return true }
        let targetURL = self.fileURL(for: targetScopeID)
        do {
            let preparedData = try Data(contentsOf: preparedURL)
            try preparedData.write(to: targetURL, options: .atomic)
            self.pendingItemsByScope.removeValue(forKey: targetScopeID)
            if self.activeScopeID == targetScopeID {
                self.load(scopeID: targetScopeID)
            }
            return true
        } catch {
            DiagnosticsLogger.ui.error("Failed to commit favorites scope merge: \(error.localizedDescription)")
            return false
        }
    }

    private func cleanupPreparedScopeMerge(
        from sourceScopeID: String,
        into targetScopeID: String,
        legacyAccountID: String
    ) -> Bool {
        let mergeKey = ScopeMergeKey(sourceScopeID: sourceScopeID, targetScopeID: targetScopeID)
        self.preparedMergeItems.removeValue(forKey: mergeKey)
        self.mergeBaselineItems.removeValue(forKey: mergeKey)
        self.pendingItemsByScope.removeValue(forKey: sourceScopeID)

        if self.skipPersistence {
            self.itemsByScope.removeValue(forKey: sourceScopeID)
            return true
        }

        var didCleanup = true
        let cleanupURLs = [
            self.fileURL(for: sourceScopeID),
            self.mergeBaselineURL(for: mergeKey),
            self.preparedMergeURL(for: mergeKey),
        ] + self.legacyClaimURLs(
            boundTo: sourceScopeID,
            legacyAccountID: legacyAccountID
        )
        for url in cleanupURLs where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                didCleanup = false
                DiagnosticsLogger.ui.error("Failed to clean up migrated favorites scope: \(error.localizedDescription)")
            }
        }
        return didCleanup
    }

    private func mergeBaselineURL(for key: ScopeMergeKey) -> URL {
        self.storageDirectory.appendingPathComponent(
            ".favorites-merge-\(key.sourceScopeID)-to-\(key.targetScopeID)-baseline.json"
        )
    }

    private func preparedMergeURL(for key: ScopeMergeKey) -> URL {
        self.storageDirectory.appendingPathComponent(
            ".favorites-merge-\(key.sourceScopeID)-to-\(key.targetScopeID)-prepared.json"
        )
    }

    // MARK: - Actions

    func add(_ item: FavoriteItem) {
        guard self.canMutate else { return }
        guard !self.isPinned(contentId: item.contentId) else { return }
        self.items.insert(item, at: 0)
        self.save()
    }

    func remove(contentId: String) {
        guard self.canMutate else { return }
        guard let index = items.firstIndex(where: { $0.contentId == contentId }) else { return }
        self.items.remove(at: index)
        self.save()
    }

    func move(from source: IndexSet, to destination: Int) {
        guard self.canMutate else { return }
        self.items.move(fromOffsets: source, toOffset: destination)
        self.save()
    }

    func moveToTop(contentId: String) {
        guard self.canMutate else { return }
        guard let index = items.firstIndex(where: { $0.contentId == contentId }) else { return }
        let item = self.items.remove(at: index)
        self.items.insert(item, at: 0)
        self.save()
    }

    func moveToEnd(contentId: String) {
        guard self.canMutate else { return }
        guard let index = items.firstIndex(where: { $0.contentId == contentId }) else { return }
        let item = self.items.remove(at: index)
        self.items.append(item)
        self.save()
    }

    func isPinned(contentId: String) -> Bool {
        self.items.contains { $0.contentId == contentId }
    }

    // MARK: - Testing Support

    private func loadMockData() {
        guard let jsonString = UITestConfig.environmentValue(for: UITestConfig.mockFavoritesKey),
              let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([FavoriteItem].self, from: data)
        else {
            self.items = []
            return
        }
        self.items = decoded
        self.pendingInitialItems = decoded
    }

    func clearAll() {
        guard self.canMutate else { return }
        self.items.removeAll()
        self.save()
    }

    func reset(with items: [FavoriteItem]) {
        guard self.canMutate else { return }
        self.items = items
        self.save()
    }
}
